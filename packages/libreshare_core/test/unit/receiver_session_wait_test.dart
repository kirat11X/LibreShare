// FileReceiver.getSession long-poll semantics (LSP-1 4.3, `GET /sessions/{sid}?wait=N`):
//
//   "If the session is already past PENDING the response is immediate. While PENDING, the server
//    holds the request until the status changes or `wait` seconds elapse, then returns the current
//    SessionStatus (still PENDING on a timeout)."
//
// The engine hides a deviation with a subclass override; these tests drive FileReceiver itself,
// in real time (wait = 3 s, "immediate" = under 1 s on a Stopwatch).
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:libreshare_core/src/model/device.dart';
import 'package:libreshare_core/src/model/file_item.dart';
import 'package:libreshare_core/src/model/session_models.dart';
import 'package:libreshare_core/src/model/transfer_status.dart';
import 'package:libreshare_core/src/transfer/file_receiver.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const int _cs = 64 * 1024; // smallest legal chunk size
const Duration _wait = Duration(seconds: 3);
const Duration _immediate = Duration(seconds: 1);

const _self = DeviceInfo(
  deviceId: 'rx-id',
  alias: 'Receiver',
  platform: 'linux',
);
const _sender = DeviceInfo(
  deviceId: 'tx-id',
  alias: 'Sender',
  platform: 'linux',
);

final Uint8List _data = Uint8List.fromList(List.generate(50, (i) => i));

SessionRequest _request() => SessionRequest(
  sender: _sender,
  files: [
    FileItem(
      fileId: 'f',
      fileName: 'a.bin',
      size: _data.length,
      chunkCount: 1,
      sha256: sha256.convert(_data).toString(),
    ),
  ],
  totalSize: _data.length,
  chunkSize: _cs,
);

void main() {
  late Directory tmp;
  final receivers = <FileReceiver>[];

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ls_wait_');
  });
  tearDown(() {
    for (final r in receivers) {
      r.dispose();
    }
    receivers.clear();
    tmp.deleteSync(recursive: true);
  });

  FileReceiver newReceiver({
    bool autoAccept = false,
    Duration permissionTimeout = const Duration(seconds: 120),
  }) {
    final r = FileReceiver(
      self: _self,
      downloadDir: Directory(p.join(tmp.path, 'Downloads'))..createSync(),
      autoAccept: autoAccept,
      onEvent: (_) {},
      permissionTimeout: permissionTimeout,
      freeSpaceProbe: (_) async => null,
    );
    receivers.add(r);
    return r;
  }

  Future<String> open(FileReceiver rx) async => (await rx.createSession(
    _request(),
    remoteAddress: '127.0.0.1',
  )).sessionId;

  /// Polls with [wait] and returns the status together with the time the call took.
  Future<(SessionStatus, Duration)> poll(
    FileReceiver rx,
    String sid,
    Duration wait,
  ) async {
    final sw = Stopwatch()..start();
    final st = await rx.getSession(sid, wait: wait);
    return (st, sw.elapsed);
  }

  /// Drives an auto-accepted session to COMPLETED.
  Future<String> completedSession(FileReceiver rx) async {
    final st = await rx.createSession(_request(), remoteAddress: '127.0.0.1');
    final token = st.acceptedFiles['f']!.token;
    await rx.putChunk(
      st.sessionId,
      'f',
      0,
      Stream.value(_data),
      token: token,
      chunkSha256: sha256.convert(_data).toString(),
    );
    await rx.completeFile(st.sessionId, 'f', token: token);
    expect((await rx.finish(st.sessionId)).status, TransferStatus.completed);
    return st.sessionId;
  }

  group('already past PENDING: the poll answers at once', () {
    test(
      '(a) IN_PROGRESS (auto-accepted) + wait 3 s -> immediate IN_PROGRESS',
      () async {
        final rx = newReceiver(autoAccept: true);
        final sid = await open(rx);
        final (st, took) = await poll(rx, sid, _wait);
        expect(st.status, TransferStatus.inProgress);
        expect(
          took,
          lessThan(_immediate),
          reason:
              'IN_PROGRESS is past PENDING: nothing to wait for (LSP-1 4.3)',
        );
      },
    );

    test('(f) a second poll right after accept() is immediate (the real client loop)', () async {
      final rx = newReceiver();
      final sid = await open(rx);
      final first = rx.getSession(sid, wait: _wait);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await rx.accept(sid);
      expect((await first).status, TransferStatus.inProgress);

      final (st, took) = await poll(rx, sid, _wait);
      expect(st.status, TransferStatus.inProgress);
      expect(st.acceptedFiles['f']!.token, isNotEmpty);
      expect(took, lessThan(_immediate));
    });

    test('(d) rejected (FAILED/REJECTED) + wait 3 s -> immediate', () async {
      final rx = newReceiver();
      final sid = await open(rx);
      await rx.reject(sid);
      final (st, took) = await poll(rx, sid, _wait);
      expect(st.status, TransferStatus.failed);
      expect(st.failureReason, FailureReason.rejected);
      expect(took, lessThan(_immediate));
    });

    test('(d) cancelled (FAILED/CANCELLED) + wait 3 s -> immediate', () async {
      final rx = newReceiver();
      final sid = await open(rx);
      await rx.cancel(sid);
      final (st, took) = await poll(rx, sid, _wait);
      expect(st.status, TransferStatus.failed);
      expect(st.failureReason, FailureReason.cancelled);
      expect(took, lessThan(_immediate));
    });

    test(
      '(d) permission timeout (FAILED/TIMEOUT) + wait 3 s -> immediate',
      () async {
        final rx = newReceiver(
          permissionTimeout: const Duration(milliseconds: 80),
        );
        final sid = await open(rx);
        await Future<void>.delayed(const Duration(milliseconds: 400));
        final (st, took) = await poll(rx, sid, _wait);
        expect(st.status, TransferStatus.failed);
        expect(st.failureReason, FailureReason.timeout);
        expect(took, lessThan(_immediate));
      },
    );

    test('(d) COMPLETED + wait 3 s -> immediate', () async {
      final rx = newReceiver(autoAccept: true);
      final sid = await completedSession(rx);
      final (st, took) = await poll(rx, sid, _wait);
      expect(st.status, TransferStatus.completed);
      expect(took, lessThan(_immediate));
    });
  });

  group('PENDING: the poll is held until the status changes or wait elapses', () {
    test(
      '(b) held, then accept() wakes it within 1 s and it returns IN_PROGRESS',
      () async {
        final rx = newReceiver();
        final sid = await open(rx);
        var done = false;
        final polled = rx
            .getSession(sid, wait: _wait)
            .whenComplete(() => done = true);

        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(done, isFalse, reason: 'a PENDING session holds the poll');

        final sw = Stopwatch()..start();
        await rx.accept(sid);
        final st = await polled;
        expect(st.status, TransferStatus.inProgress);
        expect(
          sw.elapsed,
          lessThan(_immediate),
          reason: 'accept() wakes the held poll, no waiting for the 3 s',
        );
        expect(st.acceptedFiles['f']!.token, isNotEmpty);
      },
    );

    test('(b) held, then reject() wakes it within 1 s and it returns FAILED/REJECTED', () async {
      final rx = newReceiver();
      final sid = await open(rx);
      final polled = rx.getSession(sid, wait: _wait);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final sw = Stopwatch()..start();
      await rx.reject(sid);
      final st = await polled;
      expect(st.status, TransferStatus.failed);
      expect(st.failureReason, FailureReason.rejected);
      expect(sw.elapsed, lessThan(_immediate));
    });

    test(
      '(c) wait 1 s and nobody decides -> PENDING after 0.9 s..2.5 s',
      () async {
        final rx = newReceiver();
        final sid = await open(rx);
        final (st, took) = await poll(rx, sid, const Duration(seconds: 1));
        expect(st.status, TransferStatus.pending);
        expect(st.acceptedFiles, isEmpty, reason: 'no tokens before consent');
        expect(took, greaterThanOrEqualTo(const Duration(milliseconds: 900)));
        expect(took, lessThan(const Duration(milliseconds: 2500)));
      },
    );
  });

  group('(e) wait = 0 is immediate in every state', () {
    Future<void> expectImmediate(
      FileReceiver rx,
      String sid,
      TransferStatus want,
    ) async {
      final (st, took) = await poll(rx, sid, Duration.zero);
      expect(st.status, want);
      expect(took, lessThan(_immediate));
    }

    test('PENDING', () async {
      final rx = newReceiver();
      await expectImmediate(rx, await open(rx), TransferStatus.pending);
    });

    test('IN_PROGRESS', () async {
      final rx = newReceiver(autoAccept: true);
      await expectImmediate(rx, await open(rx), TransferStatus.inProgress);
    });

    test('FAILED', () async {
      final rx = newReceiver();
      final sid = await open(rx);
      await rx.reject(sid);
      await expectImmediate(rx, sid, TransferStatus.failed);
    });

    test('COMPLETED', () async {
      final rx = newReceiver(autoAccept: true);
      await expectImmediate(
        rx,
        await completedSession(rx),
        TransferStatus.completed,
      );
    });
  });
}
