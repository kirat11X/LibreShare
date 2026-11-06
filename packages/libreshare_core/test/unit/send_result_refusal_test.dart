// P6a - SendResult.refusal: the wire error code behind a failed send, so the CLI and UI can tell
// KEY_CHANGED (exit 80) from PIN/BLOCKED (exit 82) although both map to FailureReason values.
//
// Spec: orchestrator decision of 2026-11-05 on P6a finding 1; LSP-1 4.3.1 / 5.2 error codes;
// docs/plans/inc3.md (CLI exit codes). Contract:
//   final LsErrorCode? refusal;   // on SendResult, default null
//   = the code of the LsException that made the send fail (createSession or any later call:
//     reveal, wait, chunk, complete, finish), after retries are exhausted.
//   null on success, on a cancel and on non-Ls failures (no connection, timeout).
//   FailureReason mapping is UNCHANGED (PIN/BLOCKED/BUSY/... => rejected, KEY_CHANGED/AUTH_INVALID =>
//   protocolError, INSUFFICIENT_STORAGE => diskFull).
//
// SPEC-GAP: a CANCELLED answer that the receiver sent on its own (not caused by this sender's
// cancel()) is not tested here: whether it counts as a refusal is open. The sender-initiated cancel
// must give null.
// Red state: fails to compile on `SendResult.refusal` (the allowed red).
import 'dart:async';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/p5_fake_secure_peer.dart';
import '../helpers/p5_raw_peer.dart' show infoFor;
import '../helpers/test_data.dart';

const _zero = [Duration.zero, Duration.zero, Duration.zero];

/// A legacy (plaintext) peer that fails at a chosen later call.
class _LateFailure extends FakeSecurePeer {
  _LateFailure({required super.senderFp, required super.receiverFp})
    : super(legacy: true);

  Object? putError;
  Object? completeError;
  Object? finishError;

  @override
  Future<void> putChunk(
    String sessionId,
    String fileId,
    int index,
    Stream<List<int>> body, {
    required int length,
    required String chunkSha256,
    required String token,
  }) async {
    final e = putError;
    if (e != null) {
      await body.drain<void>();
      throw e;
    }
    return super.putChunk(
      sessionId,
      fileId,
      index,
      body,
      length: length,
      chunkSha256: chunkSha256,
      token: token,
    );
  }

  @override
  Future<FileVerification> completeFile(
    String sessionId,
    String fileId, {
    required String token,
    String? sha256,
  }) async {
    final e = completeError;
    if (e != null) throw e;
    return super.completeFile(sessionId, fileId, token: token, sha256: sha256);
  }

  @override
  Future<SessionStatus> finish(String sessionId) async {
    final e = finishError;
    if (e != null) throw e;
    return super.finish(sessionId);
  }
}

void main() {
  late Directory tmp;
  late File file;
  late DeviceInfo self;
  const senderFp =
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
  const receiverFp =
      'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('p6a_refusal');
    file = writeRandomFile(tmp, 'payload.bin', 2048);
    self = infoFor('p6a-sender', senderFp);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  _LateFailure peer() =>
      _LateFailure(senderFp: senderFp, receiverFp: receiverFp);

  FileSender sender(FakeSecurePeer p) => FileSender(
    client: p,
    self: self,
    retryDelays: _zero,
    acceptTimeout: const Duration(seconds: 5),
  );

  // Every refusal code with the FailureReason it already maps to.
  final createCases = <(LsErrorCode, FailureReason)>[
    (LsErrorCode.pinRequired, FailureReason.rejected),
    (LsErrorCode.pinInvalid, FailureReason.rejected),
    (LsErrorCode.blocked, FailureReason.rejected),
    (LsErrorCode.busy, FailureReason.rejected),
    (LsErrorCode.rateLimited, FailureReason.rejected),
    (LsErrorCode.tooLarge, FailureReason.rejected),
    (LsErrorCode.keyChanged, FailureReason.protocolError),
    (LsErrorCode.authInvalid, FailureReason.protocolError),
    (LsErrorCode.insufficientStorage, FailureReason.diskFull),
  ];

  // Orchestrator decision: SendResult.refusal.
  group('createSession raises an LsException', () {
    for (final (code, reason) in createCases) {
      test(
        '${code.wire}: refusal is the code, failureReason stays $reason',
        () async {
          final p = peer()..createError = LsException(code, 'refused');
          final r = await sender(p).send([file]);
          expect(r.isSuccess, isFalse);
          expect(r.status, TransferStatus.failed);
          expect(r.refusal, code);
          expect(r.failureReason, reason, reason: 'mapping unchanged');
          expect(p.puts, 0, reason: 'no byte was sent');
        },
      );
    }
  });

  group('a later call raises an LsException', () {
    test('INSUFFICIENT_STORAGE on a chunk upload', () async {
      final p = peer()
        ..putError = LsException(LsErrorCode.insufficientStorage, 'full');
      final r = await sender(p).send([file]);
      expect(r.status, TransferStatus.failed);
      expect(r.refusal, LsErrorCode.insufficientStorage);
      expect(r.failureReason, FailureReason.diskFull);
    });

    test('BLOCKED on complete', () async {
      final p = peer()..completeError = LsException(LsErrorCode.blocked);
      final r = await sender(p).send([file]);
      expect(r.status, TransferStatus.failed);
      expect(r.refusal, LsErrorCode.blocked);
      expect(r.failureReason, FailureReason.rejected);
    });

    test('AUTH_INVALID on finish', () async {
      final p = peer()..finishError = LsException(LsErrorCode.authInvalid);
      final r = await sender(p).send([file]);
      expect(r.status, TransferStatus.failed);
      expect(r.refusal, LsErrorCode.authInvalid);
      expect(r.failureReason, FailureReason.protocolError);
    });
  });

  // The positive twins of the groups above: nothing was refused.
  group('no refusal', () {
    test('success has refusal == null (twin: the same peer without the error completes)', () async {
      final p = peer();
      final r = await sender(p).send([file]);
      expect(r.isSuccess, isTrue, reason: '$r');
      expect(r.refusal, isNull);
    });

    test('no connection: refusal == null, reason NO_CONNECTION', () async {
      final p = peer()..createError = const SocketException('refused');
      final r = await sender(p).send([file]);
      expect(r.status, TransferStatus.failed);
      expect(r.failureReason, FailureReason.noConnection);
      expect(r.refusal, isNull);
    });

    test('timeout: refusal == null', () async {
      final p = peer()..createError = TimeoutException('slow');
      final r = await sender(p).send([file]);
      expect(r.status, TransferStatus.failed);
      expect(r.failureReason, FailureReason.noConnection);
      expect(r.refusal, isNull);
    });

    test(
      'a cancel by this sender: refusal == null, reason CANCELLED',
      () async {
        final p = peer()..holdAccept = Completer<void>();
        final s = sender(p);
        final fut = s.send([file]);
        for (var i = 0; i < 200 && !p.calls.contains('waitSession'); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(p.calls, contains('waitSession'), reason: 'the send is waiting');
        await s.cancel();
        final r = await fut;
        expect(r.status, TransferStatus.failed);
        expect(r.failureReason, FailureReason.cancelled);
        expect(r.refusal, isNull);
      },
    );
  });
}
