// Card K1: "Not Enough Free Space" Phone Error
// Core unit tests for FailureReason.storageUnusable and FileSender classification.

import 'dart:async';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/p5_fake_secure_peer.dart';
import '../helpers/p5_raw_peer.dart' show infoFor;
import '../helpers/test_data.dart';

const _zero = [Duration.zero, Duration.zero, Duration.zero];

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
  group('FailureReason.storageUnusable enum', () {
    test(
      'storageUnusable exists with wire STORAGE_UNUSABLE and round-trips via fromWire',
      () {
        expect(FailureReason.storageUnusable.wire, 'STORAGE_UNUSABLE');
        expect(
          FailureReason.fromWire('STORAGE_UNUSABLE'),
          FailureReason.storageUnusable,
        );
      },
    );
  });

  group('FileSender mapping for insufficientStorage', () {
    late Directory tmp;
    late File file;
    late DeviceInfo self;
    const senderFp =
        'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
    const receiverFp =
        'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('k1_storage_unusable');
      file = writeRandomFile(tmp, 'payload.bin', 2048);
      self = infoFor('k1-sender', senderFp);
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    _LateFailure peer() =>
        _LateFailure(senderFp: senderFp, receiverFp: receiverFp);

    FileSender sender(_LateFailure p) => FileSender(
      client: p,
      self: self,
      retryDelays: _zero,
      acceptTimeout: const Duration(seconds: 5),
    );

    test(
      'when download folder is not usable occurs on createSession, sender failure reason is storageUnusable',
      () async {
        final p = peer()
          ..createError = LsException(
            LsErrorCode.insufficientStorage,
            'download folder is not usable',
          );
        final r = await sender(p).send([file]);
        expect(r.isSuccess, isFalse);
        expect(r.status, TransferStatus.failed);
        expect(r.refusal, LsErrorCode.insufficientStorage);
        expect(r.failureReason, FailureReason.storageUnusable);
      },
    );

    test(
      'when download folder is not usable occurs during transfer (chunk upload), sender failure reason is storageUnusable',
      () async {
        final p = peer()
          ..putError = LsException(
            LsErrorCode.insufficientStorage,
            'download folder is not usable',
          );
        final r = await sender(p).send([file]);
        expect(r.isSuccess, isFalse);
        expect(r.status, TransferStatus.failed);
        expect(r.refusal, LsErrorCode.insufficientStorage);
        expect(r.failureReason, FailureReason.storageUnusable);
      },
    );

    test(
      'when not enough free space occurs on createSession, sender failure reason remains diskFull',
      () async {
        final p = peer()
          ..createError = LsException(
            LsErrorCode.insufficientStorage,
            'not enough free space (need 1000 bytes)',
          );
        final r = await sender(p).send([file]);
        expect(r.isSuccess, isFalse);
        expect(r.status, TransferStatus.failed);
        expect(r.refusal, LsErrorCode.insufficientStorage);
        expect(r.failureReason, FailureReason.diskFull);
      },
    );

    test(
      'when not enough free space occurs during transfer, sender failure reason remains diskFull',
      () async {
        final p = peer()
          ..putError = LsException(
            LsErrorCode.insufficientStorage,
            'not enough free space (need 1000 bytes)',
          );
        final r = await sender(p).send([file]);
        expect(r.isSuccess, isFalse);
        expect(r.status, TransferStatus.failed);
        expect(r.refusal, LsErrorCode.insufficientStorage);
        expect(r.failureReason, FailureReason.diskFull);
      },
    );
  });
}
