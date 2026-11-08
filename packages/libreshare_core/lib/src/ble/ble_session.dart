import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../security/cert_factory.dart';
import '../security/contracts.dart';
import '../security/crypto_primitives.dart';
import '../security/identity_proof.dart' show verifySignature;
import '../security/sas.dart';
import 'ble_backend.dart';
import 'ble_crypto.dart';
import 'ble_messages.dart';
import 'gatt_frame_codec.dart';

enum BleSessionRole { central, peripheral }

enum BleSessionState {
  idle,
  handshaking,
  authenticated,
  offered,
  agreed,
  closed,
}

class BleSessionAuthResult {
  const BleSessionAuthResult({
    required this.peerFingerprint,
    required this.peerAlias,
    required this.peerPlatform,
    required this.lanCandidates,
    required this.sasCode,
    required this.isPaired,
  });

  final String peerFingerprint;
  final String peerAlias;
  final String peerPlatform;
  final List<LanCandidate> lanCandidates;
  final String sasCode;
  final bool isPaired;
}

class BleSecurityException implements Exception {
  const BleSecurityException(this.message);
  final String message;

  @override
  String toString() => 'BleSecurityException: $message';
}

/// Orchestrates an authenticated, encrypted LS-BLE/1 control session over GATT.
class BleSession {
  BleSession({
    required this.gatt,
    required this.role,
    required this.identity,
    this.trustStore,
    this.expectedPeerFingerprint,
    this.mtu = kDefaultGattMtu,
  });

  final BleGattSession gatt;
  final BleSessionRole role;
  final IdentityProvider identity;
  final TrustStore? trustStore;
  final String? expectedPeerFingerprint;
  final int mtu;

  BleSessionState _state = BleSessionState.idle;
  BleSessionState get state => _state;

  final GattFrameReassembler _reassembler = GattFrameReassembler();
  BleAeadCipher? _sendCipher;
  BleAeadCipher? _recvCipher;
  BleSessionAuthResult? _authResult;

  BleSessionAuthResult? get authResult => _authResult;

  final StreamController<BleMessage> _messageController =
      StreamController<BleMessage>.broadcast();

  Stream<BleMessage> get incomingMessages => _messageController.stream;
  StreamSubscription<List<int>>? _gattSub;

  /// Performs the M1/M2/AUTH cryptographic handshake.
  Future<BleSessionAuthResult> performHandshake({
    required String localAlias,
    required String localPlatform,
    List<LanCandidate> localLanCandidates = const [],
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (_state != BleSessionState.idle) {
      throw StateError('Handshake already performed or in progress');
    }
    _state = BleSessionState.handshaking;

    final completer = Completer<BleSessionAuthResult>();

    // Direct frame collector for initial handshake
    final handshakeFrames = StreamController<List<int>>();
    _gattSub = gatt.received.listen(
      (frame) {
        if (_state == BleSessionState.handshaking) {
          handshakeFrames.add(frame);
        } else {
          _onEncryptedFrame(frame);
        }
      },
      onError: (Object e) {
        _fail(BleSecurityException('GATT transport error: $e'));
      },
      onDone: () {
        _state = BleSessionState.closed;
      },
    );

    unawaited(
      _driveHandshake(
        handshakeFrames.stream,
        localAlias: localAlias,
        localPlatform: localPlatform,
        localLanCandidates: localLanCandidates,
      ).then(
        completer.complete,
        onError: (Object err) {
          final secErr = err is BleSecurityException
              ? err
              : BleSecurityException('Handshake failed: $err');
          _fail(secErr);
          if (!completer.isCompleted) completer.completeError(secErr);
        },
      ),
    );

    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _fail(const BleSecurityException('Handshake timed out'));
        throw const BleSecurityException('Handshake timed out');
      },
    );
  }

  Future<BleSessionAuthResult> _driveHandshake(
    Stream<List<int>> handshakeStream, {
    required String localAlias,
    required String localPlatform,
    required List<LanCandidate> localLanCandidates,
  }) async {
    final epkPair = BleEphemeralKeyPair.generate();
    final nonce = generateBleNonce();

    final frameIterator = StreamIterator(handshakeStream);

    Future<Uint8List> nextMessage() async {
      final reassembler = GattFrameReassembler();
      while (await frameIterator.moveNext()) {
        final complete = reassembler.processFrame(frameIterator.current);
        if (complete != null) return complete;
      }
      throw const BleSecurityException(
        'GATT channel closed prematurely during handshake',
      );
    }

    final BleM1 m1;
    final BleM2 m2;
    final String peerEpkBase64;

    if (role == BleSessionRole.central) {
      m1 = BleM1(epk: epkPair.publicKeyBase64, n: nonce);
      await _sendRawMessage(m1.encode());

      final m2Bytes = await nextMessage();
      final m2Json = jsonDecode(utf8.decode(m2Bytes)) as Map<String, Object?>;
      m2 = BleM2.fromJson(m2Json);
      peerEpkBase64 = m2.epk;
    } else {
      final m1Bytes = await nextMessage();
      final m1Json = jsonDecode(utf8.decode(m1Bytes)) as Map<String, Object?>;
      m1 = BleM1.fromJson(m1Json);
      peerEpkBase64 = m1.epk;

      m2 = BleM2(epk: epkPair.publicKeyBase64, n: nonce, capEcho: 0);
      await _sendRawMessage(m2.encode());
    }

    final sharedSecret = epkPair.calculateSharedSecret(peerEpkBase64);
    final transcriptHash = computeTranscriptHash(m1, m2);

    final (kC2P, kP2C) = deriveChannelKeys(
      sharedSecret: sharedSecret,
      transcriptHash: transcriptHash,
    );

    if (role == BleSessionRole.central) {
      _sendCipher = BleAeadCipher(
        key: kC2P,
        direction: 1,
        transcriptHash: transcriptHash,
      );
      _recvCipher = BleAeadCipher(
        key: kP2C,
        direction: 2,
        transcriptHash: transcriptHash,
      );
    } else {
      _sendCipher = BleAeadCipher(
        key: kP2C,
        direction: 2,
        transcriptHash: transcriptHash,
      );
      _recvCipher = BleAeadCipher(
        key: kC2P,
        direction: 1,
        transcriptHash: transcriptHash,
      );
    }

    // Build and send local AUTH
    final authDomain = role == BleSessionRole.central
        ? kBleAuthDomainCentral
        : kBleAuthDomainPeripheral;
    final sigBytes = identity.sign(authDomain, transcriptHash);

    final localAuth = BleAuth(
      certDerB64: base64Encode(identity.identity.certDer),
      sigB64: base64Encode(sigBytes),
      alias: localAlias,
      platform: localPlatform,
      lanCands: localLanCandidates,
    );

    final BleAuth peerAuth;
    if (role == BleSessionRole.central) {
      await _sendEncryptedMessage(localAuth);
      final rawPeerAuth = await nextMessage();
      final decrypted = _recvCipher!.open(rawPeerAuth);
      peerAuth = BleAuth.fromJson(
        jsonDecode(utf8.decode(decrypted)) as Map<String, Object?>,
      );
    } else {
      final rawPeerAuth = await nextMessage();
      final decrypted = _recvCipher!.open(rawPeerAuth);
      peerAuth = BleAuth.fromJson(
        jsonDecode(utf8.decode(decrypted)) as Map<String, Object?>,
      );
      await _sendEncryptedMessage(localAuth);
    }

    // Verify peer identity & signature
    final peerCertBytes = base64Decode(peerAuth.certDerB64);
    final peerFp = fingerprintHex(peerCertBytes);
    parseCertificate(peerCertBytes); // Validates valid DER structure

    final expectedDomain = role == BleSessionRole.central
        ? kBleAuthDomainPeripheral
        : kBleAuthDomainCentral;
    final peerSig = base64Decode(peerAuth.sigB64);

    final verified = verifySignature(
      certDer: peerCertBytes,
      domain: expectedDomain,
      message: transcriptHash,
      signature: peerSig,
    );
    if (!verified) {
      throw const BleSecurityException(
        'Peer AUTH signature verification failed',
      );
    }

    if (expectedPeerFingerprint != null &&
        expectedPeerFingerprint!.toUpperCase() != peerFp) {
      throw BleSecurityException(
        'Peer certificate fingerprint mismatch: expected $expectedPeerFingerprint, got $peerFp',
      );
    }

    // Evaluate trust status
    var paired = false;
    if (trustStore != null) {
      final classification = trustStore!.classifyFingerprint(peerFp);
      paired =
          classification.trust == PeerTrust.trusted ||
          classification.trust == PeerTrust.known;
    }

    final String clientFp;
    final String serverFp;
    if (role == BleSessionRole.central) {
      clientFp = identity.identity.fingerprint;
      serverFp = peerFp;
    } else {
      clientFp = peerFp;
      serverFp = identity.identity.fingerprint;
    }

    final sas = sasCode(
      ns: base64Decode(m1.n),
      nr: base64Decode(m2.n),
      fingerprintA: clientFp,
      fingerprintB: serverFp,
    );

    _authResult = BleSessionAuthResult(
      peerFingerprint: peerFp,
      peerAlias: peerAuth.alias,
      peerPlatform: peerAuth.platform,
      lanCandidates: peerAuth.lanCands,
      sasCode: sas,
      isPaired: paired,
    );

    _state = BleSessionState.authenticated;
    return _authResult!;
  }

  void _onEncryptedFrame(List<int> frame) {
    try {
      final complete = _reassembler.processFrame(frame);
      if (complete != null) {
        final plaintext = _recvCipher!.open(complete);
        final json = jsonDecode(utf8.decode(plaintext)) as Map<String, Object?>;
        final msg = BleMessage.fromJson(json);
        _messageController.add(msg);
      }
    } on Object catch (e) {
      _fail(BleSecurityException('Encrypted message decoding failed: $e'));
    }
  }

  /// Sends an encrypted application message over GATT.
  Future<void> send(BleMessage message) async {
    if (_state == BleSessionState.closed || _state == BleSessionState.idle) {
      throw StateError('Cannot send message in state $_state');
    }
    await _sendEncryptedMessage(message);
    if (message is BleOffer) {
      _state = BleSessionState.offered;
    } else if (message is BleNetPlan || message is BleDecision) {
      _state = BleSessionState.agreed;
    }
  }

  Future<void> _sendRawMessage(String text) async {
    final bytes = utf8.encode(text);
    final frames = fragmentMessage(bytes, mtu: mtu);
    for (final frame in frames) {
      await gatt.send(frame);
    }
  }

  Future<void> _sendEncryptedMessage(BleMessage message) async {
    final plaintext = utf8.encode(message.encode());
    final ciphertext = _sendCipher!.seal(plaintext);
    final frames = fragmentMessage(ciphertext, mtu: mtu);
    for (final frame in frames) {
      await gatt.send(frame);
    }
  }

  void _fail(BleSecurityException error) {
    if (_state != BleSessionState.closed) {
      _state = BleSessionState.closed;
      _messageController.addError(error);
      unawaited(close());
    }
  }

  Future<void> close() async {
    _state = BleSessionState.closed;
    await _gattSub?.cancel();
    _gattSub = null;
    _reassembler.dispose();
    await _messageController.close();
    await gatt.close();
  }
}
