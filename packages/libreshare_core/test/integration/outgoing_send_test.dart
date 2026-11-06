// OutgoingSend (LibreShareEngine.beginSendTo / beginSendFiles): the cancellable
// send handle the UI drives. Two or three real engines on loopback aliases,
// real HTTP in between.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/test_data.dart';

/// One engine, its download directory and every event it emitted.
class Node {
  Node(this.name, this.ip, this.engine, this.rx, this.events, this.port);

  final String name;
  final String ip;
  final LibreShareEngine engine;
  final Directory rx;
  final List<LsEvent> events;
  final int port;

  FileReceiver get receiver => engine.receiver;

  List<SessionFinished> get finished =>
      events.whereType<SessionFinished>().toList();

  List<File> get savedFiles => rx.existsSync()
      ? rx.listSync(recursive: true).whereType<File>().toList()
      : const [];
}

late Directory sandbox;
final List<Node> nodes = [];
final List<StreamSubscription<LsEvent>> subs = [];

Future<Node> startNode(
  String name, {
  String ip = '127.0.0.1',
  bool autoAccept = true,
  int preferredPort = 0,
  Duration? permissionTimeout,
  DiscoveryConfig discovery = DiscoveryConfig.disabled,
}) async {
  final rx = Directory(p.join(sandbox.path, 'rx-$name'));
  final engine = LibreShareEngine(
    self: DeviceInfo(
      deviceId: 'device-$name',
      alias: 'Engine-$name',
      platform: 'linux',
    ),
    downloadDir: rx,
    preferredPort: preferredPort,
    autoAccept: autoAccept,
    bindAddress: InternetAddress(ip),
    enableRateLimit: false,
    permissionTimeout: permissionTimeout ?? kPermissionTimeout,
    discovery: discovery,
  );
  final events = <LsEvent>[];
  subs.add(engine.events.listen(events.add));
  final port = await engine.start();
  final node = Node(name, ip, engine, rx, events, port);
  nodes.add(node);
  return node;
}

File source(String name, int size, {int seed = 1}) => writeRandomFile(
  Directory(p.join(sandbox.path, 'src')),
  name,
  size,
  seed: seed,
);

Future<void> untilTrue(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 10),
  String what = 'condition',
}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) fail('$what not met within $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Runs [send]'s event stream into a list; completes the list when it is done.
class Seen {
  Seen(OutgoingSend send, {void Function(LsEvent event)? onEvent}) {
    done = send.events.listen((e) {
      all.add(e);
      onEvent?.call(e);
    }).asFuture<void>();
  }

  final List<LsEvent> all = [];
  late final Future<void> done;

  List<T> of<T extends LsEvent>() => all.whereType<T>().toList();
}

DiscoveredDevice deviceOf(
  Node n, {
  String? address,
  List<String>? addrs,
  int? port,
}) => DiscoveredDevice(
  info: DeviceInfo(
    deviceId: n.engine.self.deviceId,
    alias: n.engine.self.alias,
    platform: 'linux',
    port: port ?? n.port,
    addrs: [
      for (final a in addrs ?? [n.ip]) DeviceAddress(a),
    ],
  ),
  address: address ?? n.ip,
  lastSeen: DateTime.now(),
  source: DiscoverySource.multicast,
);

void main() {
  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('ls_outgoing_');
  });
  tearDown(() async {
    for (final n in nodes.reversed) {
      await n.engine.dispose(force: true);
    }
    for (final s in subs) {
      await s.cancel();
    }
    nodes.clear();
    subs.clear();
    await sandbox.delete(recursive: true);
  });

  group('success', () {
    test('events: created, progress, finished; files arrive intact', () async {
      final a = await startNode('A', ip: '127.0.0.2');
      final b = await startNode('B', ip: '127.0.0.3');
      final small = source('small.bin', 1000, seed: 1);
      final big = source('big.bin', 9 * 1024 * 1024 + 17, seed: 2); // 3 chunks

      final send = a.engine.beginSendFiles(
        [big, small],
        host: b.ip,
        port: b.port,
        chunkConcurrency: 2,
      );
      expect(send.sessionId, isNull);
      expect(send.cancelRequested, isFalse);
      expect(send.isFinished, isFalse);
      final seen = Seen(send);
      final result = await send.result;
      await seen.done; // the stream is done after the last event

      expect(result.isSuccess, isTrue, reason: '$result');
      expect(send.isFinished, isTrue);
      expect(send.sessionId, result.sessionId);
      for (final f in [small, big]) {
        final dst = File(p.join(b.rx.path, p.basename(f.path)));
        expect(await filesIdentical(f, dst), isTrue, reason: f.path);
      }

      final created = seen.all.first as SessionCreated;
      expect(created.outgoing, isTrue);
      expect(created.sessionId, result.sessionId);
      final fin = seen.all.last as SessionFinished;
      expect(fin.success, isTrue);
      expect(seen.of<SessionFinished>(), hasLength(1));
      expect(seen.of<SessionCreated>(), hasLength(1));

      final progress = seen.of<FileProgress>();
      expect(progress, isNotEmpty);
      final byFile = <String, List<FileProgress>>{};
      for (final e in progress) {
        expect(e.sessionId, result.sessionId);
        byFile.putIfAbsent(e.fileId, () => []).add(e);
      }
      expect(byFile.keys, hasLength(2));
      for (final list in byFile.values) {
        for (var i = 1; i < list.length; i++) {
          expect(
            list[i].bytesDone,
            greaterThanOrEqualTo(list[i - 1].bytesDone),
            reason: 'progress never goes backwards',
          );
        }
        expect(list.last.bytesDone, list.last.bytesTotal);
      }
      // The big file reports more than once (3 chunks).
      expect(
        byFile.values.map((l) => l.length).reduce((x, y) => x > y ? x : y),
        greaterThan(1),
      );

      // The engine-wide stream carries the same events.
      await untilTrue(
        () => a.events.whereType<SessionFinished>().isNotEmpty,
        what: 'engine SessionFinished',
      );
      expect(a.events.whereType<FileProgress>(), hasLength(progress.length));
      expect(
        a.events.whereType<SessionCreated>().where((e) => e.outgoing),
        hasLength(1),
      );
    });

    test('a listener that attaches late still sees every event', () async {
      final a = await startNode('A', ip: '127.0.0.2');
      final b = await startNode('B', ip: '127.0.0.3');
      final send = a.engine.beginSendFiles(
        [source('x.bin', 500)],
        host: b.ip,
        port: b.port,
      );
      final result = await send.result;
      expect(result.isSuccess, isTrue);
      final seen = Seen(send);
      await seen.done;
      expect(seen.all.first, isA<SessionCreated>());
      expect(seen.all.last, isA<SessionFinished>());
    });

    test('sendFiles still resolves to the same result as the handle', () async {
      final a = await startNode('A', ip: '127.0.0.2');
      final b = await startNode('B', ip: '127.0.0.3');
      final res = await a.engine.sendFiles(
        [source('y.bin', 3000)],
        host: b.ip,
        port: b.port,
      );
      expect(res.isSuccess, isTrue);
      expect(res.bytesSent, 3000);
    });

    test('cancel() after the send completed changes nothing', () async {
      final a = await startNode('A', ip: '127.0.0.2');
      final b = await startNode('B', ip: '127.0.0.3');
      final send = a.engine.beginSendFiles(
        [source('z.bin', 100)],
        host: b.ip,
        port: b.port,
      );
      final seen = Seen(send);
      final result = await send.result;
      await send.cancel();
      await seen.done;
      expect(result.isSuccess, isTrue);
      expect(seen.of<SessionFinished>().single.success, isTrue);
      expect(b.finished.single.success, isTrue);
    });
  });

  group('cancel', () {
    test(
      'before anything reached the peer: no session is ever created',
      () async {
        final a = await startNode('A', ip: '127.0.0.2');
        final b = await startNode('B', ip: '127.0.0.3', autoAccept: false);
        final send = a.engine.beginSendFiles(
          [source('x.bin', 1000)],
          host: b.ip,
          port: b.port,
        );
        final seen = Seen(send);
        final cancelling = send.cancel(); // synchronously after beginSendFiles
        expect(send.cancelRequested, isTrue);
        final result = await send.result;
        await cancelling;
        await seen.done;

        expect(result.status, TransferStatus.failed);
        expect(result.failureReason, FailureReason.cancelled);
        expect(result.sessionId, isEmpty);
        expect(seen.all, hasLength(1));
        final fin = seen.all.single as SessionFinished;
        expect(fin.success, isFalse);
        expect(fin.reason, 'CANCELLED');
        expect(fin.sessionId, isEmpty);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(b.events.whereType<SessionCreated>(), isEmpty);
        expect(b.receiver.pendingSessionIds, isEmpty);
      },
    );

    test(
      'while the peer\'s consent prompt is open: the peer sees it',
      () async {
        final a = await startNode('A', ip: '127.0.0.2');
        final b = await startNode('B', ip: '127.0.0.3', autoAccept: false);
        final send = a.engine.beginSendFiles(
          [source('x.bin', 1000)],
          host: b.ip,
          port: b.port,
        );
        final seen = Seen(send);
        await untilTrue(
          () => b.receiver.pendingSessionIds.isNotEmpty,
          what: 'consent prompt on B',
        );
        final sid = b.receiver.pendingSessionIds.single;
        expect(b.receiver.activeSessionCount, 1);

        await send.cancel();
        final result = await send.result;
        await seen.done;

        expect(result.failureReason, FailureReason.cancelled);
        expect(result.sessionId, sid);
        expect(send.sessionId, sid);
        expect(seen.of<SessionFinished>().single.reason, 'CANCELLED');
        // The receiver's prompt and session closed at once, not after 120 s.
        expect(b.receiver.pendingSessionIds, isEmpty);
        expect(b.receiver.activeSessionCount, 0);
        await untilTrue(
          () => b.finished.isNotEmpty,
          what: 'SessionFinished on B',
        );
        expect(b.finished.single.reason, 'CANCELLED');
        expect(b.finished.single.sessionId, sid);
        expect(b.savedFiles, isEmpty);
      },
    );

    test('mid-transfer: uploading stops, the peer drops the session', () async {
      final a = await startNode('A', ip: '127.0.0.2');
      final b = await startNode('B', ip: '127.0.0.3');
      final big = source('big.bin', 17 * 1024 * 1024, seed: 5); // 5 chunks
      final send = a.engine.beginSendFiles(
        [big],
        host: b.ip,
        port: b.port,
        chunkConcurrency: 1,
      );
      // Cancel on the first progress event: the next chunk still has to be
      // hashed and uploaded, which takes far longer than this microtask.
      var cancelled = false;
      final seen = Seen(
        send,
        onEvent: (e) {
          if (e is FileProgress && !cancelled) {
            cancelled = true;
            unawaited(send.cancel());
          }
        },
      );
      final result = await send.result;
      await seen.done;

      expect(result.failureReason, FailureReason.cancelled);
      expect(result.bytesSent, lessThan(big.lengthSync()));
      expect(seen.of<SessionFinished>().single.reason, 'CANCELLED');
      await untilTrue(
        () => b.finished.isNotEmpty,
        what: 'SessionFinished on B',
      );
      expect(b.finished.single.reason, 'CANCELLED');
      expect(File(p.join(b.rx.path, 'big.bin')).existsSync(), isFalse);
      expect(b.receiver.activeSessionCount, 0);
    });

    test(
      'at every moment of the handshake the peer ends up with no prompt',
      () async {
        final a = await startNode('A', ip: '127.0.0.2');
        final b = await startNode('B', ip: '127.0.0.3', autoAccept: false);
        final f = source('x.bin', 2000);
        for (var delayMs = 0; delayMs <= 14; delayMs++) {
          final send = a.engine.beginSendFiles([f], host: b.ip, port: b.port);
          final seen = Seen(send);
          if (delayMs > 0) {
            await Future<void>.delayed(Duration(milliseconds: delayMs));
          }
          unawaited(send.cancel());
          final result = await send.result.timeout(const Duration(seconds: 5));
          await seen.done;
          expect(
            result.failureReason,
            FailureReason.cancelled,
            reason: 'cancel after $delayMs ms',
          );
          await untilTrue(
            () => b.receiver.activeSessionCount == 0,
            timeout: const Duration(seconds: 3),
            what: 'receiver closed its prompt (cancel after $delayMs ms)',
          );
          expect(b.savedFiles, isEmpty);
        }
      },
    );

    test('a double cancel is harmless', () async {
      final a = await startNode('A', ip: '127.0.0.2');
      final b = await startNode('B', ip: '127.0.0.3', autoAccept: false);
      final send = a.engine.beginSendFiles(
        [source('x.bin', 1000)],
        host: b.ip,
        port: b.port,
      );
      final seen = Seen(send);
      await untilTrue(
        () => b.receiver.pendingSessionIds.isNotEmpty,
        what: 'consent prompt on B',
      );
      await Future.wait([send.cancel(), send.cancel()]);
      await send.cancel();
      final result = await send.result;
      await send.cancel(); // and after it ended
      await seen.done;

      expect(result.failureReason, FailureReason.cancelled);
      expect(seen.of<SessionFinished>(), hasLength(1));
      await untilTrue(
        () => b.finished.isNotEmpty,
        what: 'SessionFinished on B',
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(b.finished, hasLength(1));
      expect(b.receiver.activeSessionCount, 0);
    });

    test(
      'while the address is being looked up: prompt, nothing sent',
      () async {
        final probeEntered = Completer<void>();
        final a = await startNode(
          'A',
          ip: '127.0.0.2',
          discovery: DiscoveryConfig(
            enabled: false,
            // Never answers: the lookup would sit there until probeTimeout.
            infoProbe: (ip, port, timeout) {
              if (!probeEntered.isCompleted) probeEntered.complete();
              return Completer<DeviceInfo?>().future;
            },
          ),
        );
        final b = await startNode('B', ip: '127.0.0.3', autoAccept: false);
        final send = a.engine.beginSendTo(deviceOf(b), [
          source('x.bin', 1000),
        ], probeTimeout: const Duration(minutes: 5));
        final seen = Seen(send);
        await probeEntered.future;
        await send.cancel();
        final result = await send.result.timeout(const Duration(seconds: 5));
        await seen.done;

        expect(result.failureReason, FailureReason.cancelled);
        expect(result.sessionId, isEmpty);
        expect(seen.all, hasLength(1));
        expect((seen.all.single as SessionFinished).reason, 'CANCELLED');
        expect(b.events.whereType<SessionCreated>(), isEmpty);
      },
    );
  });

  group('finding the peer (beginSendTo)', () {
    test('tries the next address when the first does not answer', () async {
      final a = await startNode('A', ip: '127.0.0.2');
      final b = await startNode('B', ip: '127.0.0.3');
      final f = source('second.bin', 777, seed: 7);
      final send = a.engine.beginSendTo(
        deviceOf(b, address: '127.0.0.250', addrs: ['127.0.0.251', b.ip]),
        [f],
        probeTimeout: const Duration(milliseconds: 300),
      );
      final result = await send.result;
      expect(result.isSuccess, isTrue, reason: '$result');
      expect(
        await filesIdentical(f, File(p.join(b.rx.path, 'second.bin'))),
        isTrue,
      );
    });

    test('skips an address where a different device answers', () async {
      final impostor = await startNode('Impostor', ip: '127.0.0.2');
      // Same port, other alias: the first address is the impostor's.
      final b = await startNode(
        'B',
        ip: '127.0.0.3',
        preferredPort: impostor.port,
      );
      if (b.port != impostor.port) {
        markTestSkipped('test needs one port on two IPs');
        return;
      }
      final a = await startNode('A', ip: '127.0.0.4');
      final f = source('real.bin', 4000, seed: 3);
      final send = a.engine.beginSendTo(
        deviceOf(b, address: impostor.ip, addrs: [impostor.ip, b.ip]),
        [f],
      );
      final result = await send.result;
      expect(result.isSuccess, isTrue, reason: '$result');
      expect(impostor.savedFiles, isEmpty);
      expect(impostor.events.whereType<SessionCreated>(), isEmpty);
      expect(
        await filesIdentical(f, File(p.join(b.rx.path, 'real.bin'))),
        isTrue,
      );
    });

    test('nobody answers: FAILED(NO_CONNECTION), one failed event', () async {
      final a = await startNode('A', ip: '127.0.0.2');
      final ghost = DiscoveredDevice(
        info: const DeviceInfo(
          deviceId: 'ghost',
          alias: 'Ghost',
          platform: 'linux',
          port: 53318,
          addrs: [DeviceAddress('127.0.0.251')],
        ),
        address: '127.0.0.250',
        lastSeen: DateTime.now(),
        source: DiscoverySource.multicast,
      );
      final send = a.engine.beginSendTo(ghost, [
        source('x.bin', 10),
      ], probeTimeout: const Duration(milliseconds: 200));
      final seen = Seen(send);
      final result = await send.result;
      await seen.done;

      expect(result.status, TransferStatus.failed);
      expect(result.failureReason, FailureReason.noConnection);
      expect(result.sessionId, isEmpty);
      expect(result.bytesSent, 0);
      expect(seen.all, hasLength(1));
      final fin = seen.all.single as SessionFinished;
      expect(fin.success, isFalse);
      expect(fin.reason, 'NO_CONNECTION');
      expect(fin.sessionId, isEmpty);
      await untilTrue(
        () => a.finished.isNotEmpty,
        what: 'engine-wide SessionFinished',
      );
      expect(a.finished, hasLength(1));
      expect(a.finished.single.reason, 'NO_CONNECTION');
      expect(send.sessionId, isNull);
    });

    test('a device without a usable port is unreachable too', () async {
      final a = await startNode('A', ip: '127.0.0.2');
      final b = await startNode('B', ip: '127.0.0.3');
      final send = a.engine.beginSendTo(deviceOf(b, port: 0), [
        source('x.bin', 10),
      ]);
      final result = await send.result;
      expect(result.failureReason, FailureReason.noConnection);
      expect(b.events.whereType<SessionCreated>(), isEmpty);
    });

    test('sendTo behaves as before: same result for the same inputs', () async {
      final a = await startNode('A', ip: '127.0.0.2');
      final b = await startNode('B', ip: '127.0.0.3');
      final f = source('via-sendto.bin', 5000);
      final res = await a.engine.sendTo(deviceOf(b), [f]);
      expect(res.isSuccess, isTrue);
      expect(
        await filesIdentical(f, File(p.join(b.rx.path, 'via-sendto.bin'))),
        isTrue,
      );
    });
  });

  group('local file problems', () {
    test(
      'a missing file is thrown by result and sendFiles, no events',
      () async {
        final a = await startNode('A', ip: '127.0.0.2');
        final b = await startNode('B', ip: '127.0.0.3');
        final gone = File(p.join(sandbox.path, 'gone.bin'));
        final send = a.engine.beginSendFiles([gone], host: b.ip, port: b.port);
        final seen = Seen(send);
        await expectLater(send.result, throwsA(isA<FileSystemException>()));
        await seen.done;
        expect(seen.all, isEmpty);
        expect(send.isFinished, isTrue);
        await expectLater(
          a.engine.sendFiles([gone], host: b.ip, port: b.port),
          throwsA(isA<FileSystemException>()),
        );
        expect(b.events.whereType<SessionCreated>(), isEmpty);
      },
    );

    test('an empty list is a programming error, as for sendFiles', () async {
      final a = await startNode('A', ip: '127.0.0.2');
      expect(
        () => a.engine.beginSendFiles(const [], host: '127.0.0.3', port: 1),
        throwsArgumentError,
      );
      await expectLater(
        a.engine.sendFiles(const [], host: '127.0.0.3', port: 1),
        throwsArgumentError,
      );
    });
  });
}
