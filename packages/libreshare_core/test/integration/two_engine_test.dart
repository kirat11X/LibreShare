// Two LibreShareEngine instances in one process (spec section 13 "Two-instance"):
// distinct loopback ports and download directories, real HTTP in between.
//
// Covers FR-07 (multi-file session), FR-08 (chunk boundaries), FR-09/10
// (byte-identical, SHA-256), FR-11 (events on both sides), FR-17 (A->B, B->A,
// concurrently), FR-01 (port fallback), FR-06 (reject / timeout), FR-16
// (path traversal) and a regression for the receiver-shutdown race.
import 'dart:async';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/test_data.dart';

const String loopback = '127.0.0.1';

/// One engine plus everything a test needs to inspect it.
class Node {
  Node(this.name, this.engine, this.rx, this.log, this.port);

  final String name;
  final LibreShareEngine engine;

  /// Download directory.
  final Directory rx;
  final EventLog log;

  /// The bound port, remembered so it stays readable after the engine stopped.
  final int port;
}

/// Records every [LsEvent] an engine emits.
class EventLog {
  EventLog(Stream<LsEvent> events) {
    _sub = events.listen(all.add);
  }

  final List<LsEvent> all = [];
  late final StreamSubscription<LsEvent> _sub;

  List<T> of<T extends LsEvent>() => all.whereType<T>().toList();

  /// `SessionFinished` events, outgoing and incoming alike.
  List<SessionFinished> get finished => of<SessionFinished>();

  Future<void> close() => _sub.cancel();
}

late Directory sandbox;
final List<Node> nodes = [];

Future<Node> startNode(
  String name, {
  bool autoAccept = true,
  Duration? permissionTimeout,
  int preferredPort = 0,
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
    bindAddress: InternetAddress.loopbackIPv4,
    enableRateLimit: false,
    permissionTimeout: permissionTimeout ?? kPermissionTimeout,
  );
  final log = EventLog(engine.events);
  final port = await engine.start();
  final node = Node(name, engine, rx, log, port);
  nodes.add(node);
  return node;
}

/// Test fixture: file [name] of [size] bytes with a fixed whole-second mtime.
File source(String name, int size, {int seed = 1, int mtimeSecs = 0}) =>
    writeRandomFile(
      Directory(p.join(sandbox.path, 'src-${nodes.length}')),
      name,
      size,
      seed: seed,
      mtime: DateTime.utc(2024, 3, 15, 12, 34, mtimeSecs % 60),
    );

/// Lets queued stream events reach their listeners. Engine events are delivered
/// asynchronously (broadcast stream), so a test that inspects an [EventLog]
/// right after `sendFiles` returned must yield first.
Future<void> settle() => Future<void>.delayed(Duration.zero);

/// `from.engine.sendFiles` to [to] over loopback, then [settle].
Future<SendResult> sendFiles(
  Node from,
  Node to,
  List<File> files, {
  int chunkConcurrency = 3,
  Duration acceptTimeout = kPermissionTimeout,
}) async {
  final res = await from.engine.sendFiles(
    files,
    host: loopback,
    port: to.port,
    chunkConcurrency: chunkConcurrency,
    acceptTimeout: acceptTimeout,
  );
  await settle();
  return res;
}

Future<void> untilTrue(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) fail('condition not met within $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Asserts that [dst] is a byte-identical copy of [src] (length, bytes, SHA-256)
/// and, if [checkMtime], that the sender's modification time was restored.
Future<void> expectCopy(File src, File dst, {bool checkMtime = true}) async {
  expect(dst.existsSync(), isTrue, reason: '${dst.path} missing');
  expect(dst.lengthSync(), src.lengthSync(), reason: 'length of ${dst.path}');
  expect(
    await sha256OfFileHex(dst),
    await sha256OfFileHex(src),
    reason: 'sha256 of ${dst.path}',
  );
  expect(
    await filesIdentical(src, dst),
    isTrue,
    reason: 'bytes of ${dst.path}',
  );
  if (checkMtime) {
    expect(
      dst.lastModifiedSync().millisecondsSinceEpoch,
      src.lastModifiedSync().millisecondsSinceEpoch,
      reason: 'mtime of ${dst.path}',
    );
  }
}

/// A [PeerClient] that forwards to [inner] but rewrites the manifest, so a test
/// can send the hostile names no honest [FileSender] would produce.
class RewritingClient implements PeerClient {
  RewritingClient(this.inner, this.rewrite);

  final PeerClient inner;
  final FileItem Function(int index, FileItem item) rewrite;

  @override
  Future<SessionStatus> createSession(SessionRequest r) => inner.createSession(
    SessionRequest(
      sender: r.sender,
      pin: r.pin,
      chunkSize: r.chunkSize,
      files: [for (var i = 0; i < r.files.length; i++) rewrite(i, r.files[i])],
      totalSize: r.totalSize,
      tunnelOffer: r.tunnelOffer,
    ),
  );

  @override
  Future<DeviceInfo> info() => inner.info();
  @override
  Future<DeviceInfo> register(DeviceInfo self) => inner.register(self);
  @override
  Future<SessionStatus> waitSession(String sessionId, {int waitSeconds = 25}) =>
      inner.waitSession(sessionId, waitSeconds: waitSeconds);
  @override
  Future<FileState> fileState(
    String sessionId,
    String fileId, {
    required String token,
  }) => inner.fileState(sessionId, fileId, token: token);
  @override
  Future<void> putChunk(
    String sessionId,
    String fileId,
    int index,
    Stream<List<int>> body, {
    required int length,
    required String chunkSha256,
    required String token,
  }) => inner.putChunk(
    sessionId,
    fileId,
    index,
    body,
    length: length,
    chunkSha256: chunkSha256,
    token: token,
  );
  @override
  Future<FileVerification> completeFile(
    String sessionId,
    String fileId, {
    required String token,
    String? sha256,
  }) => inner.completeFile(sessionId, fileId, token: token, sha256: sha256);
  @override
  Future<SessionStatus> finish(String sessionId) => inner.finish(sessionId);
  @override
  Future<void> cancel(String sessionId) => inner.cancel(sessionId);
  @override
  void close() => inner.close();
}

FileItem withNames(FileItem i, {String? fileName, String? relativePath}) =>
    FileItem(
      fileId: i.fileId,
      fileName: fileName ?? i.fileName,
      relativePath: relativePath ?? i.relativePath,
      size: i.size,
      chunkCount: i.chunkCount,
      mime: i.mime,
      sha256: i.sha256,
      modified: i.modified,
    );

void main() {
  late Node a;
  late Node b;

  setUp(() async {
    sandbox = Directory.systemTemp.createTempSync('ls_two_engine_');
    nodes.clear();
    a = await startNode('a');
    b = await startNode('b');
  });

  tearDown(() async {
    for (final n in nodes) {
      await n.engine.dispose(force: true);
      await n.log.close();
    }
    sandbox.deleteSync(recursive: true);
  });

  group('multi-file session A -> B (FR-07, FR-08, FR-09, FR-10, FR-11)', () {
    test('six files incl. 0 B, 1 B, chunkSize, chunkSize+1 and ~9 MiB arrive '
        'byte-identical with matching SHA-256 and original mtime', () async {
      final files = <File>[
        source('empty.bin', 0, seed: 1, mtimeSecs: 1),
        source('one.bin', 1, seed: 2, mtimeSecs: 2),
        source('notes.txt', 1234, seed: 3, mtimeSecs: 3),
        source('exact-chunk.bin', kChunkSize, seed: 4, mtimeSecs: 4),
        source('chunk-plus-1.bin', kChunkSize + 1, seed: 5, mtimeSecs: 5),
        source('nine-mib.bin', 9 * 1024 * 1024 + 12345, seed: 6, mtimeSecs: 6),
      ];
      final total = files.fold<int>(0, (s, f) => s + f.lengthSync());

      final res = await sendFiles(
        a,
        b,
        // Shuffled on purpose: the manifest orders smallest first.
        [files[4], files[0], files[5], files[2], files[1], files[3]],
      );

      expect(res.status, TransferStatus.completed, reason: '$res');
      expect(res.failureReason, isNull);
      expect(res.isSuccess, isTrue);
      expect(res.bytesSent, total);

      for (final f in files) {
        await expectCopy(f, File(p.join(b.rx.path, p.basename(f.path))));
      }
      expect(
        b.rx.listSync().map((e) => p.basename(e.path)).toSet(),
        files.map((f) => p.basename(f.path)).toSet(),
        reason: 'exactly the sent files, nothing else',
      );
      expect(partialLeftovers(b.rx), isEmpty);

      // FR-11: sender side.
      final created = a.log.of<SessionCreated>();
      expect(created, hasLength(1));
      expect(created.single.outgoing, isTrue);
      expect(created.single.sessionId, res.sessionId);
      expect(a.log.finished, hasLength(1));
      expect(a.log.finished.single.success, isTrue);
      expect(a.log.finished.single.sessionId, res.sessionId);
      final progress = a.log.of<FileProgress>();
      expect(progress, isNotEmpty);
      expect(progress.every((e) => e.sessionId == res.sessionId), isTrue);
      final lastPerFile = <String, FileProgress>{};
      for (final e in progress) {
        lastPerFile[e.fileId] = e;
      }
      for (final e in lastPerFile.values) {
        expect(e.bytesDone, e.bytesTotal, reason: 'file ${e.fileId} done');
      }

      // FR-11: receiver side.
      final incoming = b.log.of<SessionCreated>();
      expect(incoming, hasLength(1));
      expect(incoming.single.outgoing, isFalse);
      expect(incoming.single.sessionId, res.sessionId);
      final saved = b.log.of<FileSaved>();
      expect(saved, hasLength(files.length), reason: 'one FileSaved per file');
      expect(saved.every((e) => e.sessionId == res.sessionId), isTrue);
      expect(
        saved.map((e) => p.basename(e.path)).toSet(),
        files.map((f) => p.basename(f.path)).toSet(),
      );
      for (final e in saved) {
        expect(p.isWithin(b.rx.path, e.path), isTrue);
        expect(File(e.path).existsSync(), isTrue);
      }
      // Smallest first (FR-07): FileSaved follows the manifest order.
      final sizes = [for (final e in saved) File(e.path).lengthSync()];
      expect(sizes, [...sizes]..sort(), reason: 'smallest first');
      expect(b.log.finished, hasLength(1));
      expect(b.log.finished.single.success, isTrue);
      expect(b.log.finished.single.sessionId, res.sessionId);

      // The sender's engine received nothing.
      expect(a.rx.listSync(), isEmpty);
      expect(a.log.of<FileSaved>(), isEmpty);
    });

    test(
      'a single chunk in flight (chunkConcurrency 1) is identical too',
      () async {
        final f = source(
          'multi.bin',
          2 * kChunkSize + 77,
          seed: 11,
          mtimeSecs: 7,
        );
        final res = await sendFiles(a, b, [f], chunkConcurrency: 1);
        expect(res.isSuccess, isTrue, reason: '$res');
        await expectCopy(f, File(p.join(b.rx.path, 'multi.bin')));
      },
    );

    test('sending the same file twice keeps both: name (1).ext', () async {
      final f = source('photo.jpg', 4096, seed: 12, mtimeSecs: 8);
      for (var i = 0; i < 2; i++) {
        final res = await sendFiles(a, b, [f]);
        expect(res.isSuccess, isTrue, reason: '$res');
      }
      await expectCopy(f, File(p.join(b.rx.path, 'photo.jpg')));
      await expectCopy(f, File(p.join(b.rx.path, 'photo (1).jpg')));
      expect(partialLeftovers(b.rx), isEmpty);
    });
  });

  group('both directions (FR-17)', () {
    test('A sends to B, then B sends to A', () async {
      final fromA = [
        source('from-a-small.txt', 777, seed: 21, mtimeSecs: 11),
        source('from-a-big.bin', kChunkSize + 4097, seed: 22, mtimeSecs: 12),
      ];
      final fromB = [
        source('from-b-empty.txt', 0, seed: 23, mtimeSecs: 13),
        source('from-b-big.bin', 2 * kChunkSize + 1, seed: 24, mtimeSecs: 14),
      ];

      final ab = await sendFiles(a, b, fromA);
      expect(ab.isSuccess, isTrue, reason: '$ab');
      final ba = await sendFiles(b, a, fromB);
      expect(ba.isSuccess, isTrue, reason: '$ba');
      expect(ab.sessionId, isNot(ba.sessionId));

      for (final f in fromA) {
        await expectCopy(f, File(p.join(b.rx.path, p.basename(f.path))));
      }
      for (final f in fromB) {
        await expectCopy(f, File(p.join(a.rx.path, p.basename(f.path))));
      }
      expect(b.rx.listSync(), hasLength(fromA.length));
      expect(a.rx.listSync(), hasLength(fromB.length));

      // Each engine saw one outgoing and one incoming session, both successful.
      for (final n in [a, b]) {
        final sessions = n.log.of<SessionCreated>();
        expect(sessions.where((e) => e.outgoing), hasLength(1), reason: n.name);
        expect(
          sessions.where((e) => !e.outgoing),
          hasLength(1),
          reason: n.name,
        );
        expect(n.log.finished, hasLength(2), reason: n.name);
        expect(n.log.finished.every((e) => e.success), isTrue, reason: n.name);
      }
      expect(a.log.of<FileSaved>(), hasLength(fromB.length));
      expect(b.log.of<FileSaved>(), hasLength(fromA.length));
    });

    test('A and B send to each other at the same time', () async {
      final fromA = [
        source('a-1.bin', 3 * kChunkSize + 5, seed: 31, mtimeSecs: 21),
        source('a-2.bin', 100, seed: 32, mtimeSecs: 22),
      ];
      final fromB = [
        source('b-1.bin', 3 * kChunkSize + 9, seed: 33, mtimeSecs: 23),
        source('b-2.bin', 0, seed: 34, mtimeSecs: 24),
      ];

      final results = await Future.wait([
        sendFiles(a, b, fromA),
        sendFiles(b, a, fromB),
      ]);
      expect(results[0].isSuccess, isTrue, reason: '${results[0]}');
      expect(results[1].isSuccess, isTrue, reason: '${results[1]}');

      for (final f in fromA) {
        await expectCopy(f, File(p.join(b.rx.path, p.basename(f.path))));
      }
      for (final f in fromB) {
        await expectCopy(f, File(p.join(a.rx.path, p.basename(f.path))));
      }
      for (final n in [a, b]) {
        expect(n.log.finished, hasLength(2), reason: n.name);
        expect(n.log.finished.every((e) => e.success), isTrue, reason: n.name);
        expect(partialLeftovers(n.rx), isEmpty, reason: n.name);
      }
    });
  });

  group('engine basics', () {
    test(
      'FR-01: a busy preferred port falls back to a higher free port',
      () async {
        // An ephemeral port that leaves room below 53327 to fall back to.
        var preferred = 0;
        for (var i = 0; i < 100 && preferred == 0; i++) {
          final probe = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          final candidate = probe.port;
          await probe.close();
          if (candidate >= 20000 && candidate < 53000) preferred = candidate;
        }
        expect(preferred, isNonZero, reason: 'no suitable free port found');

        final first = await startNode('first', preferredPort: preferred);
        final second = await startNode('second', preferredPort: first.port);
        expect(first.port, greaterThanOrEqualTo(preferred));
        expect(second.port, greaterThan(first.port));
        expect(second.port, lessThanOrEqualTo(kPortFallbackMax));
        expect(first.engine.isRunning && second.engine.isRunning, isTrue);

        // Both listeners are alive and distinct.
        final i1 = await a.engine.peerInfo(loopback, first.port);
        final i2 = await a.engine.peerInfo(loopback, second.port);
        expect(i1.deviceId, 'device-first');
        expect(i2.deviceId, 'device-second');
      },
    );

    test('peerInfo returns the remote DeviceInfo', () async {
      final info = await a.engine.peerInfo(loopback, b.port);
      expect(info.deviceId, 'device-b');
      expect(info.alias, 'Engine-b');
      expect(info.platform, 'linux');
      expect(info.version, kProtocolVersion);
      // The reverse direction identifies A.
      expect((await b.engine.peerInfo(loopback, a.port)).alias, 'Engine-a');
    });

    test('peerInfo on a closed port is a transport error', () async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final closed = probe.port;
      await probe.close();
      await expectLater(
        a.engine.peerInfo(loopback, closed),
        throwsA(isA<SocketException>()),
      );
    });

    test(
      'lifecycle: port before start / double start throw; stop frees the port',
      () async {
        final fresh = LibreShareEngine(
          self: const DeviceInfo(deviceId: 'x', alias: 'x', platform: 'linux'),
          downloadDir: Directory(p.join(sandbox.path, 'rx-fresh')),
          preferredPort: 0,
          bindAddress: InternetAddress.loopbackIPv4,
        );
        expect(() => fresh.port, throwsStateError);
        expect(() => fresh.receiver, throwsStateError);
        expect(fresh.isRunning, isFalse);
        await fresh.start();
        expect(fresh.isRunning, isTrue);
        await expectLater(fresh.start(), throwsStateError);
        final port = fresh.port;
        await fresh.dispose();
        expect(fresh.isRunning, isFalse);
        await expectLater(
          a.engine.peerInfo(loopback, port),
          throwsA(isA<SocketException>()),
        );
      },
    );
  });

  group(
    'receiver shuts down inside its SessionFinished listener (regression)',
    () {
      // SessionFinished fires inside the POST /finish handler, BEFORE the response
      // is flushed. A receiver (UI or CLI --once) that stops its engine right
      // there used to cut the connection and the sender saw NO_CONNECTION even
      // though every file was verified. stop() is now graceful (5 s grace).
      for (final variant in ['dispose', 'stop', 'stop(force: false)']) {
        test(
          'sender still completes when the receiver calls $variant',
          () async {
            final files = [
              source('r-empty.txt', 0, seed: 41, mtimeSecs: 31),
              source('r-big.bin', kChunkSize + 4096, seed: 42, mtimeSecs: 32),
            ];
            final rx = await startNode('rx-$variant');
            Future<void>? shutdown;
            final stopwatch = Stopwatch();
            final sub = rx.engine.events.listen((e) {
              if (e is SessionFinished && shutdown == null) {
                stopwatch.start();
                shutdown = switch (variant) {
                  'dispose' => rx.engine.dispose(),
                  'stop' => rx.engine.stop(),
                  _ => rx.engine.stop(force: false),
                };
              }
            });

            final res = await sendFiles(a, rx, files);
            expect(res.status, TransferStatus.completed, reason: '$res');
            expect(res.failureReason, isNull);
            expect(a.log.finished.single.success, isTrue);

            await untilTrue(() => shutdown != null);
            await shutdown;
            stopwatch.stop();
            expect(
              stopwatch.elapsed,
              lessThan(const Duration(seconds: 4)),
              reason: 'graceful stop must not run into its 5 s grace',
            );
            expect(rx.engine.isRunning, isFalse);
            await sub.cancel();

            for (final f in files) {
              await expectCopy(f, File(p.join(rx.rx.path, p.basename(f.path))));
            }
            // The receiver did not stop before it had recorded success.
            expect(rx.log.finished.single.success, isTrue);
            await expectLater(
              a.engine.peerInfo(loopback, rx.port),
              throwsA(isA<SocketException>()),
              reason: 'the listener is really gone',
            );
          },
        );
      }
    },
  );

  group('consent (FR-06)', () {
    /// Calls [decide] 150 ms after the receiver reports an incoming session.
    void decideLater(
      Node rx,
      Future<void> Function(FileReceiver receiver, String sessionId) decide,
    ) {
      rx.engine.events.listen((e) {
        if (e is SessionCreated && !e.outgoing) {
          unawaited(
            Future<void>.delayed(
              const Duration(milliseconds: 150),
              () => decide(rx.engine.receiver, e.sessionId),
            ),
          );
        }
      });
    }

    test('autoAccept false + receiver.accept -> COMPLETED', () async {
      final rx = await startNode('manual', autoAccept: false);
      decideLater(rx, (r, sid) => r.accept(sid));
      final f = source('consent.bin', kChunkSize + 3, seed: 51, mtimeSecs: 41);
      final res = await sendFiles(a, rx, [f]);
      expect(res.isSuccess, isTrue, reason: '$res');
      await expectCopy(f, File(p.join(rx.rx.path, 'consent.bin')));
    });

    test(
      'autoAccept false + receiver.reject -> sender FAILED(REJECTED)',
      () async {
        final rx = await startNode('rejecting', autoAccept: false);
        decideLater(rx, (r, sid) => r.reject(sid));
        final f = source('nope.bin', 5000, seed: 52);
        final sw = Stopwatch()..start();
        final res = await sendFiles(a, rx, [f]);

        expect(res.status, TransferStatus.failed, reason: '$res');
        expect(res.failureReason, FailureReason.rejected);
        expect(res.bytesSent, 0);
        expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
        expect(a.log.finished.single.success, isFalse);
        expect(a.log.finished.single.reason, FailureReason.rejected.wire);
        await untilTrue(() => rx.log.finished.isNotEmpty);
        expect(rx.log.finished.single.success, isFalse);
        expect(rx.log.finished.single.reason, FailureReason.rejected.wire);
        expect(rx.log.of<FileSaved>(), isEmpty);
        expect(rx.rx.listSync(), isEmpty, reason: 'nothing written');
      },
    );

    test('autoAccept false + silence past the permission timeout -> FAILED(TIMEOUT)', () async {
      final rx = await startNode(
        'silent',
        autoAccept: false,
        permissionTimeout: const Duration(milliseconds: 400),
      );
      final f = source('late.bin', 5000, seed: 53);
      final sw = Stopwatch()..start();
      final res = await sendFiles(a, rx, [f]);

      expect(res.status, TransferStatus.failed, reason: '$res');
      expect(res.failureReason, FailureReason.timeout);
      expect(sw.elapsed, lessThan(const Duration(seconds: 8)));
      expect(a.log.finished.single.reason, FailureReason.timeout.wire);
      expect(rx.log.finished.single.success, isFalse);
      expect(rx.log.finished.single.reason, FailureReason.timeout.wire);
      expect(rx.rx.listSync(), isEmpty);
    });

    test('a sender that stops waiting (acceptTimeout) fails with TIMEOUT and cancels the session', () async {
      final rx = await startNode('slow-human', autoAccept: false);
      final f = source('impatient.bin', 5000, seed: 54);
      final res = await sendFiles(a, rx, [
        f,
      ], acceptTimeout: const Duration(seconds: 1));
      expect(res.status, TransferStatus.failed, reason: '$res');
      expect(res.failureReason, FailureReason.timeout);
      await untilTrue(() => rx.log.finished.isNotEmpty);
      expect(rx.log.finished.single.success, isFalse);
      expect(rx.log.finished.single.reason, FailureReason.cancelled.wire);
      expect(rx.rx.listSync(), isEmpty);
    });
  });

  group('path traversal (FR-16)', () {
    /// Every regular file below the sandbox that is not a test fixture.
    List<String> filesOutside(Directory allowed) => [
      for (final e in sandbox.listSync(recursive: true, followLinks: false))
        if (e is File &&
            !p.isWithin(allowed.path, e.path) &&
            !p.basename(p.dirname(e.path)).startsWith('src-'))
          e.path,
    ];

    Future<SendResult> sendRewritten(
      Node from,
      Node to,
      List<File> files,
      FileItem Function(int, FileItem) rewrite,
    ) async {
      final api = ApiClient(host: loopback, port: to.port);
      try {
        return await FileSender(
          client: RewritingClient(api, rewrite),
          self: from.engine.self,
        ).send(files);
      } finally {
        api.close();
      }
    }

    test(
      'fileName ../../evil.txt (and variants) lands inside the download dir',
      () async {
        final files = [
          source('t1.bin', 11, seed: 61),
          source('t2.bin', 22, seed: 62),
          source('t3.bin', 33, seed: 63),
          source('t4.bin', 44, seed: 64),
        ];
        const hostile = [
          '../../evil.txt',
          r'..\..\evil2.txt',
          '/tmp/ls-evil3.txt',
          '../../../../../../../../tmp/ls-evil4.txt',
        ];
        // Manifest order is smallest first, i.e. the order of [files].
        final res = await sendRewritten(
          a,
          b,
          files,
          (i, item) => withNames(item, fileName: hostile[i]),
        );
        expect(res.isSuccess, isTrue, reason: '$res');

        final saved = b.log.of<FileSaved>();
        expect(saved, hasLength(files.length));
        for (var i = 0; i < files.length; i++) {
          expect(
            p.isWithin(b.rx.path, saved[i].path),
            isTrue,
            reason: '${saved[i].path} escaped ${b.rx.path}',
          );
          await expectCopy(files[i], File(saved[i].path), checkMtime: false);
        }
        expect(
          b.rx.listSync().map((e) => p.basename(e.path)),
          containsAll([
            'evil.txt',
            'evil2.txt',
            'ls-evil3.txt',
            'ls-evil4.txt',
          ]),
        );
        expect(filesOutside(b.rx), isEmpty);
        expect(File('/tmp/ls-evil3.txt').existsSync(), isFalse);
        expect(File('/tmp/ls-evil4.txt').existsSync(), isFalse);
        expect(partialLeftovers(b.rx), isEmpty);
      },
    );

    test(
      'relativePath with a .. segment is refused and nothing is written',
      () async {
        for (final bad in [
          '../../evil.txt',
          'photos/../../evil.txt',
          r'..\x',
        ]) {
          final f = source('rel-${bad.hashCode.abs()}.bin', 10, seed: 65);
          final res = await sendRewritten(a, b, [
            f,
          ], (i, item) => withNames(item, relativePath: bad));
          expect(res.status, TransferStatus.failed, reason: '$bad: $res');
          expect(res.failureReason, FailureReason.protocolError, reason: bad);
        }
        expect(b.rx.listSync(), isEmpty);
        expect(filesOutside(b.rx), isEmpty);
        expect(b.log.of<FileSaved>(), isEmpty);
      },
    );

    test(
      'an honest relativePath creates its folders inside the download dir',
      () async {
        final f = source('deep.bin', 2000, seed: 66);
        final res = await sendRewritten(a, b, [
          f,
        ], (i, item) => withNames(item, relativePath: 'photos/2024/trip'));
        expect(res.isSuccess, isTrue, reason: '$res');
        final dst = File(
          p.join(b.rx.path, 'photos', '2024', 'trip', 'deep.bin'),
        );
        await expectCopy(f, dst, checkMtime: false);
        expect(filesOutside(b.rx), isEmpty);
      },
    );
  });
}
