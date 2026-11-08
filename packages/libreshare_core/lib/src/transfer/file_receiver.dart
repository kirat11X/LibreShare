/// FileReceiver (UML 7.0): the receiving side of LSP/1 (spec §4.3, §4.4, §5, §8).
///
/// Implements [IncomingTransferHandler] without any HTTP knowledge: the
/// ApiServer maps [LsException]s to the spec error envelope.
///
/// Per file: chunks are written at their offset into `<target>.lspart` (or
/// `<partialDir>/<hash>.lspart`), the received-chunk bitmap lives in a
/// [ResumeStore] sidecar, and on `complete` the whole file is hashed in an
/// isolate and compared with the manifest hash before an atomic rename.
/// Nothing the sender controls is trusted: names go through
/// `filename_sanitizer.dart`, tokens are compared in constant time and never
/// logged, sizes/chunk counts/limits are validated up front.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../clock.dart';
import '../model/device.dart';
import '../model/events.dart';
import '../model/file_item.dart';
import '../model/ls_exception.dart';
import '../security/contracts.dart';
import '../security/crypto_primitives.dart'
    show b64urlDecode, b64urlEncode, secureRandomBytes;
import '../security/pairing_service.dart';
import '../security/sas.dart';
import '../model/session_models.dart';
import '../model/transfer_status.dart';
import '../protocol.dart';
import '../server/incoming_transfer_handler.dart';
import '../storage/atomic_file.dart';
import 'chunker.dart';
import 'filename_sanitizer.dart';
import 'hashing.dart';
import 'resume_store.dart';

final Logger _log = Logger('FileReceiver');

const int _kMinChunkSize = 64 * 1024;
const int _kMaxChunkSize = 16 * 1024 * 1024;
const int _kMaxFileSize = 1 << 48; // 256 TiB; keeps sums far from overflow
const int _kMaxFileIdLength = 128;
final RegExp _hex64 = RegExp(r'^[0-9a-fA-F]{64}$');

/// Free bytes on the file system holding [dir], or null if unknown.
typedef FreeSpaceProbe = Future<int?> Function(Directory dir);

class _FileEntry {
  _FileEntry({
    required this.item,
    required this.token,
    required this.target,
    required this.partial,
  });

  final FileItem item;
  final String token;
  File target; // may change at completion if the name got taken meanwhile
  final File partial;
  final List<String> reservedKeys = [];

  ResumeStore? store;
  Future<ResumeStore>? storeFuture;
  int bytesDone = 0;
  bool verified = false;
  bool discarded = false; // partial + sidecar deleted; never flush again
  FileVerification? verification;
  Future<FileVerification>? completion;

  Sha256Incremental? runningHasher;
  int nextExpectedChunkIndex = 0;
  bool canUseRunningHash = true;
}

class _Session {
  _Session(this.id, this.request, DateTime now, this.remoteAddress)
    : lastActivity = now;

  final String id;
  final SessionRequest request;
  final String remoteAddress;

  /// Secure profile: who the proof named, and how the trust store classified it at creation.
  AuthenticatedPeer? peer;
  PeerTrust trust = PeerTrust.unknown;

  /// SAS (LSP-1 5.1): the sender's commitment, our nonce Nr, the code once the reveal verified.
  String? sasCommit;
  Uint8List? sasNr;
  bool sasRevealed = false;
  String? sasCode;
  Timer? sasTimer;
  int get chunkSize => request.chunkSize;
  TransferStatus status = TransferStatus.pending;
  FailureReason? failureReason;
  final Map<String, _FileEntry> files = {};
  DateTime lastActivity;
  Timer? permissionTimer;
  final List<Completer<void>> waiters = [];
}

/// Drops the running whole-file digest, if any, and frees its native state.
void _releaseRunningHash(_FileEntry f) {
  final h = f.runningHasher;
  f.runningHasher = null;
  h?.dispose();
}

/// Finishes the running whole-file digest and frees its native state.
String _finishRunningHash(_FileEntry f) {
  final h = f.runningHasher!;
  f.runningHasher = null;
  try {
    return h.finishHex();
  } finally {
    h.dispose();
  }
}

class FileReceiver implements SecureTransferHandler {
  FileReceiver({
    required this.self,
    required this.downloadDir,
    this.partialDir,
    this.autoAccept = true,
    this.clock = const SystemClock(),
    this.minFreeBytesMargin = 64 * 1024 * 1024,
    this._onEvent,
    this.permissionTimeout = kPermissionTimeout,
    FreeSpaceProbe? freeSpaceProbe,
    this.sessionTtl = kResumeWindow,
    this.selfProvider,
    this.security = const SecurityConfig.plaintext(),
    this.pinVerifier,
    this.pairing,
  }) : _freeSpaceProbe = freeSpaceProbe ?? _dfFreeBytes;

  /// Our own identity, returned by [deviceInfo] / [register] unless
  /// [selfProvider] is given.
  final DeviceInfo self;

  /// Evaluated on every `GET /info` and `POST /register`, so the identity
  /// reports what is true now: the port the listener really bound (after the
  /// FR-01 fallback) and the current local addresses. Null: [self] as given.
  final DeviceInfo Function()? selfProvider;

  /// Secure profile (trust classification, SAS, consent policy). Plaintext = Inc 1 behaviour.
  final SecurityConfig security;

  /// PIN enforcement (P3's PinGuard); null = no PIN.
  final PinVerifier? pinVerifier;

  /// QR pairing (`POST /pair`); null = the route answers 404.
  final PairingService? pairing;

  final Directory downloadDir;

  /// Where `.lspart` files live; null = next to the final file.
  final Directory? partialDir;

  /// true: sessions start IN_PROGRESS immediately. false: PENDING until
  /// [accept] / [reject] / [permissionTimeout].
  final bool autoAccept;
  final Clock clock;
  final int minFreeBytesMargin;
  final Duration permissionTimeout;

  /// Idle sessions (and their in-memory state) are dropped after this long.
  final Duration sessionTtl;

  final void Function(LsEvent)? _onEvent;
  final FreeSpaceProbe _freeSpaceProbe;

  final Random _rng = Random.secure();
  final Map<String, _Session> _sessions = {};

  /// Serialises steps 10-13 of requests that need a PIN, so a one-time PIN is checked and
  /// consumed atomically. Every gate is completed in a `finally`.
  Future<void> _pinTail = Future<void>.value();

  /// Lower-cased absolute paths of in-flight targets and their partial files.
  final Set<String> _reserved = {};

  // ------------------------------------------------------------------ info

  @override
  DeviceInfo get deviceInfo => selfProvider?.call() ?? self;

  @override
  DeviceInfo register(DeviceInfo peer) => deviceInfo;

  /// While false, [createSession] answers `409 BUSY`: the Receive window has
  /// ended and the transfers that are still running are being drained (design
  /// 01 section 1.1, Draining). Sessions already created are unaffected.
  bool acceptingSessions = true;

  /// Sessions that are pending (awaiting [accept]) or in progress.
  int get activeSessionCount => _countActive();

  /// Emits [activeSessionCount] whenever it changes.
  Stream<int> get activeSessionCountChanges => _activeChanges.stream;

  final StreamController<int> _activeChanges =
      StreamController<int>.broadcast();
  int _lastActive = 0;

  int _countActive() {
    var n = 0;
    for (final s in _sessions.values) {
      if (!s.status.isTerminal) n++;
    }
    return n;
  }

  void _notifyActive() {
    final n = _countActive();
    if (n == _lastActive) return;
    _lastActive = n;
    if (!_activeChanges.isClosed) _activeChanges.add(n);
  }

  /// Session ids waiting for [accept] / [reject].
  List<String> get pendingSessionIds => [
    for (final s in _sessions.values)
      if (s.status == TransferStatus.pending) s.id,
  ];

  /// The manifest of a known session (for the consent prompt), else null.
  SessionRequest? requestFor(String sessionId) => _sessions[sessionId]?.request;

  /// Cancels permission timers and wakes long-pollers. Safe to call twice.
  void dispose() {
    pairing?.dispose();
    for (final s in _sessions.values) {
      s.permissionTimer?.cancel();
      s.permissionTimer = null;
      s.sasTimer?.cancel();
      s.sasTimer = null;
      _wake(s);
    }
    if (!_activeChanges.isClosed) unawaited(_activeChanges.close());
  }

  // --------------------------------------------------------------- session

  @override
  Future<SessionStatus> createSession(
    SessionRequest request, {
    required String remoteAddress,
  }) async {
    if (security.isSecure) {
      // A secure receiver never creates a session without a proof (LSP-1 4.3.4 step 4).
      throw LsException(LsErrorCode.authInvalid, 'identity proof required');
    }
    if (!acceptingSessions) {
      throw LsException(LsErrorCode.busy, 'not accepting new sessions');
    }
    _evictExpired();
    _validate(request);
    _checkDownloadDir();
    await _checkFreeSpace(request.totalSize);
    return _open(request, remoteAddress, autoStart: autoAccept);
  }

  /// Secure profile, LSP-1 4.3.4 "Secure-profile order" from step 7 on. The gate, rate limit, body
  /// size, version and the proof itself belong to the HTTP layer; [peer] is what the proof named.
  @override
  Future<SessionStatus> createAuthenticatedSession(
    SessionRequest request, {
    required String remoteAddress,
    required AuthenticatedPeer? peer,
  }) async {
    final trustStore = security.trust;
    if (!security.isSecure || trustStore == null) {
      return createSession(request, remoteAddress: remoteAddress);
    }
    if (peer == null) {
      throw LsException(LsErrorCode.authInvalid, 'identity proof required');
    }
    _evictExpired();
    // 5/7 shape and consistency
    _validate(request);
    final commit = request.sasCommit;
    if (commit != null && !_isCommit(commit)) {
      throw LsException(LsErrorCode.badRequest, 'malformed sasCommit');
    }
    final pin = request.pin;
    if (pin != null && !RegExp(r'^[0-9]{6}$').hasMatch(pin)) {
      throw LsException(LsErrorCode.badRequest, 'pin must be 6 digits');
    }
    // 8 sender match: the body names the device, the proof names the key.
    final claimed = request.sender.fingerprint.toUpperCase();
    final deviceId = peer.deviceId;
    if (claimed.isEmpty ||
        claimed != peer.fingerprint.toUpperCase() ||
        deviceId == null ||
        deviceId != request.sender.deviceId) {
      throw LsException(LsErrorCode.authInvalid, 'sender does not match proof');
    }
    // 9 trust
    final info = trustStore.classify(deviceId, peer.fingerprint);
    if (info.trust == PeerTrust.blocked) {
      throw LsException(LsErrorCode.blocked, 'sender is blocked');
    }
    if (info.keyChanged) {
      _log.warning(
        'key change refused: pinned fp=${shortFp(info.pinnedFingerprint ?? '')} '
        'presented fp=${shortFp(peer.fingerprint)}',
      );
      _emit(
        PeerKeyChanged(
          deviceId: deviceId,
          pinnedFingerprint: info.pinnedFingerprint ?? '',
          presentedFingerprint: peer.fingerprint,
        ),
      );
      throw LsException(LsErrorCode.keyChanged, 'device key changed');
    }
    // 10 PIN
    final verifier = pinVerifier;
    final exempt =
        info.trust == PeerTrust.trusted && security.pin.exemptContacts;
    final needsPin = verifier != null && verifier.enforced && !exempt;

    Future<SessionStatus> rest() async {
      if (verifier != null && verifier.enforced) {
        verifier.check(
          remoteAddress: remoteAddress,
          pin: request.pin,
          exempt: exempt,
        );
      }
      // 11 storage
      _checkDownloadDir();
      await _checkFreeSpace(request.totalSize);
      // 12 pending prompts (no await from here to the registration of the session)
      final consent = security.consent;
      var pendingTotal = 0;
      var pendingFromIp = 0;
      for (final s in _sessions.values) {
        if (s.status != TransferStatus.pending) continue;
        pendingTotal++;
        if (s.remoteAddress == remoteAddress) pendingFromIp++;
      }
      if (pendingFromIp >= consent.maxPendingPerIp ||
          pendingTotal >= consent.maxPendingTotal) {
        throw LsException(
          LsErrorCode.rateLimited,
          'too many pending requests',
          const Duration(seconds: 30),
        );
      }
      // 13 busy
      if (!acceptingSessions) {
        throw LsException(LsErrorCode.busy, 'not accepting new sessions');
      }
      // A request that carries a commitment is never auto-accepted, whatever the trust level or
      // the operator flag: the human comparison must happen (LSP-1 5.1).
      final auto =
          commit == null &&
          (autoAccept ||
              (info.trust == PeerTrust.trusted && consent.autoAcceptTrusted));
      return _open(
        request,
        remoteAddress,
        autoStart: auto,
        peer: peer,
        trust: info.trust,
        sasCommit: commit,
        onRegistered: needsPin ? verifier.consume : null,
      );
    }

    if (!needsPin) return rest();
    final prev = _pinTail;
    final gate = Completer<void>();
    _pinTail = gate.future;
    await prev;
    try {
      return await rest();
    } finally {
      gate.complete();
    }
  }

  Future<SessionStatus> _open(
    SessionRequest request,
    String remoteAddress, {
    required bool autoStart,
    AuthenticatedPeer? peer,
    PeerTrust trust = PeerTrust.unknown,
    String? sasCommit,
    void Function()? onRegistered,
  }) async {
    var sid = _newSessionId();
    while (_sessions.containsKey(sid)) {
      sid = _newSessionId();
    }
    final s = _Session(sid, request, clock.now(), remoteAddress)
      ..peer = peer
      ..trust = trust;
    try {
      _plan(s);
    } catch (_) {
      _release(s);
      rethrow;
    }
    if (sasCommit != null) {
      s.sasCommit = sasCommit;
      s.sasNr = secureRandomBytes(kSasNonceBytes);
    }
    _sessions[sid] = s;
    _notifyActive();
    onRegistered?.call();
    _log.fine(
      'session ${_short(sid)} from $remoteAddress: ${request.files.length} '
      'file(s), ${request.totalSize} bytes',
    );
    if (!autoStart) {
      s.permissionTimer = Timer(permissionTimeout, () {
        if (s.status == TransferStatus.pending) {
          _setStatus(s, TransferStatus.failed, FailureReason.timeout);
        }
      });
      if (s.sasCommit != null) {
        s.sasTimer = Timer(kSasRevealTimeout, () {
          if (s.status == TransferStatus.pending && !s.sasRevealed) {
            _setStatus(s, TransferStatus.failed, FailureReason.timeout);
          }
        });
      }
    }
    _emit(SessionCreated(sid, outgoing: false));
    if (autoStart) await _start(s);
    return _snapshot(s);
  }

  /// Consent granted: PENDING -> IN_PROGRESS with tokens.
  Future<SessionStatus> accept(String sessionId) async {
    final s = _session(sessionId);
    if (s.status != TransferStatus.pending) {
      throw LsException(LsErrorCode.wrongState, 'session is not pending');
    }
    // The code must exist first, or a sender that never reveals would bypass the SAS.
    if (s.sasCommit != null && s.sasCode == null) {
      throw LsException(LsErrorCode.wrongState, 'verification code not ready');
    }
    final peer = s.peer;
    final trustStore = security.trust;
    final deviceId = peer?.deviceId;
    if (peer != null && trustStore != null && deviceId != null) {
      // The user may have blocked the sender, or changed its pin, while the prompt was open.
      final now = trustStore.classify(deviceId, peer.fingerprint);
      if (now.trust == PeerTrust.blocked || now.keyChanged) {
        _setStatus(s, TransferStatus.failed, FailureReason.rejected);
        throw LsException(
          now.trust == PeerTrust.blocked
              ? LsErrorCode.blocked
              : LsErrorCode.keyChanged,
          'sender no longer acceptable',
        );
      }
    }
    s.permissionTimer?.cancel();
    s.permissionTimer = null;
    s.sasTimer?.cancel();
    s.sasTimer = null;
    await _start(s);
    if (s.sasCode != null) await _pinAfterSas(s);
    return _snapshot(s);
  }

  /// LSP-1 5.1: after the user accepted a SAS-confirmed first contact, the sender is pinned as
  /// `known` (TOFU). A plain unknown sender (no SAS happened) is not pinned, trust is never
  /// lowered and a pinned key is never replaced.
  Future<void> _pinAfterSas(_Session s) async {
    final peer = s.peer;
    final trustStore = security.trust;
    final deviceId = peer?.deviceId;
    if (peer == null || trustStore == null || deviceId == null) return;
    final now = trustStore.classify(deviceId, peer.fingerprint);
    if (now.trust != PeerTrust.unknown || now.keyChanged) return;
    try {
      await trustStore.pin(
        deviceId: deviceId,
        fingerprint: peer.fingerprint,
        alias: s.request.sender.alias,
        trust: PeerTrust.known,
      );
    } on Exception {
      _log.warning('could not pin the sender of session ${_short(s.id)}');
      return;
    } on ArgumentError {
      _log.warning('could not pin the sender of session ${_short(s.id)}');
      return;
    }
    _emit(ContactChanged(deviceId));
  }

  /// Consent refused: PENDING -> FAILED(REJECTED).
  Future<void> reject(String sessionId) async {
    final s = _session(sessionId);
    if (s.status != TransferStatus.pending) {
      throw LsException(LsErrorCode.wrongState, 'session is not pending');
    }
    _setStatus(s, TransferStatus.failed, FailureReason.rejected);
    _recordReject(s);
  }

  // ------------------------------------------------------- block suggestion

  static const int _kBlockSuggestAfter = 3;
  static const Duration _kBlockSuggestWindow = Duration(minutes: 10);

  /// User rejects per authenticated fingerprint inside the window. Timeouts, cancels and
  /// auto-declines never reach here. The receiver only suggests; it never blocks by itself.
  final Map<String, List<DateTime>> _rejects = {};

  void _recordReject(_Session s) {
    final peer = s.peer;
    final deviceId = peer?.deviceId;
    if (peer == null || deviceId == null) return;
    final now = clock.now();
    _rejects.removeWhere(
      (_, v) => v.every((t) => now.difference(t) > _kBlockSuggestWindow),
    );
    final list = _rejects.putIfAbsent(peer.fingerprint, () => <DateTime>[])
      ..removeWhere((t) => now.difference(t) > _kBlockSuggestWindow)
      ..add(now);
    if (list.length >= _kBlockSuggestAfter) {
      final count = list.length;
      _rejects.remove(peer.fingerprint);
      _emit(
        BlockSuggested(
          deviceId: deviceId,
          fingerprint: peer.fingerprint,
          alias: s.request.sender.alias,
          rejectCount: count,
        ),
      );
    }
  }

  // -------------------------------------------------------------------- SAS

  @override
  Future<SessionStatus> revealSas(
    String sessionId, {
    required String nonce,
    required AuthenticatedPeer? peer,
  }) async {
    final identity = security.identity;
    if (identity == null) {
      throw LsException(LsErrorCode.notFound, 'not found');
    }
    final s = _session(sessionId);
    final owner = s.peer;
    // The proof must name the session's sender. A foreign proof is refused but is not fatal:
    // anyone who learns a session id must not be able to abort a pending prompt.
    if (peer == null ||
        owner == null ||
        peer.fingerprint.toUpperCase() != owner.fingerprint.toUpperCase()) {
      throw LsException(
        LsErrorCode.authInvalid,
        'proof does not match session',
      );
    }
    if (s.status == TransferStatus.failed &&
        s.failureReason == FailureReason.cancelled) {
      throw LsException(LsErrorCode.cancelled, 'session cancelled');
    }
    final commit = s.sasCommit;
    if (s.status != TransferStatus.pending || commit == null || s.sasRevealed) {
      throw LsException(LsErrorCode.wrongState, 'no SAS reveal expected');
    }
    final ns = _decodeNonce(nonce);
    if (ns == null) {
      throw LsException(LsErrorCode.badRequest, 'malformed nonce');
    }
    final ownFp = identity.identity.fingerprint;
    if (!sasCommitMatches(
      commit: commit,
      ns: ns,
      senderFingerprint: owner.fingerprint,
      receiverFingerprintSeenBySender: ownFp,
    )) {
      _setStatus(s, TransferStatus.failed, FailureReason.protocolError);
      throw LsException(LsErrorCode.authInvalid, 'SAS commitment mismatch');
    }
    final code = sasCode(
      ns: ns,
      nr: s.sasNr!,
      fingerprintA: owner.fingerprint,
      fingerprintB: ownFp,
    );
    s.sasRevealed = true;
    s.sasCode = code;
    s.sasTimer?.cancel();
    s.sasTimer = null;
    _emit(SasReady(s.id, code, outgoing: false));
    return _snapshot(s);
  }

  @override
  Future<PairResponse> pair(
    PairRequest request, {
    required String remoteAddress,
    required AuthenticatedPeer peer,
  }) async {
    final service = pairing;
    if (!security.isSecure || service == null) {
      throw LsException(LsErrorCode.notFound, 'not found');
    }
    return service.handlePair(request, peer: peer);
  }

  @override
  IncomingSessionInfo? incomingInfo(String sessionId) {
    final s = _sessions[sessionId];
    if (s == null) return null;
    return IncomingSessionInfo(
      sessionId: s.id,
      peer: s.peer,
      trust: s.trust,
      sasRequired: s.sasCommit != null,
      sasCode: s.sasCode,
    );
  }

  @override
  Future<SessionStatus> getSession(
    String sessionId, {
    Duration wait = Duration.zero,
  }) async {
    final s = _session(sessionId);
    if (wait > Duration.zero && s.status == TransferStatus.pending) {
      final c = Completer<void>();
      s.waiters.add(c);
      try {
        await c.future.timeout(wait, onTimeout: () {});
      } finally {
        s.waiters.remove(c);
      }
      s.lastActivity = clock.now();
    }
    return _snapshot(s);
  }

  // ----------------------------------------------------------------- state

  @override
  Future<FileState> fileState(
    String sessionId,
    String fileId, {
    required String token,
  }) async {
    final s = _session(sessionId);
    final f = _authorize(s, fileId, token);
    _requireInProgress(s);
    return FileState(
      receivedRanges: f.store?.ranges ?? const [],
      chunkCount: f.item.chunkCount,
    );
  }

  // ----------------------------------------------------------------- chunk

  @override
  Future<void> putChunk(
    String sessionId,
    String fileId,
    int index,
    Stream<List<int>> body, {
    required String token,
    String? chunkSha256,
  }) async {
    final s = _session(sessionId);
    final f = _authorize(s, fileId, token);
    _requireInProgress(s);
    if (f.verified) {
      throw LsException(LsErrorCode.wrongState, 'file already completed');
    }
    if (index < 0 || index >= f.item.chunkCount) {
      throw LsException(
        LsErrorCode.outOfRange,
        'chunk index $index outside 0..${f.item.chunkCount - 1}',
      );
    }
    String? expectedHash;
    if (chunkSha256 != null) {
      if (!_hex64.hasMatch(chunkSha256)) {
        throw LsException(LsErrorCode.badRequest, 'malformed chunk hash');
      }
      expectedHash = chunkSha256.toLowerCase();
    }
    final range = Chunker(s.chunkSize).range(f.item.size, index);
    final expected = range.length;

    final store = await _ensureStore(s, f);
    _requireInProgress(s);
    final already = store.has(index);

    final inOrderForRunning =
        f.canUseRunningHash && index == f.nextExpectedChunkIndex && !already;
    if (inOrderForRunning) {
      f.runningHasher ??= newSha256Incremental();
    } else {
      f.canUseRunningHash = false;
      _releaseRunningHash(f);
    }
    final hasher = newSha256Incremental();
    var received = 0;
    var chunkOk = false;
    RandomAccessFile? raf;

    try {
      if (!already) {
        raf = await f.partial.open(mode: FileMode.append);
      }
      await for (final piece in body) {
        if (received + piece.length > expected) {
          throw LsException(
            LsErrorCode.outOfRange,
            'chunk $index is longer than its declared length $expected',
          );
        }
        hasher.add(piece);
        if (inOrderForRunning && f.runningHasher != null) {
          f.runningHasher!.add(piece);
        }
        if (raf != null && piece.isNotEmpty) {
          await raf.setPosition(range.start + received);
          await raf.writeFrom(piece);
        }
        received += piece.length;
      }
      if (received < expected) {
        throw LsException(
          LsErrorCode.badRequest,
          'chunk $index has $received of $expected bytes',
        );
      }
      final chunkHex = hasher.finishHex();
      if (expectedHash != null && chunkHex != expectedHash) {
        if (inOrderForRunning) {
          f.canUseRunningHash = false;
          _releaseRunningHash(f);
        }
        throw LsException(
          LsErrorCode.chunkHashMismatch,
          'chunk $index failed its SHA-256 check',
        );
      }
      if (inOrderForRunning) {
        f.nextExpectedChunkIndex++;
      }
      chunkOk = true;
    } on FileSystemException catch (e) {
      if (s.status != TransferStatus.inProgress) _throwStateError(s);
      if (_isDiskFull(e)) {
        _setStatus(s, TransferStatus.failed, FailureReason.diskFull);
        throw LsException(
          LsErrorCode.insufficientStorage,
          'no space left on device',
        );
      }
      _log.warning('chunk write failed: ${e.message}');
      throw LsException(LsErrorCode.internal, 'chunk write failed');
    } finally {
      hasher.dispose();
      if (!chunkOk && inOrderForRunning) {
        // The running hash absorbed part of this chunk; a retry would feed it
        // again. Drop it so the final check re-hashes the file instead.
        f.canUseRunningHash = false;
        _releaseRunningHash(f);
      }
      await raf?.close();
      if (s.status == TransferStatus.failed &&
          s.failureReason == FailureReason.cancelled &&
          !f.verified) {
        _deleteQuietly(f.partial);
        _deleteQuietly(ResumeStore.sidecarFor(f.partial));
      }
    }

    _requireInProgress(s);
    s.lastActivity = clock.now();
    final fresh = !store.has(index);
    final persisted = store.markReceived(index);
    if (fresh) {
      f.bytesDone += expected;
      _emit(FileProgress(s.id, fileId, f.bytesDone, f.item.size));
    }
    await persisted;
  }

  // -------------------------------------------------------------- complete

  @override
  Future<FileVerification> completeFile(
    String sessionId,
    String fileId, {
    required String token,
    String? sha256,
  }) async {
    final s = _session(sessionId);
    final f = _authorize(s, fileId, token);
    _requireInProgress(s);
    final verified = f.verification;
    if (f.verified && verified != null) return verified;
    final running = f.completion;
    if (running != null) return running;

    final count = f.item.chunkCount;
    final have = f.store?.receivedCount ?? 0;
    if (count > 0 && have < count) {
      throw LsException(
        LsErrorCode.missingChunks,
        '${count - have} of $count chunks missing',
      );
    }

    final manifestHash = f.item.sha256?.toLowerCase();
    String? bodyHash;
    if (sha256 != null) {
      if (!_hex64.hasMatch(sha256)) {
        throw LsException(LsErrorCode.badRequest, 'malformed sha256');
      }
      bodyHash = sha256.toLowerCase();
    }
    if (manifestHash != null && bodyHash != null && manifestHash != bodyHash) {
      throw LsException(
        LsErrorCode.badRequest,
        'sha256 differs from the manifest',
      );
    }
    final expectedHash = manifestHash ?? bodyHash;
    if (expectedHash == null) {
      throw LsException(
        LsErrorCode.badRequest,
        'no sha256 in the manifest and none supplied',
      );
    }

    final run = _finalize(s, f, expectedHash);
    f.completion = run;
    try {
      return await run;
    } catch (_) {
      if (!f.verified) f.completion = null;
      rethrow;
    }
  }

  Future<FileVerification> _finalize(
    _Session s,
    _FileEntry f,
    String expectedHash,
  ) async {
    final item = f.item;
    try {
      if (item.chunkCount == 0) {
        if (partialDir == null) assertInsideDir(downloadDir, f.partial.path);
        await f.partial.parent.create(recursive: true);
        if (!f.partial.existsSync()) await f.partial.create();
      } else {
        await _syncFile(f.partial);
      }
      final actual = await _actualHash(f);
      _requireInProgress(s); // cancelled while hashing?

      if (actual != expectedHash) {
        await _discard(f);
        _setStatus(s, TransferStatus.failed, FailureReason.verifyFailed);
        throw LsException(
          LsErrorCode.verifyFailed,
          'SHA-256 of ${item.fileId} does not match; partial file removed',
        );
      }

      await _moveIntoPlace(f);
      await f.store?.discard(deletePartial: false);
      final modified = item.modified;
      if (modified != null) {
        try {
          await f.target.setLastModified(modified);
        } on FileSystemException {
          // best effort: some file systems cannot store arbitrary mtimes
        } on ArgumentError {
          // out-of-range timestamp from a hostile manifest
        }
      }
      f.verified = true;
      final result = FileVerification(verified: true, sha256: actual);
      f.verification = result;
      _unreserve(f);
      s.lastActivity = clock.now();
      _emit(FileSaved(s.id, item.fileId, f.target.path));
      return result;
    } on FileSystemException catch (e) {
      if (s.status != TransferStatus.inProgress) _throwStateError(s);
      if (_isDiskFull(e)) {
        _setStatus(s, TransferStatus.failed, FailureReason.diskFull);
        throw LsException(
          LsErrorCode.insufficientStorage,
          'no space left on device',
        );
      }
      _log.warning('completing a file of session ${_short(s.id)} failed');
      throw LsException(LsErrorCode.internal, 'could not save file');
    }
  }

  /// SHA-256 of the partial file: the running digest when it saw every byte in
  /// order, else a re-hash in an isolate. The running digest is released on
  /// every path.
  Future<String> _actualHash(_FileEntry f) async {
    try {
      final item = f.item;
      final length = f.partial.existsSync() ? f.partial.lengthSync() : -1;
      if (length != item.size) return 'size-mismatch';
      if (f.canUseRunningHash &&
          f.nextExpectedChunkIndex == item.chunkCount &&
          f.runningHasher != null) {
        return _finishRunningHash(f);
      }
      final path = f.partial.path;
      return await Isolate.run(() => sha256OfPathStreamed(path));
    } finally {
      _releaseRunningHash(f);
    }
  }

  /// partial -> final name. Never overwrites: if the target appeared in the
  /// meantime a new `name (n).ext` is chosen.
  Future<void> _moveIntoPlace(_FileEntry f) async {
    assertInsideDir(downloadDir, f.target.path);
    await f.target.parent.create(recursive: true);
    assertInsideDir(downloadDir, f.target.path);

    if (FileSystemEntity.typeSync(f.target.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      _unreserve(f);
      final fresh = resolveTarget(
        downloadDir: downloadDir,
        fileName: f.item.fileName,
        relativePath: f.item.relativePath,
        isReserved: _isReserved,
      );
      f.target = fresh;
      _reserve(f);
      assertInsideDir(downloadDir, f.target.path);
      await f.target.parent.create(recursive: true);
    }
    try {
      await atomicReplace(f.partial, f.target);
    } on FileSystemException {
      if (partialDir == null) rethrow;
      // Different file system: copy next to the target, then rename.
      final tmp = File(
        '${f.target.path}.lspart-${_rng.nextInt(1 << 32).toRadixString(16)}',
      );
      try {
        await f.partial.copy(tmp.path);
        await atomicReplace(tmp, f.target);
      } catch (_) {
        _deleteQuietly(tmp);
        rethrow;
      }
      _deleteQuietly(f.partial);
    }
  }

  // ---------------------------------------------------------- finish/cancel

  @override
  Future<SessionStatus> finish(String sessionId) async {
    final s = _session(sessionId);
    if (s.status == TransferStatus.completed) return _snapshot(s);
    _requireInProgress(s);
    final open = s.files.values.where((f) => !f.verified).length;
    if (open > 0) {
      throw LsException(
        LsErrorCode.wrongState,
        '$open file(s) not yet verified',
      );
    }
    _setStatus(s, TransferStatus.completed, null);
    return _snapshot(s);
  }

  @override
  Future<void> cancel(String sessionId) async {
    final s = _session(sessionId);
    if (s.status.isTerminal) return;
    _setStatus(s, TransferStatus.failed, FailureReason.cancelled);
    for (final f in s.files.values) {
      if (!f.verified) await _discard(f);
    }
  }

  // ---------------------------------------------------------------- helpers

  _Session _session(String id) {
    final s = _sessions[id];
    if (s == null) {
      throw LsException(LsErrorCode.notFound, 'unknown session');
    }
    if (clock.now().difference(s.lastActivity) > sessionTtl) {
      _expire(s);
      throw LsException(LsErrorCode.notFound, 'unknown session');
    }
    s.lastActivity = clock.now();
    return s;
  }

  _FileEntry _authorize(_Session s, String fileId, String token) {
    final f = s.files[fileId];
    if (f == null) {
      throw LsException(LsErrorCode.notFound, 'unknown file');
    }
    if (!_tokenEquals(token, f.token)) {
      throw LsException(LsErrorCode.tokenInvalid, 'invalid file token');
    }
    return f;
  }

  void _requireInProgress(_Session s) {
    if (s.status != TransferStatus.inProgress) _throwStateError(s);
  }

  Never _throwStateError(_Session s) {
    switch (s.status) {
      case TransferStatus.pending:
        throw LsException(LsErrorCode.wrongState, 'awaiting consent');
      case TransferStatus.completed:
        throw LsException(LsErrorCode.wrongState, 'session already completed');
      case TransferStatus.failed:
        if (s.failureReason == FailureReason.cancelled) {
          throw LsException(LsErrorCode.cancelled, 'session cancelled');
        }
        throw LsException(
          LsErrorCode.wrongState,
          'session failed (${s.failureReason?.wire ?? 'unknown'})',
        );
      case TransferStatus.inProgress:
        throw LsException(LsErrorCode.internal, 'unexpected state');
    }
  }

  SessionStatus _snapshot(_Session s) => SessionStatus(
    sessionId: s.id,
    status: s.status,
    failureReason: s.failureReason,
    sas: s.status == TransferStatus.pending && s.sasNr != null
        ? SasChallenge(nonce: b64urlEncode(s.sasNr!))
        : null,
    acceptedFiles: s.status == TransferStatus.inProgress
        ? {
            for (final e in s.files.entries)
              e.key: AcceptedFile(
                token: e.value.token,
                receivedRanges: e.value.store?.ranges ?? const [],
              ),
          }
        : const {},
  );

  void _setStatus(_Session s, TransferStatus st, FailureReason? reason) {
    if (s.status == st && s.failureReason == reason) return;
    if (s.status.isTerminal) return;
    s.status = st;
    s.failureReason = reason;
    s.lastActivity = clock.now();
    s.permissionTimer?.cancel();
    s.permissionTimer = null;
    s.sasTimer?.cancel();
    s.sasTimer = null;
    _wake(s);
    if (st.isTerminal) {
      for (final f in s.files.values) {
        _releaseRunningHash(f);
      }
      _release(s);
      _notifyActive();
      if (st == TransferStatus.failed && reason != FailureReason.cancelled) {
        for (final f in s.files.values) {
          final store = f.store;
          if (store != null && !f.verified && !f.discarded) {
            unawaited(store.flush().catchError((Object _) {}));
          }
        }
      }
      _emit(
        SessionFinished(
          s.id,
          success: st == TransferStatus.completed,
          reason: reason?.wire,
        ),
      );
    }
  }

  void _wake(_Session s) {
    final ws = List<Completer<void>>.of(s.waiters);
    s.waiters.clear();
    for (final c in ws) {
      if (!c.isCompleted) c.complete();
    }
  }

  void _emit(LsEvent e) {
    try {
      _onEvent?.call(e);
    } catch (err) {
      _log.warning('event listener threw: ${err.runtimeType}');
    }
  }

  void _evictExpired() {
    final now = clock.now();
    for (final s in _sessions.values.toList()) {
      if (now.difference(s.lastActivity) > sessionTtl) _expire(s);
    }
  }

  void _expire(_Session s) {
    if (!s.status.isTerminal) {
      _setStatus(s, TransferStatus.failed, FailureReason.timeout);
    }
    _release(s);
    _sessions.remove(s.id);
  }

  // ------------------------------------------------------------ validation

  void _validate(SessionRequest r) {
    final cs = r.chunkSize;
    if (cs < _kMinChunkSize || cs > _kMaxChunkSize || (cs & (cs - 1)) != 0) {
      throw LsException(
        LsErrorCode.badRequest,
        'chunkSize must be a power of two between 64 KiB and 16 MiB',
      );
    }
    if (r.files.isEmpty) {
      throw LsException(LsErrorCode.badRequest, 'no files');
    }
    if (r.files.length > kMaxFilesPerSession) {
      throw LsException(
        LsErrorCode.tooLarge,
        'more than $kMaxFilesPerSession files',
      );
    }
    if (r.totalSize < 0) {
      throw LsException(LsErrorCode.badRequest, 'negative totalSize');
    }
    final chunker = Chunker(cs);
    final ids = <String>{};
    var sum = 0;
    for (final f in r.files) {
      if (f.fileId.isEmpty || f.fileId.length > _kMaxFileIdLength) {
        throw LsException(LsErrorCode.badRequest, 'invalid fileId');
      }
      if (!ids.add(f.fileId)) {
        throw LsException(LsErrorCode.badRequest, 'duplicate fileId');
      }
      if (f.size < 0) {
        throw LsException(LsErrorCode.badRequest, 'negative file size');
      }
      if (f.size > _kMaxFileSize) {
        throw LsException(LsErrorCode.tooLarge, 'file too large');
      }
      if (f.chunkCount != chunker.chunkCount(f.size)) {
        throw LsException(
          LsErrorCode.badRequest,
          'chunkCount of ${f.fileId} does not match its size',
        );
      }
      final h = f.sha256;
      if (h != null && !_hex64.hasMatch(h)) {
        throw LsException(LsErrorCode.badRequest, 'malformed sha256');
      }
      sum += f.size;
    }
    if (sum != r.totalSize) {
      throw LsException(
        LsErrorCode.badRequest,
        'file sizes sum to $sum but totalSize is ${r.totalSize}',
      );
    }
  }

  /// An unusable download folder (missing and not creatable, or not writable) is refused up
  /// front with 507, before anybody is asked (LSP-1 4.3.4 step 11, both profiles).
  void _checkDownloadDir() {
    try {
      downloadDir.createSync(recursive: true);
      final probe = File(
        p.join(
          downloadDir.path,
          '.lsprobe-${_rng.nextInt(1 << 32).toRadixString(16)}',
        ),
      );
      probe.createSync(exclusive: true);
      probe.deleteSync();
    } on FileSystemException {
      throw LsException(
        LsErrorCode.insufficientStorage,
        'download folder is not usable',
      );
    }
  }

  Future<void> _checkFreeSpace(int totalSize) async {
    final needed = totalSize + minFreeBytesMargin;
    final dirs = <Directory>[?partialDir, downloadDir];
    for (final d in dirs) {
      final free = await _freeSpaceProbe(d);
      if (free != null && free < needed) {
        throw LsException(
          LsErrorCode.insufficientStorage,
          'not enough free space (need $needed bytes)',
        );
      }
    }
  }

  // ------------------------------------------------------------- planning

  /// Chooses targets and tokens (no file system writes except the root dir).
  void _plan(_Session s) {
    final hints = <String, int>{};
    for (final item in s.request.files) {
      final target = resolveTarget(
        downloadDir: downloadDir,
        fileName: item.fileName,
        relativePath: item.relativePath,
        isReserved: _isReserved,
        collisionHints: hints,
      );
      final f = _FileEntry(
        item: item,
        token: _newToken(),
        target: target,
        partial: _partialFor(target),
      );
      _reserve(f);
      s.files[item.fileId] = f;
    }
  }

  File _partialFor(File target) {
    final dir = partialDir;
    if (dir == null) return File('${target.path}$kPartialSuffix');
    final rel = p.relative(
      target.path,
      from: p.normalize(downloadDir.absolute.path),
    );
    final h = sha256.convert(utf8.encode(rel)).toString().substring(0, 24);
    return File(p.join(dir.path, '$h$kPartialSuffix'));
  }

  bool _isReserved(String candPath) {
    if (_reserved.contains(candPath.toLowerCase())) return true;
    if (partialDir == null) {
      // A `<name>.lspart` we did not create (no sidecar) belongs to somebody
      // else: never touch it, pick another name.
      final part = '$candPath$kPartialSuffix';
      if (FileSystemEntity.typeSync(part, followLinks: false) !=
              FileSystemEntityType.notFound &&
          FileSystemEntity.typeSync('$part.json', followLinks: false) ==
              FileSystemEntityType.notFound) {
        return true;
      }
    }
    return false;
  }

  void _reserve(_FileEntry f) {
    _unreserve(f);
    for (final path in [
      f.target.path,
      f.partial.path,
      ResumeStore.sidecarFor(f.partial).path,
    ]) {
      final key = path.toLowerCase();
      f.reservedKeys.add(key);
      _reserved.add(key);
    }
  }

  void _unreserve(_FileEntry f) {
    _reserved.removeAll(f.reservedKeys);
    f.reservedKeys.clear();
  }

  void _release(_Session s) {
    for (final f in s.files.values) {
      _unreserve(f);
    }
  }

  // -------------------------------------------------------------- activate

  Future<void> _start(_Session s) async {
    try {
      partialDir?.createSync(recursive: true);
      for (final f in s.files.values) {
        if (ResumeStore.sidecarFor(f.partial).existsSync()) {
          await _ensureStore(s, f);
        }
      }
    } on FileSystemException catch (e) {
      _log.warning('cannot start session ${_short(s.id)}: ${e.message}');
      _setStatus(s, TransferStatus.failed, FailureReason.protocolError);
      throw LsException(LsErrorCode.internal, 'cannot prepare download');
    }
    if (s.status != TransferStatus.pending) _throwStateError(s);
    _setStatus(s, TransferStatus.inProgress, null);
  }

  Future<ResumeStore> _ensureStore(_Session s, _FileEntry f) {
    final existing = f.store;
    if (existing != null) return Future.value(existing);
    return f.storeFuture ??= _openStore(s, f).catchError((Object e) {
      f.storeFuture = null;
      throw e;
    });
  }

  Future<ResumeStore> _openStore(_Session s, _FileEntry f) async {
    if (partialDir == null) assertInsideDir(downloadDir, f.partial.path);
    if (FileSystemEntity.typeSync(f.partial.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw LsException(LsErrorCode.badRequest, 'unsafe partial file');
    }
    final store = await ResumeStore.open(
      partialFile: f.partial,
      size: f.item.size,
      chunkSize: s.chunkSize,
      chunkCount: f.item.chunkCount,
      sha256: f.item.sha256?.toLowerCase(),
      modified: f.item.modified,
      clock: clock,
      beforePersist: () => _syncFile(f.partial),
    );
    final chunker = Chunker(s.chunkSize);
    var done = 0;
    for (final r in store.ranges) {
      for (var i = r[0]; i <= r[1]; i++) {
        done += chunker.range(f.item.size, i).length;
      }
    }
    f.bytesDone = done;
    f.store = store;
    return store;
  }

  /// fsync the partial file (no-op if it does not exist).
  Future<void> _syncFile(File partial) async {
    if (!partial.existsSync()) return;
    final raf = await partial.open(mode: FileMode.append);
    try {
      await raf.flush();
    } finally {
      await raf.close();
    }
  }

  Future<void> _discard(_FileEntry f) async {
    f.discarded = true;
    _releaseRunningHash(f);
    f.canUseRunningHash = false;
    final store = f.store;
    if (store != null) {
      await store.discard();
    } else {
      _deleteQuietly(f.partial);
      _deleteQuietly(ResumeStore.sidecarFor(f.partial));
    }
  }

  // ----------------------------------------------------------- randomness

  String _newToken() {
    final b = Uint8List(16);
    for (var i = 0; i < b.length; i++) {
      b[i] = _rng.nextInt(256);
    }
    return base64Url.encode(b).replaceAll('=', '');
  }

  String _newSessionId() {
    final b = Uint8List(16);
    for (var i = 0; i < b.length; i++) {
      b[i] = _rng.nextInt(256);
    }
    b[6] = (b[6] & 0x0f) | 0x40; // version 4
    b[8] = (b[8] & 0x3f) | 0x80; // RFC 4122 variant
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-${h.substring(20)}';
  }
}

/// First 8 characters of a session id: all a log line may carry.
String _short(String sid) => sid.length <= 8 ? sid : sid.substring(0, 8);

/// 43 base64url characters that decode to 32 bytes (a SHA-256 commitment).
bool _isCommit(String s) {
  if (s.length != 43) return false;
  try {
    return b64urlDecode(s).length == 32;
  } on FormatException {
    return false;
  }
}

/// 22 base64url characters that decode to exactly [kSasNonceBytes] bytes, else null.
Uint8List? _decodeNonce(String s) {
  if (s.length != 22) return null;
  try {
    final d = b64urlDecode(s);
    return d.length == kSasNonceBytes ? d : null;
  } on FormatException {
    return null;
  }
}

/// Constant-time (for equal lengths; length itself is not secret) comparison.
bool _tokenEquals(String a, String b) {
  final x = utf8.encode(a);
  final y = utf8.encode(b);
  var diff = x.length ^ y.length;
  final n = x.length > y.length ? x.length : y.length;
  for (var i = 0; i < n; i++) {
    diff |= (i < x.length ? x[i] : 0) ^ (i < y.length ? y[i] : 0);
  }
  return diff == 0;
}

bool _isDiskFull(FileSystemException e) {
  final code = e.osError?.errorCode;
  return code == 28 /* ENOSPC */ || code == 112 /* ERROR_DISK_FULL */;
}

void _deleteQuietly(File f) {
  try {
    if (FileSystemEntity.typeSync(f.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      f.deleteSync();
    }
  } on FileSystemException {
    // best effort
  }
}

final RegExp _dfLine = RegExp(
  r'^(.+?)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)%\s+(.*)$',
);

/// Free bytes via POSIX `df -Pk`; null where unavailable (e.g. Windows).
Future<int?> _dfFreeBytes(Directory dir) async {
  if (Platform.isWindows) return null;
  try {
    dir.createSync(recursive: true);
    final r = await Process.run('df', ['-Pk', dir.path]);
    if (r.exitCode != 0) return null;
    final lines = (r.stdout as String).trim().split('\n');
    if (lines.length < 2) return null;
    final m = _dfLine.firstMatch(lines.last.trim());
    if (m == null) return null;
    final availKb = int.tryParse(m.group(4)!);
    return availKb == null ? null : availKb * 1024;
  } on Object {
    return null;
  }
}
