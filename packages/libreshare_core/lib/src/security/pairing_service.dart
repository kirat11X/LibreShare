/// QR pairing (LSP-1 5.3, docs/plans/inc3.md D13): the inviter side ([PairingService.createInvite],
/// [PairingService.handlePair], [PairingService.decide]) and the scanner side
/// ([PairingService.startScan] / [PairScan]).
///
///  * `PairRequest.mac = HMAC-SHA256(S, "LSP1-PAIR-REQ" 0x00 || fpB || fpA || nB)`
///  * `PairResponse.mac = HMAC-SHA256(S, "LSP1-PAIR-ACK" 0x00 || fpA || fpB || nA || nB)`
///  * `K_pair = HKDF-SHA256(ikm=S, salt=nA || nB, info="LSP-R1 pair" || min(fpA,fpB) || max(fpA,fpB), 32)`
///
/// A is the inviter (shows the QR), B the scanner. Fingerprints enter every MAC as their 64 ASCII
/// uppercase hex characters. `S` lives in memory only and is zeroed once the invite is spent.
/// Nothing here logs a secret, nonce, MAC, key or full fingerprint; exceptions carry fixed text.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../clock.dart';
import '../model/device.dart';
import '../model/events.dart';
import '../model/ls_exception.dart';
import '../model/session_models.dart';
import '../protocol.dart';
import '../storage/device_registry.dart' show RegistryFullException;
import 'contracts.dart';
import 'crypto_primitives.dart';
import 'trust_store.dart' show FingerprintInUseException, KeyChangedException;

final Logger _log = Logger('PairingService');

const int _kSecretBytes = 32;
const int _kNonceBytes = 16;
final RegExp _fp64 = RegExp(r'^[0-9A-Fa-f]{64}$');

String _fp(String fingerprint) {
  if (!_fp64.hasMatch(fingerprint)) {
    throw ArgumentError.value('invalid', 'fingerprint');
  }
  return fingerprint.toUpperCase();
}

/// `HMAC-SHA256(S, "LSP1-PAIR-REQ" 0x00 || fpB || fpA || nB)`.
Uint8List pairRequestMac({
  required List<int> secret,
  required String scannerFingerprint,
  required String inviterFingerprint,
  required List<int> scannerNonce,
}) => hmacSha256(
  secret,
  domainSeparate(SigDomain.pairRequest, [
    ...ascii.encode(_fp(scannerFingerprint)),
    ...ascii.encode(_fp(inviterFingerprint)),
    ...scannerNonce,
  ]),
);

/// `HMAC-SHA256(S, "LSP1-PAIR-ACK" 0x00 || fpA || fpB || nA || nB)`.
Uint8List pairAckMac({
  required List<int> secret,
  required String inviterFingerprint,
  required String scannerFingerprint,
  required List<int> inviterNonce,
  required List<int> scannerNonce,
}) => hmacSha256(
  secret,
  domainSeparate(SigDomain.pairAck, [
    ...ascii.encode(_fp(inviterFingerprint)),
    ...ascii.encode(_fp(scannerFingerprint)),
    ...inviterNonce,
    ...scannerNonce,
  ]),
);

/// `HKDF-SHA256(ikm=S, salt=nA || nB, info="LSP-R1 pair" || min(fpA,fpB) || max(fpA,fpB), L=32)`.
/// The nonce order is fixed (inviter first); the fingerprint order is not.
Uint8List derivePairKey({
  required List<int> secret,
  required List<int> inviterNonce,
  required List<int> scannerNonce,
  required String fingerprintA,
  required String fingerprintB,
}) {
  final a = _fp(fingerprintA);
  final b = _fp(fingerprintB);
  final lo = a.compareTo(b) <= 0 ? a : b;
  final hi = a.compareTo(b) <= 0 ? b : a;
  return hkdfSha256(
    ikm: secret,
    salt: [...inviterNonce, ...scannerNonce],
    info: [
      ...ascii.encode(SigDomain.pairInfo),
      ...ascii.encode(lo),
      ...ascii.encode(hi),
    ],
    length: 32,
  );
}

/// What [PairingService.createInvite] hands to the UI for the QR code. The caller owns this copy
/// of `S`; the service keeps (and erases) its own.
final class PairInvite {
  PairInvite._(List<int> secret, this.expiresAt)
    : secret = Uint8List.fromList(secret),
      secretB64 = b64urlEncode(secret);

  final Uint8List secret;

  /// The `s=` value of the invite URI (43 characters).
  final String secretB64;
  final DateTime expiresAt;
}

/// The request being held for the inviter's decision.
final class PairPrompt {
  const PairPrompt._(this.sender, this.fingerprint);

  final DeviceInfo sender;

  /// The fingerprint the proof named (not the one the body claims).
  final String fingerprint;
}

class _Invite {
  _Invite(this.secret, this.expiresAt);
  final Uint8List secret;
  final DateTime expiresAt;
}

class _Held {
  _Held(this.prompt, this.decision);
  final PairPrompt prompt;
  final Completer<bool> decision;
}

Uint8List? _decodeFixed(String s, int bytes) {
  final chars = ((bytes * 8) + 5) ~/ 6;
  if (s.length != chars) return null;
  try {
    final d = b64urlDecode(s);
    return d.length == bytes ? d : null;
  } on FormatException {
    return null;
  }
}

void _zero(Uint8List b) {
  for (var i = 0; i < b.length; i++) {
    b[i] = 0;
  }
}

class PairingService {
  PairingService({
    required this.identity,
    required this.trust,
    required this.secrets,
    required this._self,
    this.clock = const SystemClock(),
    this.inviteTtl = const Duration(minutes: 10),
    this.holdTimeout = kPairTimeout,
    Uint8List Function(int length)? randomBytes,
    this._onEvent,
  }) : _random = randomBytes ?? secureRandomBytes;

  final IdentityProvider identity;
  final TrustStore trust;
  final SecretStore secrets;
  final Clock clock;
  final Duration inviteTtl;
  final Duration holdTimeout;
  final DeviceInfo Function() _self;
  final Uint8List Function(int) _random;
  final void Function(LsEvent)? _onEvent;

  _Invite? _invite;
  _Held? _held;

  String get _ownFp => identity.identity.fingerprint;

  void _emit(LsEvent e) {
    try {
      _onEvent?.call(e);
    } catch (_) {
      _log.warning('event listener threw');
    }
  }

  // ------------------------------------------------------------ inviter

  /// A new single-use invite secret valid for [inviteTtl]; replaces any earlier one.
  PairInvite createInvite() {
    _spend();
    final s = Uint8List.fromList(_random(_kSecretBytes));
    if (s.length != _kSecretBytes) {
      throw StateError('random source returned the wrong length');
    }
    final expires = clock.now().add(inviteTtl);
    _invite = _Invite(s, expires);
    return PairInvite._(s, expires);
  }

  bool get hasActiveInvite => _activeInvite() != null;

  /// The request currently held for the user, if any.
  PairPrompt? get pendingPrompt => _held?.prompt;

  _Invite? _activeInvite() {
    final inv = _invite;
    if (inv == null) return null;
    if (!clock.now().isBefore(inv.expiresAt)) {
      _spend();
      return null;
    }
    return inv;
  }

  void _spend() {
    final inv = _invite;
    if (inv == null) return;
    _zero(inv.secret);
    _invite = null;
  }

  /// `POST /pair` (LSP-1 4.3.4). The caller (HTTP layer) has already checked the rate limit, the
  /// body size and the proof; [peer] is what the proof named. Throws [LsException].
  Future<PairResponse> handlePair(
    PairRequest request, {
    required AuthenticatedPeer peer,
  }) async {
    final inv = _activeInvite();
    if (inv == null) throw LsException(LsErrorCode.notFound, 'not found');

    final nB = _decodeFixed(request.nonce, _kNonceBytes);
    final mac = _decodeFixed(request.mac, 32);
    if (nB == null || mac == null) {
      throw LsException(LsErrorCode.badRequest, 'malformed pairing request');
    }
    if (request.sender.version.split('.').first != '1') {
      throw LsException(
        LsErrorCode.upgradeRequired,
        'unsupported protocol version',
      );
    }
    final scannerFp = peer.fingerprint.toUpperCase();
    final claimed = request.sender.fingerprint.toUpperCase();
    final deviceId = peer.deviceId;
    if (claimed.isEmpty ||
        claimed != scannerFp ||
        !_fp64.hasMatch(scannerFp) ||
        deviceId == null ||
        deviceId != request.sender.deviceId) {
      throw LsException(LsErrorCode.authInvalid, 'sender does not match proof');
    }
    final expected = pairRequestMac(
      secret: inv.secret,
      scannerFingerprint: scannerFp,
      inviterFingerprint: _ownFp,
      scannerNonce: nB,
    );
    if (!constantTimeEquals(expected, mac)) {
      throw LsException(LsErrorCode.authInvalid, 'pairing proof invalid');
    }

    final info = trust.classify(deviceId, scannerFp);
    if (info.trust == PeerTrust.blocked) {
      throw LsException(LsErrorCode.blocked, 'sender is blocked');
    }
    if (info.keyChanged) {
      _emit(
        PeerKeyChanged(
          deviceId: deviceId,
          pinnedFingerprint: info.pinnedFingerprint ?? '',
          presentedFingerprint: scannerFp,
        ),
      );
      throw LsException(LsErrorCode.keyChanged, 'device key changed');
    }
    if (_held != null) {
      throw LsException(LsErrorCode.busy, 'another pairing request is pending');
    }

    // S is copied for the derivations below: the invite itself is spent (and erased) as soon as
    // the decision is in, and a new invite may replace it while the request is held.
    final s = Uint8List.fromList(inv.secret);
    try {
      final held = _Held(PairPrompt._(request.sender, scannerFp), Completer());
      _held = held;
      final timer = Timer(holdTimeout, () {
        if (!held.decision.isCompleted) held.decision.complete(false);
      });
      final bool accepted;
      try {
        accepted = await held.decision.future;
      } finally {
        timer.cancel();
        if (identical(_held, held)) _held = null;
      }

      // Either outcome spends the invite.
      if (identical(_invite, inv)) _spend();
      if (!accepted) return PairResponse(accepted: false, responder: _self());
      final nA = Uint8List.fromList(_random(_kNonceBytes));
      final ack = pairAckMac(
        secret: s,
        inviterFingerprint: _ownFp,
        scannerFingerprint: scannerFp,
        inviterNonce: nA,
        scannerNonce: nB,
      );
      final k = derivePairKey(
        secret: s,
        inviterNonce: nA,
        scannerNonce: nB,
        fingerprintA: _ownFp,
        fingerprintB: scannerFp,
      );
      final stored = await _storeContact(
        deviceId: deviceId,
        fingerprint: scannerFp,
        alias: request.sender.alias,
        kPair: k,
      );
      _zero(k);
      if (!stored) return PairResponse(accepted: false, responder: _self());
      return PairResponse(
        accepted: true,
        responder: _self(),
        nonce: b64urlEncode(nA),
        mac: b64urlEncode(ack),
      );
    } finally {
      _zero(s);
    }
  }

  /// Declines a held request (the owner is going away).
  void dispose() => decide(accept: false);

  /// The inviter's user decided. Ignored when nothing is held (a late tap after the timeout).
  void decide({required bool accept}) {
    final h = _held;
    if (h == null || h.decision.isCompleted) return;
    h.decision.complete(accept);
  }

  /// Pins [fingerprint] as trusted, stores K_pair, emits ContactChanged. False (nothing kept) when
  /// the trust store refuses.
  Future<bool> _storeContact({
    required String deviceId,
    required String fingerprint,
    required String alias,
    required Uint8List kPair,
  }) async {
    final key = 'kpair/$deviceId';
    var wasNew = false;
    var pinned = false;
    try {
      wasNew = !trust.contacts.any((c) => c.deviceId == deviceId);
      await secrets.put(key, Uint8List.fromList(kPair));
      try {
        await trust.pin(
          deviceId: deviceId,
          fingerprint: fingerprint,
          alias: alias,
          trust: PeerTrust.trusted,
        );
        pinned = true;
        await trust.setPairKey(deviceId, true);
      } on Object {
        try {
          await secrets.delete(key);
          if (pinned && wasNew) await trust.remove(deviceId);
        } on Object {
          _log.warning('pairing rollback incomplete');
        }
        rethrow;
      }
    } on KeyChangedException {
      _log.warning('pairing refused: key changed');
      return false;
    } on FingerprintInUseException {
      _log.warning('pairing refused: fingerprint in use');
      return false;
    } on RegistryFullException {
      _log.warning('pairing refused: contact list full');
      return false;
    } on ArgumentError {
      _log.warning('pairing refused: invalid contact data');
      return false;
    } on Object {
      _log.warning('pairing could not store the contact');
      return false;
    }
    _log.info('paired fp=${shortFp(fingerprint)}');
    _emit(ContactChanged(deviceId));
    return true;
  }

  // ------------------------------------------------------------ scanner

  /// The scanner side: B scanned A's QR. [inviter] is built from the URI (`id`, `fp`, `n`, ...).
  /// Throws [ArgumentError] for a malformed secret or inviter fingerprint.
  PairScan startScan({
    required String inviteSecretB64,
    required DeviceInfo inviter,
  }) {
    final s = _decodeFixed(inviteSecretB64, _kSecretBytes);
    if (s == null) throw ArgumentError.value('invalid', 'inviteSecretB64');
    final inviterFp = _fp(inviter.fingerprint);
    final nB = Uint8List.fromList(_random(_kNonceBytes));
    final mac = pairRequestMac(
      secret: s,
      scannerFingerprint: _ownFp,
      inviterFingerprint: inviterFp,
      scannerNonce: nB,
    );
    return PairScan._(
      this,
      s,
      inviter,
      inviterFp,
      nB,
      PairRequest(
        sender: _self(),
        nonce: b64urlEncode(nB),
        mac: b64urlEncode(mac),
      ),
    );
  }
}

/// One scan in progress: the request to send and the verification of the answer.
class PairScan {
  PairScan._(
    this._service,
    this._secret,
    this._inviter,
    this._inviterFp,
    this._nonce,
    this.request,
  );

  final PairingService _service;
  final Uint8List _secret;
  final DeviceInfo _inviter;
  final String _inviterFp;
  final Uint8List _nonce;
  bool _done = false;

  /// What to POST to `/pair`.
  final PairRequest request;

  /// Verifies the inviter's answer. False on `accepted:false` (nothing stored). On `accepted:true`
  /// the ack MAC must verify against S, the responder must be the device of the QR and the trust
  /// store must not refuse; then the inviter is pinned as trusted and K_pair stored. Throws
  /// [LsException] (`authInvalid` for a bad ack; `blocked` / `keyChanged` for a trust conflict).
  Future<bool> complete(PairResponse response) async {
    if (_done) throw LsException(LsErrorCode.wrongState, 'scan already used');
    if (!response.accepted) {
      _finish();
      return false;
    }
    final nA = response.nonce == null
        ? null
        : _decodeFixed(response.nonce!, _kNonceBytes);
    final mac = response.mac == null ? null : _decodeFixed(response.mac!, 32);
    final responder = response.responder;
    final fpOk =
        _fp64.hasMatch(responder.fingerprint) &&
        responder.fingerprint.toUpperCase() == _inviterFp;
    if (nA == null ||
        mac == null ||
        !fpOk ||
        responder.deviceId != _inviter.deviceId) {
      throw LsException(LsErrorCode.authInvalid, 'pairing answer invalid');
    }
    final expected = pairAckMac(
      secret: _secret,
      inviterFingerprint: _inviterFp,
      scannerFingerprint: _service._ownFp,
      inviterNonce: nA,
      scannerNonce: _nonce,
    );
    if (!constantTimeEquals(expected, mac)) {
      throw LsException(LsErrorCode.authInvalid, 'pairing answer invalid');
    }
    final info = _service.trust.classify(_inviter.deviceId, _inviterFp);
    if (info.trust == PeerTrust.blocked) {
      throw LsException(LsErrorCode.blocked, 'inviter is blocked');
    }
    if (info.keyChanged) {
      throw LsException(LsErrorCode.keyChanged, 'device key changed');
    }
    final k = derivePairKey(
      secret: _secret,
      inviterNonce: nA,
      scannerNonce: _nonce,
      fingerprintA: _inviterFp,
      fingerprintB: _service._ownFp,
    );
    final stored = await _service._storeContact(
      deviceId: _inviter.deviceId,
      fingerprint: _inviterFp,
      alias: responder.alias,
      kPair: k,
    );
    _zero(k);
    _finish();
    return stored;
  }

  void _finish() {
    _done = true;
    _zero(_secret);
  }
}
