/// FileSender (UML 6.0, spec §2.2, §4.3, §4.4): drives one outgoing session
/// through a [PeerClient] — manifest, permission wait, resumable chunk upload,
/// per-file verification, finish.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../client/peer_client.dart';
import '../client/peer_security_exceptions.dart';
import '../model/device.dart';
import '../model/events.dart';
import '../model/ls_exception.dart';
import '../model/session_models.dart';
import '../model/transfer_status.dart';
import '../security/contracts.dart';
import '../security/crypto_primitives.dart'
    show b64urlDecode, b64urlEncode, secureRandomBytes;
import '../security/sas.dart';
import 'chunker.dart';
import 'hashing.dart';
import 'manifest.dart';

/// Outcome of [FileSender.send]. Protocol/transport failures are reported here
/// (never thrown); only programming/local-file errors throw.
class SendResult {
  const SendResult({
    required this.sessionId,
    required this.status,
    required this.bytesSent,
    required this.elapsed,
    this.failureReason,
    this.receiverFingerprint,
    this.refusal,
  });

  /// Wire error code of the receiver's refusal when the send failed on an [LsException]
  /// (PIN_REQUIRED, BLOCKED, KEY_CHANGED, ...); null on success, on cancel and on failures
  /// without a wire code (no connection, timeout).
  final LsErrorCode? refusal;

  /// Fingerprint (uppercase hex) of the receiver certificate seen in the TLS handshake. Set only
  /// when the receiver accepted the session in the secure profile, so a rejected or aborted
  /// receiver is never pinned; null in the plaintext profile.
  final String? receiverFingerprint;

  /// Empty when the session could not be created.
  final String sessionId;

  /// [TransferStatus.completed] or [TransferStatus.failed].
  final TransferStatus status;
  final FailureReason? failureReason;

  /// Payload bytes uploaded (and acked) by this run. Chunks the receiver
  /// already held (resume) are not counted.
  final int bytesSent;

  /// Wall time of the whole [FileSender.send] call (manifest hashing included).
  final Duration elapsed;

  bool get isSuccess => status == TransferStatus.completed;

  @override
  String toString() =>
      'SendResult($sessionId, ${status.wire}'
      '${failureReason == null ? '' : '/${failureReason!.wire}'}, '
      '$bytesSent B, ${elapsed.inMilliseconds} ms)';
}

class FileSender {
  FileSender({
    required this.client,
    required this.self,
    this.chunker = const Chunker(),
    this.chunkConcurrency = 3,
    this.fileConcurrency = 1,
    this.retryDelays = const [
      Duration(milliseconds: 500),
      Duration(seconds: 1),
      Duration(seconds: 2),
    ],
    this.acceptTimeout = const Duration(seconds: 120),
    this.pin,
    this.onEvent,
    this.hashLimitBytes = kManifestHashLimit,
    this.security = const SecurityConfig.plaintext(),
    this.pinnedReceiverFingerprint,
  }) {
    final pinned = pinnedReceiverFingerprint;
    if (pinned != null && !RegExp(r'^[0-9A-Fa-f]{64}$').hasMatch(pinned)) {
      // A malformed pin must never mean "first contact".
      throw ArgumentError.value(
        'not a fingerprint',
        'pinnedReceiverFingerprint',
      );
    }
    if (chunkConcurrency < 1) {
      throw ArgumentError.value(
        chunkConcurrency,
        'chunkConcurrency',
        'must be >= 1',
      );
    }
    if (fileConcurrency < 1) {
      throw ArgumentError.value(
        fileConcurrency,
        'fileConcurrency',
        'must be >= 1',
      );
    }
  }

  final PeerClient client;
  final DeviceInfo self;
  final Chunker chunker;

  /// Chunks in flight per file.
  final int chunkConcurrency;

  /// Files transferred in parallel (total in flight <= file x chunk).
  final int fileConcurrency;

  /// Delay before retry 1, 2, 3...; its length is the retry budget per request.
  final List<Duration> retryDelays;

  /// How long to wait for the receiver's user to accept (spec: 120 s).
  final Duration acceptTimeout;
  final String? pin;
  final void Function(LsEvent)? onEvent;

  /// Files above this size are announced with `sha256: null` and hashed in the
  /// background while uploading (spec §4.3).
  final int hashLimitBytes;

  /// Secure profile (LSP/1.1): the receiver is learnt through `info()`, pinned or authenticated
  /// by SAS. The plaintext profile (default) behaves exactly like Increment 1/2.
  final SecurityConfig security;

  /// Fingerprint pinned for the receiver; null in the secure profile = first contact (SAS).
  final String? pinnedReceiverFingerprint;

  static final Logger _log = Logger('libreshare.FileSender');

  /// Log form of an id: at most 8 characters.
  static String _shortId(String id) =>
      id.isEmpty ? '(none)' : (id.length <= 8 ? id : id.substring(0, 8));

  final Set<_SendRun> _runs = {};

  /// Sends [files] (order is irrelevant: the manifest is sorted smallest
  /// first). Resolves with a [SendResult]; throws [ArgumentError] for an empty
  /// list and [FileSystemException] if a path is missing or not a regular file
  /// (before any session exists).
  Future<SendResult> send(List<File> files) async {
    if (files.isEmpty) {
      throw ArgumentError.value(files, 'files', 'must not be empty');
    }
    final sw = Stopwatch()..start();
    // Registered before the first await so that cancel() is honoured from the
    // very first moment (manifest hashing included), not only once a session
    // exists.
    final run = _SendRun();
    _runs.add(run);
    try {
      final builder = ManifestBuilder(
        chunker: chunker,
        maxHashedSize: hashLimitBytes,
      );
      final entries = await builder.buildEntries(files);
      final request = builder.buildSessionRequest(
        sender: self,
        files: [for (final e in entries) e.item],
        pin: pin,
      );
      try {
        await _execute(run, entries, request);
        _log.info(
          'session ${_shortId(run.sessionId)} completed (${run.bytesSent} B sent)',
        );
        _emit(SessionFinished(run.sessionId, success: true));
        return SendResult(
          sessionId: run.sessionId,
          status: TransferStatus.completed,
          bytesSent: run.bytesSent,
          elapsed: sw.elapsed,
          receiverFingerprint: run.acceptedReceiverFp,
        );
      } on Object catch (e, st) {
        // A caller-requested cancel wins over whatever error it provoked
        // (e.g. a transport error on a request that was in flight); while a SAS comparison is
        // outstanding it is an abort of that comparison.
        final f = run.cancelRequested
            ? (run.sasOutstanding
                  ? _classify(const SasAbortedException())
                  : _SendFailure._cancelled())
            : _classify(e);
        _log.warning(
          'session ${_shortId(run.sessionId)} failed: '
          '${f.reason.wire} (${f.message})',
          f.isInternal ? e.runtimeType : null,
          f.isInternal ? st : null,
        );
        // Also covers a cancel() that arrived before the session id was known:
        // the id is known now, so the peer is told now.
        if (f.notifyPeer) await _cancelPeer(run);
        _emit(
          SessionFinished(run.sessionId, success: false, reason: f.reason.wire),
        );
        final security = f.securityError;
        if (security != null) throw security;
        return SendResult(
          sessionId: run.sessionId,
          status: TransferStatus.failed,
          failureReason: f.reason,
          bytesSent: run.bytesSent,
          elapsed: sw.elapsed,
          receiverFingerprint: run.acceptedReceiverFp,
          refusal: f.refusal,
        );
      }
    } finally {
      _runs.remove(run);
    }
  }

  /// Aborts every running [send] and makes the pending call resolve with
  /// FAILED(CANCELLED). Safe at any moment and idempotent:
  ///
  /// * the session already exists: the peer is told (`/cancel`, once) and this
  ///   completes when it answered;
  /// * the session id is not known yet (manifest being built, `createSession`
  ///   in flight): nothing can be told yet; the send tells the peer itself the
  ///   moment the `createSession` reply gives the id, and uploads nothing;
  /// * nothing is running: no effect.
  Future<void> cancel() async {
    for (final run in _runs.toList()) {
      run.cancelRequested = true;
      await _cancelPeer(run);
    }
  }

  // ---------------------------------------------------------------- session

  Future<void> _execute(
    _SendRun run,
    List<ManifestEntry> entries,
    SessionRequest request,
  ) async {
    run.throwIfAborted(); // cancelled while the manifest was being built
    final sas = security.isSecure ? await _prepareSecure(run) : null;
    if (sas != null) {
      request = _withCommit(request, sas);
      run.sasOutstanding = sas.ns != null;
    }
    // Not retried: a blind retry could make the receiver prompt twice.
    var st = await client.createSession(request);
    run.sessionId = st.sessionId;
    _emit(SessionCreated(run.sessionId, outgoing: true));
    run.throwIfAborted();

    if (sas != null && sas.ns != null) await _runSas(run, st, sas);

    st = await _awaitAcceptance(run, st);
    run.sasOutstanding = false;
    if (sas != null) run.acceptedReceiverFp = sas.receiverFp;

    final accepted = st.acceptedFiles;
    final todo = [
      for (final e in entries)
        if (accepted.containsKey(e.item.fileId)) e,
    ];
    if (todo.isEmpty) {
      throw _SendFailure(
        FailureReason.rejected,
        'receiver accepted none of the files',
        notifyPeer: true,
      );
    }

    await _forEachConcurrent<ManifestEntry>(
      run,
      todo,
      fileConcurrency,
      (e) => _sendFile(run, e, accepted[e.item.fileId]!),
    );

    final fin = await _retry(run, () => client.finish(run.sessionId));
    switch (fin.status) {
      case TransferStatus.completed:
        return;
      case TransferStatus.failed:
        throw _SendFailure(
          fin.failureReason ?? FailureReason.protocolError,
          'receiver failed the session at finish',
        );
      case TransferStatus.pending:
      case TransferStatus.inProgress:
        throw _SendFailure(
          FailureReason.protocolError,
          'finish answered ${fin.status.wire}',
          notifyPeer: true,
        );
    }
  }

  // ------------------------------------------------------------ secure profile

  /// Learns and checks the receiver (LSP-1 4.7, 5.1) before any session exists. Returns null for
  /// a legacy receiver the user explicitly allowed (plaintext behaviour from then on).
  Future<_SecureSend?> _prepareSecure(_SendRun run) async {
    final peer = await client.info();
    run.throwIfAborted();
    if (peer.fingerprint.isEmpty) {
      if (security.allowInsecurePeers) return null;
      throw const InsecurePeerException();
    }
    final c = client;
    final seen = c is SecurePeerClient ? c.serverFingerprint : null;
    if (seen == null) throw const InsecurePeerException();
    final receiverFp = seen.toUpperCase();
    final pinned = pinnedReceiverFingerprint?.toUpperCase();
    if (pinned != null && pinned != receiverFp) {
      throw PeerFingerprintMismatchException(
        shortFp(pinned),
        shortFp(receiverFp),
      );
    }
    final senderFp = security.identity!.identity.fingerprint;
    // No pin = the receiver is not authenticated yet: commit to a fresh Ns (LSP-1 5.1).
    final ns = pinned == null ? secureRandomBytes(kSasNonceBytes) : null;
    return _SecureSend(
      receiverFp: receiverFp,
      senderFp: senderFp,
      ns: ns,
      commit: ns == null
          ? null
          : sasCommit(
              ns: ns,
              senderFingerprint: senderFp,
              receiverFingerprintSeenBySender: receiverFp,
            ),
    );
  }

  static SessionRequest _withCommit(SessionRequest r, _SecureSend sas) =>
      sas.commit == null
      ? r
      : SessionRequest(
          sender: r.sender,
          files: r.files,
          totalSize: r.totalSize,
          pin: r.pin,
          chunkSize: r.chunkSize,
          tunnelOffer: r.tunnelOffer,
          sasCommit: sas.commit,
        );

  /// Reveals Ns right after the 202 and shows the code (LSP-1 5.1). Any failure ends the
  /// session before a chunk is sent.
  Future<void> _runSas(_SendRun run, SessionStatus st, _SecureSend sas) async {
    final challenge = st.sas;
    final Uint8List nr;
    if (st.status != TransferStatus.pending || challenge == null) {
      // A receiver that ignored the commitment has not been authenticated.
      throw _SendFailure(
        FailureReason.protocolError,
        'receiver did not answer the SAS commitment',
        notifyPeer: true,
      );
    }
    try {
      nr = b64urlDecode(challenge.nonce);
    } on FormatException {
      throw _SendFailure(
        FailureReason.protocolError,
        'malformed SAS nonce',
        notifyPeer: true,
      );
    }
    if (nr.length != kSasNonceBytes) {
      throw _SendFailure(
        FailureReason.protocolError,
        'malformed SAS nonce',
        notifyPeer: true,
      );
    }
    final c = client;
    if (c is! SecurePeerClient) throw const InsecurePeerException();
    final SessionStatus revealed;
    try {
      // Valid once only: never retried.
      revealed = await c.revealSas(run.sessionId, nonce: b64urlEncode(sas.ns!));
    } on Object {
      throw const SasAbortedException();
    }
    run.throwIfAborted();
    final again = revealed.sas?.nonce;
    if (revealed.status != TransferStatus.pending ||
        again == null ||
        again != challenge.nonce) {
      // The receiver must not change Nr after it learnt Ns.
      throw const SasAbortedException();
    }
    final code = sasCode(
      ns: sas.ns!,
      nr: nr,
      fingerprintA: sas.senderFp,
      fingerprintB: sas.receiverFp,
    );
    _emit(SasReady(run.sessionId, code, outgoing: true));
  }

  /// Long-polls until the session leaves PENDING (spec §2.2). Throws
  /// [_SendFailure] for rejection, receiver-side failure or [acceptTimeout].
  Future<SessionStatus> _awaitAcceptance(
    _SendRun run,
    SessionStatus first,
  ) async {
    var st = first;
    final waited = Stopwatch()..start();
    var transient = 0;
    while (st.status == TransferStatus.pending) {
      run.throwIfAborted();
      final remaining = acceptTimeout - waited.elapsed;
      if (remaining <= Duration.zero) {
        throw _SendFailure(
          FailureReason.timeout,
          'no answer within ${acceptTimeout.inSeconds} s',
          notifyPeer: true,
        );
      }
      final waitSeconds = math.min(
        25,
        math.max(1, (remaining.inMilliseconds / 1000).ceil()),
      );
      // Safety net against a connection that hangs instead of long-polling.
      final guard = remaining + const Duration(milliseconds: 500);
      final hardCap = Duration(seconds: waitSeconds + 10);
      final poll = Stopwatch()..start();
      try {
        st = await client
            .waitSession(run.sessionId, waitSeconds: waitSeconds)
            .timeout(guard < hardCap ? guard : hardCap);
        transient = 0;
      } on Object catch (e) {
        if (e is TimeoutException && waited.elapsed >= acceptTimeout) {
          throw _SendFailure(
            FailureReason.timeout,
            'no answer within ${acceptTimeout.inSeconds} s',
            notifyPeer: true,
          );
        }
        if (_isTransient(e) && transient < retryDelays.length) {
          await Future<void>.delayed(retryDelays[transient++]);
          continue;
        }
        rethrow;
      }
      // A server that answers PENDING immediately must not make us spin.
      const minPoll = Duration(milliseconds: 100);
      if (st.status == TransferStatus.pending && poll.elapsed < minPoll) {
        await Future<void>.delayed(minPoll - poll.elapsed);
      }
    }
    switch (st.status) {
      case TransferStatus.inProgress:
        return st;
      case TransferStatus.failed:
        throw _SendFailure(
          st.failureReason ?? FailureReason.protocolError,
          'receiver ended the session',
        );
      case TransferStatus.completed:
      case TransferStatus.pending:
        throw _SendFailure(
          FailureReason.protocolError,
          'unexpected status ${st.status.wire} before transfer',
          notifyPeer: true,
        );
    }
  }

  // ------------------------------------------------------------------ files

  Future<void> _sendFile(
    _SendRun run,
    ManifestEntry entry,
    AcceptedFile accepted,
  ) async {
    final item = entry.item;
    final sid = run.sessionId;
    final token = accepted.token;

    // Whole-file digest for files the manifest could not carry one for; runs in
    // an isolate, pipelined with the upload.
    Future<String>? fullHash;
    if (item.sha256 == null) {
      fullHash = sha256OfFile(entry.file)..ignore();
    }
    String? suppliedSha;

    for (var round = 0; ; round++) {
      final state = await _retry(
        run,
        () => client.fileState(sid, item.fileId, token: token),
      );
      if (state.chunkCount != item.chunkCount) {
        throw _SendFailure(
          FailureReason.protocolError,
          'peer expects ${state.chunkCount} chunks for ${item.fileId}, '
          'manifest has ${item.chunkCount}',
          notifyPeer: true,
        );
      }
      final have = _receivedSet(state.receivedRanges, item.chunkCount);
      final missing = [
        for (var i = 0; i < item.chunkCount; i++)
          if (!have.contains(i)) i,
      ];
      final progress = _FileProgress(
        total: item.size,
        done: have.fold<int>(
          0,
          (sum, i) => sum + chunker.range(item.size, i).length,
        ),
      );
      if (progress.done > 0) {
        _emit(FileProgress(sid, item.fileId, progress.done, progress.total));
      }
      if (have.isNotEmpty) {
        _log.fine(
          '${_shortId(sid)}/${_shortId(item.fileId)}: resuming, '
          '${missing.length} chunks left',
        );
      }

      await _forEachConcurrent<int>(
        run,
        missing,
        chunkConcurrency,
        (i) => _uploadChunk(run, entry, token, i, progress),
      );

      if (fullHash != null) suppliedSha ??= await fullHash;
      try {
        final v = await _retry(
          run,
          () => client.completeFile(
            sid,
            item.fileId,
            token: token,
            sha256: suppliedSha,
          ),
          retryIf: (e) => _isTransient(e) && !_isMissingChunks(e),
        );
        if (!v.verified) {
          throw _SendFailure(
            FailureReason.verifyFailed,
            'peer could not verify ${item.fileId}',
            notifyPeer: true,
          );
        }
        break;
      } on LsException catch (e) {
        // The peer lost some chunks (e.g. restarted): re-read /state, re-send.
        if (_isMissingChunks(e) && round < retryDelays.length) {
          await Future<void>.delayed(retryDelays[round]);
          continue;
        }
        rethrow;
      }
    }

    _emit(FileProgress(sid, item.fileId, item.size, item.size));
  }

  Future<void> _uploadChunk(
    _SendRun run,
    ManifestEntry entry,
    String token,
    int index,
    _FileProgress progress,
  ) async {
    final item = entry.item;
    final r = chunker.range(item.size, index);

    // Read chunk into single in-memory buffer: eliminates double disk read and isolate overhead
    final raf = await entry.file.open(mode: FileMode.read);
    final Uint8List chunkBytes;
    try {
      await raf.setPosition(r.start);
      final buf = Uint8List(r.length);
      final read = await raf.readInto(buf);
      if (read != r.length) {
        throw FileSystemException(
          'File shorter than expected: chunk $index has $read of ${r.length} bytes',
          entry.file.path,
        );
      }
      chunkBytes = buf;
    } finally {
      await raf.close();
    }

    final hash = sha256OfBytes(chunkBytes);
    run.throwIfAborted();

    // Stream single-pass chunk buffer for the upload
    await _retry(
      run,
      () => client.putChunk(
        run.sessionId,
        item.fileId,
        index,
        Stream.value(chunkBytes),
        length: r.length,
        chunkSha256: hash,
        token: token,
      ),
    );
    run.bytesSent += r.length;
    progress.done += r.length;
    _emit(
      FileProgress(run.sessionId, item.fileId, progress.done, progress.total),
    );
  }

  // ---------------------------------------------------------------- helpers

  /// Runs [task] over [items] with at most [concurrency] in flight. The first
  /// failure aborts the run (no new items start), all started tasks settle,
  /// then it is rethrown.
  Future<void> _forEachConcurrent<T>(
    _SendRun run,
    List<T> items,
    int concurrency,
    Future<void> Function(T item) task,
  ) async {
    var next = 0;
    Future<void> worker() async {
      while (!run.aborted && next < items.length) {
        final item = items[next++];
        try {
          await task(item);
        } on Object catch (e) {
          run.fail(_classify(e));
        }
      }
    }

    await Future.wait([
      for (var i = 0; i < math.min(concurrency, items.length); i++) worker(),
    ]);
    run.throwIfAborted();
  }

  /// Retries [op] on transient errors with [retryDelays] (spec §4.4: 3 retries
  /// at 0.5/1/2 s).
  Future<T> _retry<T>(
    _SendRun run,
    Future<T> Function() op, {
    bool Function(Object error)? retryIf,
  }) async {
    final shouldRetry = retryIf ?? _isTransient;
    for (var attempt = 0; ; attempt++) {
      run.throwIfAborted();
      try {
        return await op();
      } on Object catch (e) {
        if (attempt >= retryDelays.length || run.aborted || !shouldRetry(e)) {
          rethrow;
        }
        _log.fine(
          'transient ${e.runtimeType}, retry ${attempt + 1}/${retryDelays.length}',
        );
        await Future<void>.delayed(retryDelays[attempt]);
      }
    }
  }

  static bool _isTransient(Object e) =>
      e is SocketException ||
      e is TimeoutException ||
      e is HttpException ||
      (e is LsException && e.retryable);

  static bool _isMissingChunks(Object e) =>
      e is LsException && e.code == LsErrorCode.missingChunks;

  /// Chunk indices the peer reports as held, clamped to the real chunk count so
  /// a hostile or buggy `[0, 2^62]` cannot blow up memory.
  static Set<int> _receivedSet(ChunkRanges ranges, int chunkCount) {
    final clamped = <List<int>>[];
    for (final r in ranges) {
      if (r.length != 2) continue;
      final lo = math.max(r[0], 0);
      final hi = math.min(r[1], chunkCount - 1);
      if (lo <= hi) clamped.add([lo, hi]);
    }
    return expandRanges(clamped);
  }

  static _SendFailure _classify(Object e) {
    if (e is _SendFailure) return e;
    if (e is SasAbortedException) {
      return _SendFailure(
        FailureReason.protocolError,
        'SAS aborted',
        notifyPeer: true,
        securityError: e,
      );
    }
    if (e is InsecurePeerException || e is PeerFingerprintMismatchException) {
      // Local security refusals: leave send() as themselves; the peer is not authenticated, so
      // nothing more is sent to it.
      return _SendFailure(
        FailureReason.protocolError,
        e.runtimeType.toString(),
        securityError: e,
      );
    }
    if (e is LsException) {
      final f = _classifyWire(e);
      if (e.code != LsErrorCode.cancelled) f.refusal = e.code;
      return f;
    }
    return _classifyOther(e);
  }

  static _SendFailure _classifyWire(LsException e) {
    final detail = e.code.wire;
    return switch (e.code) {
      LsErrorCode.verifyFailed => _SendFailure(
        FailureReason.verifyFailed,
        detail,
        notifyPeer: true,
      ),
      LsErrorCode.cancelled => _SendFailure(FailureReason.cancelled, detail),
      LsErrorCode.insufficientStorage => _SendFailure(
        FailureReason.diskFull,
        detail,
        notifyPeer: true,
      ),
      LsErrorCode.pinRequired ||
      LsErrorCode.pinInvalid ||
      LsErrorCode.blocked ||
      LsErrorCode.busy ||
      LsErrorCode.tooLarge ||
      LsErrorCode.rateLimited => _SendFailure(
        FailureReason.rejected,
        detail,
        notifyPeer: true,
      ),
      _ => _SendFailure(FailureReason.protocolError, detail, notifyPeer: true),
    };
  }

  static _SendFailure _classifyOther(Object e) {
    if (e is SocketException || e is TimeoutException || e is HttpException) {
      return _SendFailure(
        FailureReason.noConnection,
        e.runtimeType.toString(),
        notifyPeer: true,
      );
    }
    return _SendFailure(
      FailureReason.protocolError,
      e.runtimeType.toString(),
      notifyPeer: true,
      isInternal: true,
    );
  }

  /// Tells the peer to drop the session, once per run: later callers (a second
  /// cancel(), the send's own failure path) share the first request's future, so
  /// the send never resolves while `/cancel` is still in flight. A no-op while
  /// the session id is unknown; the caller repeats it once the id is known.
  Future<void> _cancelPeer(_SendRun run) {
    final sid = run.sessionId;
    if (sid.isEmpty) return Future<void>.value();
    return run.peerCancel ??= _sendCancel(sid);
  }

  Future<void> _sendCancel(String sessionId) async {
    try {
      await client.cancel(sessionId).timeout(const Duration(seconds: 5));
    } on Object catch (e) {
      _log.fine('cancel request failed: ${e.runtimeType}');
    }
  }

  void _emit(LsEvent event) {
    final cb = onEvent;
    if (cb == null) return;
    try {
      cb(event);
    } on Object catch (e, st) {
      _log.warning('onEvent listener threw', e, st);
    }
  }
}

/// Mutable state of one [FileSender.send] call.
class _SendRun {
  String sessionId = '';
  int bytesSent = 0;
  bool cancelRequested = false;

  /// A SAS comparison has been started and the receiver has not accepted yet.
  bool sasOutstanding = false;

  /// Receiver fingerprint, set once the receiver accepted in the secure profile.
  String? acceptedReceiverFp;

  /// The one `/cancel` request of this run (null until it was sent).
  Future<void>? peerCancel;
  _SendFailure? failure;

  bool get aborted => failure != null || cancelRequested;

  void fail(_SendFailure f) {
    failure ??= cancelRequested ? _SendFailure._cancelled() : f;
  }

  void throwIfAborted() {
    final f = failure;
    if (f != null) throw f;
    if (cancelRequested) throw _SendFailure._cancelled();
  }
}

class _FileProgress {
  _FileProgress({required this.total, required this.done});
  final int total;
  int done;
}

/// Internal control-flow exception carrying the final [FailureReason].
class _SendFailure implements Exception {
  _SendFailure(
    this.reason,
    this.message, {
    this.notifyPeer = false,
    this.isInternal = false,
    this.securityError,
  });

  /// The caller cancelled: the peer has to be told (unlike a cancel that came
  /// from the peer, see [_classify]).
  factory _SendFailure._cancelled() => _SendFailure(
    FailureReason.cancelled,
    'cancelled by caller',
    notifyPeer: true,
  );

  final FailureReason reason;
  final String message;

  /// Whether we should send `/cancel` (false when the peer already ended it).
  final bool notifyPeer;

  /// Wire code of the receiver's refusal, when the failure came from an [LsException].
  LsErrorCode? refusal;

  /// Unexpected (non-protocol) exception: log its stack trace.
  final bool isInternal;

  /// A local security refusal that leaves [FileSender.send] as itself.
  final Object? securityError;

  @override
  String toString() => '_SendFailure(${reason.wire}: $message)';
}

/// What the secure profile decided about one receiver.
class _SecureSend {
  _SecureSend({
    required this.receiverFp,
    required this.senderFp,
    required this.ns,
    required this.commit,
  });
  final String receiverFp;
  final String senderFp;

  /// Our SAS nonce; null when the receiver is pinned (no SAS).
  final Uint8List? ns;
  final String? commit;
}
