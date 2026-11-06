import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:libreshare_core/src/client/peer_client.dart';
import 'package:libreshare_core/src/model/device.dart';
import 'package:libreshare_core/src/model/events.dart';
import 'package:libreshare_core/src/model/file_item.dart';
import 'package:libreshare_core/src/model/ls_exception.dart';
import 'package:libreshare_core/src/model/session_models.dart';
import 'package:libreshare_core/src/model/transfer_status.dart';
import 'package:libreshare_core/src/transfer/chunker.dart';
import 'package:libreshare_core/src/transfer/file_sender.dart';
import 'package:test/test.dart';

const _self = DeviceInfo(
  deviceId: 'dev-self',
  alias: 'Sender',
  platform: 'linux',
);
const _zero = [Duration.zero, Duration.zero, Duration.zero];

String _sha(List<int> b) => crypto.sha256.convert(b).toString();

/// In-memory stand-in for the receiver side of LSP/1.
class FakePeer implements PeerClient {
  // ---- behaviour knobs ----
  /// Number of waitSession calls answered PENDING before accepting.
  int pendingPolls = 0;
  FailureReason? rejectWith;
  bool neverAccept = false;
  bool hangOnWait = false;
  Duration pollDelay = Duration.zero;
  bool createAccepted = false;
  Duration putDelay = Duration.zero;
  Set<String>? acceptOnly;
  Object? createError;

  /// When set, createSession records the request (the receiver has created the
  /// session) and then waits for this gate before replying: the window in which
  /// the sender does not know the session id yet.
  Completer<void>? createGate;

  /// How long /cancel takes to be answered.
  Duration cancelDelay = Duration.zero;
  final Map<String, List<Object>> putFailures = {}; // 'fid/idx' -> errors
  final List<Object> completeErrors = [];

  // ---- observations ----
  SessionRequest? request;
  final List<String> calls = [];
  final List<int> waitSecondsSeen = [];
  final Map<String, Map<int, List<int>>> received = {};
  final Map<String, Map<int, String>> headerHashes = {};
  final Map<String, int> putAttempts = {};
  final List<(String, int)> putOrder = [];
  final List<String> completeOrder = [];
  final Map<String, String?> completeSha = {};
  final Map<String, int> stateCalls = {};
  int inFlight = 0;
  int maxInFlight = 0;
  int cancelCalls = 0;
  int cancelsAnswered = 0;
  final List<String> cancelledSessions = [];

  /// Completes when createSession has been entered (request recorded).
  final Completer<void> createEntered = Completer<void>();
  int finishCalls = 0;
  void Function(String fileId, int index)? onPutStarted;

  static const sessionId = 'sess-1';
  int _waitCalls = 0;

  void preload(String fid, int index, List<int> bytes) =>
      (received[fid] ??= {})[index] = bytes;

  Map<String, AcceptedFile> _accepted() => {
    for (final f in request!.files)
      if (acceptOnly == null || acceptOnly!.contains(f.fileId))
        f.fileId: AcceptedFile(token: 'tok-${f.fileId}'),
  };

  FileItem _item(String fid) =>
      request!.files.firstWhere((f) => f.fileId == fid);

  @override
  Future<SessionStatus> createSession(SessionRequest r) async {
    calls.add('createSession');
    if (!createEntered.isCompleted) createEntered.complete();
    final gate = createGate;
    if (gate != null) await gate.future;
    if (createError != null) throw createError!;
    request = r;
    return SessionStatus(
      sessionId: sessionId,
      status: createAccepted
          ? TransferStatus.inProgress
          : TransferStatus.pending,
      acceptedFiles: createAccepted ? _accepted() : const {},
    );
  }

  @override
  Future<SessionStatus> waitSession(String sid, {int waitSeconds = 25}) async {
    calls.add('waitSession');
    waitSecondsSeen.add(waitSeconds);
    expect(sid, sessionId);
    if (hangOnWait) await Completer<void>().future;
    if (pollDelay > Duration.zero) await Future<void>.delayed(pollDelay);
    if (rejectWith != null) {
      return SessionStatus(
        sessionId: sid,
        status: TransferStatus.failed,
        failureReason: rejectWith,
      );
    }
    if (neverAccept || _waitCalls++ < pendingPolls) {
      return SessionStatus(sessionId: sid, status: TransferStatus.pending);
    }
    return SessionStatus(
      sessionId: sid,
      status: TransferStatus.inProgress,
      acceptedFiles: _accepted(),
    );
  }

  @override
  Future<FileState> fileState(
    String sid,
    String fid, {
    required String token,
  }) async {
    calls.add('fileState');
    expect(token, 'tok-$fid');
    stateCalls[fid] = (stateCalls[fid] ?? 0) + 1;
    return FileState(
      receivedRanges: compactRanges((received[fid] ?? {}).keys),
      chunkCount: _item(fid).chunkCount,
    );
  }

  @override
  Future<void> putChunk(
    String sid,
    String fid,
    int index,
    Stream<List<int>> body, {
    required int length,
    required String chunkSha256,
    required String token,
  }) async {
    calls.add('putChunk');
    final key = '$fid/$index';
    putAttempts[key] = (putAttempts[key] ?? 0) + 1;
    putOrder.add((fid, index));
    onPutStarted?.call(fid, index);
    inFlight++;
    maxInFlight = math.max(maxInFlight, inFlight);
    try {
      final bytes = BytesBuilder(copy: false);
      await for (final part in body) {
        bytes.add(part);
      }
      if (putDelay > Duration.zero) await Future<void>.delayed(putDelay);
      final queued = putFailures[key];
      if (queued != null && queued.isNotEmpty) throw queued.removeAt(0);
      if (token != 'tok-$fid') throw LsException(LsErrorCode.tokenInvalid);
      final data = bytes.takeBytes();
      if (data.length != length) {
        throw LsException(
          LsErrorCode.badRequest,
          'length ${data.length} != $length',
        );
      }
      if (_sha(data) != chunkSha256) {
        throw LsException(LsErrorCode.chunkHashMismatch);
      }
      (headerHashes[fid] ??= {})[index] = chunkSha256;
      (received[fid] ??= {})[index] = data;
    } finally {
      inFlight--;
    }
  }

  @override
  Future<FileVerification> completeFile(
    String sid,
    String fid, {
    required String token,
    String? sha256,
  }) async {
    calls.add('completeFile');
    completeOrder.add(fid);
    completeSha[fid] = sha256;
    if (completeErrors.isNotEmpty) throw completeErrors.removeAt(0);
    final item = _item(fid);
    final chunks = received[fid] ?? {};
    final all = BytesBuilder();
    for (var i = 0; i < item.chunkCount; i++) {
      final c = chunks[i];
      if (c == null) throw LsException(LsErrorCode.missingChunks);
      all.add(c);
    }
    final digest = _sha(all.toBytes());
    final expected = item.sha256 ?? sha256;
    if (expected != digest) throw LsException(LsErrorCode.verifyFailed);
    return FileVerification(verified: true, sha256: digest);
  }

  @override
  Future<SessionStatus> finish(String sid) async {
    calls.add('finish');
    finishCalls++;
    return SessionStatus(sessionId: sid, status: TransferStatus.completed);
  }

  @override
  Future<void> cancel(String sid) async {
    calls.add('cancel');
    cancelCalls++;
    cancelledSessions.add(sid);
    if (cancelDelay > Duration.zero) await Future<void>.delayed(cancelDelay);
    cancelsAnswered++;
  }

  @override
  Future<DeviceInfo> info() => throw UnimplementedError();
  @override
  Future<DeviceInfo> register(DeviceInfo self) => throw UnimplementedError();
  @override
  void close() {}
}

void main() {
  late Directory tmp;
  late FakePeer peer;
  late List<LsEvent> events;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ls_sender_');
    peer = FakePeer();
    events = [];
  });
  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Uint8List content(String name, int size) {
    final seed = name.codeUnits.fold<int>(7, (a, b) => (a * 31 + b) & 0xFFFF);
    final b = Uint8List(size);
    for (var i = 0; i < size; i++) {
      b[i] = (i * 17 + seed + (i >> 7)) & 0xFF;
    }
    return b;
  }

  File makeFile(String name, int size) =>
      File('${tmp.path}/$name')..writeAsBytesSync(content(name, size));

  FileSender newSender({
    int chunkSize = 1000,
    int chunkConcurrency = 3,
    int fileConcurrency = 1,
    List<Duration> retryDelays = _zero,
    Duration acceptTimeout = const Duration(seconds: 120),
    String? pin,
    int? hashLimitBytes,
    void Function(LsEvent)? onEvent,
  }) => FileSender(
    client: peer,
    self: _self,
    chunker: Chunker(chunkSize),
    chunkConcurrency: chunkConcurrency,
    fileConcurrency: fileConcurrency,
    retryDelays: retryDelays,
    acceptTimeout: acceptTimeout,
    pin: pin,
    hashLimitBytes: hashLimitBytes ?? 2 * 1024 * 1024 * 1024,
    onEvent: onEvent ?? events.add,
  );

  /// Resolves once the fake peer has seen a call named [name].
  Future<void> untilCalled(String name) async {
    final sw = Stopwatch()..start();
    while (!peer.calls.contains(name)) {
      if (sw.elapsed > const Duration(seconds: 5)) fail('$name never called');
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  String fileIdOf(String name) =>
      peer.request!.files.firstWhere((f) => f.fileName == name).fileId;

  Uint8List reassembled(String name) {
    final fid = fileIdOf(name);
    final item = peer.request!.files.firstWhere((f) => f.fileId == fid);
    final out = BytesBuilder();
    for (var i = 0; i < item.chunkCount; i++) {
      out.add(peer.received[fid]![i]!);
    }
    return out.toBytes();
  }

  group('happy path', () {
    test('multiple files incl. an empty one arrive byte-identical', () async {
      final big = makeFile('big.bin', 4500); // 5 chunks (last = 500)
      final tiny = makeFile('tiny.bin', 3); // 1 chunk
      final empty = makeFile('empty.bin', 0); // 0 chunks
      final exact = makeFile('exact.bin', 2000); // 2 chunks exactly
      final sender = newSender(pin: '246810');

      final result = await sender.send([big, tiny, empty, exact]);

      expect(result.status, TransferStatus.completed);
      expect(result.failureReason, isNull);
      expect(result.sessionId, FakePeer.sessionId);
      expect(result.bytesSent, 4500 + 3 + 0 + 2000);
      expect(result.elapsed, greaterThan(Duration.zero));

      // Request content.
      final req = peer.request!;
      expect(req.pin, '246810');
      expect(req.sender.deviceId, 'dev-self');
      expect(req.chunkSize, 1000);
      expect(req.totalSize, 6503);
      expect(req.files.map((f) => f.fileName), [
        'empty.bin',
        'tiny.bin',
        'exact.bin',
        'big.bin',
      ]);
      expect(req.files.map((f) => f.chunkCount), [0, 1, 2, 5]);

      // Bytes identical.
      expect(reassembled('big.bin'), content('big.bin', 4500));
      expect(reassembled('tiny.bin'), content('tiny.bin', 3));
      expect(reassembled('exact.bin'), content('exact.bin', 2000));
      expect(reassembled('empty.bin'), isEmpty);

      // The 0-byte file still gets completeFile; smallest first.
      expect(peer.completeOrder, ['f1', 'f2', 'f3', 'f4']);
      expect(peer.completeSha.values, everyElement(isNull)); // manifest had sha
      expect(peer.putOrder.where((p) => p.$1 == 'f1'), isEmpty);

      // Protocol order: create, wait, ..., finish last.
      expect(peer.calls.first, 'createSession');
      expect(peer.calls[1], 'waitSession');
      expect(peer.calls.last, 'finish');
      expect(peer.calls, isNot(contains('cancel')));
    });

    test(
      'emits SessionCreated, monotonic FileProgress, SessionFinished',
      () async {
        final a = makeFile('a.bin', 2500);
        final b = makeFile('b.bin', 0);
        await newSender().send([a, b]);

        expect(events.first, isA<SessionCreated>());
        final created = events.first as SessionCreated;
        expect(created.sessionId, FakePeer.sessionId);
        expect(created.outgoing, isTrue);

        expect(events.last, isA<SessionFinished>());
        final fin = events.last as SessionFinished;
        expect(fin.success, isTrue);
        expect(fin.reason, isNull);

        final progress = events.whereType<FileProgress>().toList();
        for (final fid in ['f1', 'f2']) {
          final mine = progress.where((p) => p.fileId == fid).toList();
          expect(mine, isNotEmpty, reason: 'progress for $fid');
          var last = -1;
          for (final p in mine) {
            expect(p.sessionId, FakePeer.sessionId);
            expect(p.bytesDone, greaterThanOrEqualTo(last));
            expect(p.bytesDone, lessThanOrEqualTo(p.bytesTotal));
            last = p.bytesDone;
          }
          expect(mine.last.bytesDone, mine.last.bytesTotal);
        }
        expect(progress.where((p) => p.fileId == 'f2').last.bytesTotal, 2500);
      },
    );

    test('only empty files: no chunks, completeFile still called', () async {
      final z = makeFile('z.bin', 0);
      final result = await newSender().send([z]);
      expect(result.status, TransferStatus.completed);
      expect(result.bytesSent, 0);
      expect(peer.calls, isNot(contains('putChunk')));
      expect(peer.completeOrder, ['f1']);
    });

    test('trusted auto-accept: no long-poll needed', () async {
      peer.createAccepted = true;
      final result = await newSender().send([makeFile('a.bin', 1500)]);
      expect(result.status, TransferStatus.completed);
      expect(peer.calls, isNot(contains('waitSession')));
    });

    test('long-polls with wait=25 until accepted', () async {
      peer.pendingPolls = 2;
      final result = await newSender().send([makeFile('a.bin', 10)]);
      expect(result.status, TransferStatus.completed);
      expect(peer.waitSecondsSeen, [25, 25, 25]);
    });

    test('files the receiver did not accept are skipped', () async {
      peer.acceptOnly = {'f2'};
      final result = await newSender().send([
        makeFile('a.bin', 100),
        makeFile('b.bin', 2000),
      ]);
      expect(result.status, TransferStatus.completed);
      expect(result.bytesSent, 2000);
      expect(peer.completeOrder, ['f2']);
    });

    test('a throwing onEvent callback does not break the transfer', () async {
      final result = await newSender(
        onEvent: (_) => throw StateError('listener bug'),
      ).send([makeFile('a.bin', 2500)]);
      expect(result.status, TransferStatus.completed);
    });

    test('empty file list is a programming error', () async {
      await expectLater(newSender().send(const []), throwsArgumentError);
      expect(peer.calls, isEmpty);
    });

    test('missing file fails before any session is created', () async {
      await expectLater(
        newSender().send([File('${tmp.path}/nope.bin')]),
        throwsA(isA<FileSystemException>()),
      );
      expect(peer.calls, isEmpty);
    });
  });

  group('chunk integrity header', () {
    test('every chunk is sent with the SHA-256 of exactly its bytes', () async {
      final data = content('h.bin', 3456);
      final f = makeFile('h.bin', 3456);
      await newSender().send([f]);
      final hashes = peer.headerHashes['f1']!;
      expect(hashes.keys.toList()..sort(), [0, 1, 2, 3]);
      for (final entry in hashes.entries) {
        final start = entry.key * 1000;
        final end = math.min(start + 1000, data.length);
        expect(entry.value, _sha(data.sublist(start, end)));
        expect(entry.value, matches(RegExp(r'^[0-9a-f]{64}$')));
      }
    });
  });

  group('resume', () {
    test('chunks reported by /state are skipped', () async {
      final data = content('r.bin', 10000); // 10 chunks
      final f = makeFile('r.bin', 10000);
      // Peer already holds 0-3 and 7 (needs the right file id: single file -> f1).
      for (final i in [0, 1, 2, 3, 7]) {
        peer.preload('f1', i, data.sublist(i * 1000, (i + 1) * 1000));
      }
      final result = await newSender().send([f]);

      expect(result.status, TransferStatus.completed);
      final sent = peer.putOrder.map((p) => p.$2).toList()..sort();
      expect(sent, [4, 5, 6, 8, 9]);
      expect(result.bytesSent, 5000);
      expect(peer.stateCalls['f1'], 1);
      expect(reassembled('r.bin'), data);

      final progress = events.whereType<FileProgress>().toList();
      expect(progress.last.bytesDone, 10000);
    });

    test('fully received file only needs completeFile', () async {
      final data = content('r.bin', 2500);
      final f = makeFile('r.bin', 2500);
      for (var i = 0; i < 3; i++) {
        peer.preload(
          'f1',
          i,
          data.sublist(i * 1000, math.min((i + 1) * 1000, 2500)),
        );
      }
      final result = await newSender().send([f]);
      expect(result.status, TransferStatus.completed);
      expect(result.bytesSent, 0);
      expect(peer.calls, isNot(contains('putChunk')));
      expect(peer.completeOrder, ['f1']);
    });

    test('hostile /state ranges are clamped, not expanded', () async {
      final f = makeFile('r.bin', 2500);
      final hostile = _HostileStatePeer(peer);
      final sender = FileSender(
        client: hostile,
        self: _self,
        chunker: const Chunker(1000),
        retryDelays: _zero,
      );
      // Claims chunks [0, 2^62] received: must not hang / OOM; chunk 0..2 treated
      // as received, so completeFile runs (and the fake reports MISSING_CHUNKS,
      // which then fails the session cleanly).
      final result = await sender
          .send([f])
          .timeout(const Duration(seconds: 20));
      expect(result.status, TransferStatus.failed);
      expect(peer.calls, isNot(contains('putChunk')));
    });

    test('MISSING_CHUNKS at complete re-reads /state and retries', () async {
      peer.completeErrors.add(LsException(LsErrorCode.missingChunks));
      final result = await newSender().send([makeFile('a.bin', 2500)]);
      expect(result.status, TransferStatus.completed);
      expect(peer.stateCalls['f1'], 2);
      expect(peer.completeOrder, ['f1', 'f1']);
    });
  });

  group('retries', () {
    test('transient chunk errors are retried, then succeed', () async {
      peer.putFailures['f1/1'] = [
        const SocketException('reset'),
        TimeoutException('slow'),
        LsException(LsErrorCode.chunkHashMismatch),
      ];
      final result = await newSender().send([makeFile('a.bin', 3000)]);
      expect(result.status, TransferStatus.completed);
      expect(peer.putAttempts['f1/1'], 4); // 1 + 3 retries
      expect(peer.putAttempts['f1/0'], 1);
      expect(peer.putAttempts['f1/2'], 1);
      expect(reassembled('a.bin'), content('a.bin', 3000));
      expect(peer.cancelCalls, 0);
    });

    test('retry delays are honoured', () async {
      peer.putFailures['f1/0'] = [
        const SocketException('x'),
        const SocketException('x'),
      ];
      final result = await newSender(
        retryDelays: const [
          Duration(milliseconds: 40),
          Duration(milliseconds: 50),
          Duration(milliseconds: 60),
        ],
      ).send([makeFile('a.bin', 500)]);
      expect(result.status, TransferStatus.completed);
      expect(
        result.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 90)),
      );
    });

    test(
      'exhausted transient retries -> FAILED(NO_CONNECTION) + cancel',
      () async {
        peer.putFailures['f1/0'] = List.generate(
          10,
          (_) => const SocketException('down'),
        );
        final result = await newSender().send([makeFile('a.bin', 500)]);
        expect(result.status, TransferStatus.failed);
        expect(result.failureReason, FailureReason.noConnection);
        expect(peer.putAttempts['f1/0'], 4);
        expect(peer.cancelCalls, 1);
        expect(peer.finishCalls, 0);
        final fin = events.last as SessionFinished;
        expect(fin.success, isFalse);
        expect(fin.reason, 'NO_CONNECTION');
      },
    );

    test(
      'non-retryable error -> FAILED(PROTOCOL_ERROR), single attempt',
      () async {
        peer.putFailures['f1/1'] = [LsException(LsErrorCode.outOfRange)];
        final result = await newSender().send([makeFile('a.bin', 3000)]);
        expect(result.status, TransferStatus.failed);
        expect(result.failureReason, FailureReason.protocolError);
        expect(peer.putAttempts['f1/1'], 1);
        expect(peer.cancelCalls, 1);
        expect(peer.finishCalls, 0);
      },
    );

    test('invalid token -> FAILED(PROTOCOL_ERROR)', () async {
      peer.putFailures['f1/0'] = [LsException(LsErrorCode.tokenInvalid)];
      final result = await newSender().send([makeFile('a.bin', 100)]);
      expect(result.failureReason, FailureReason.protocolError);
      expect(peer.putAttempts['f1/0'], 1);
    });

    test('VERIFY_FAILED from completeFile -> FAILED(VERIFY_FAILED)', () async {
      peer.completeErrors.add(LsException(LsErrorCode.verifyFailed));
      final result = await newSender().send([makeFile('a.bin', 1500)]);
      expect(result.status, TransferStatus.failed);
      expect(result.failureReason, FailureReason.verifyFailed);
      expect(peer.completeOrder, ['f1']); // not retried
      expect(peer.finishCalls, 0);
      expect(peer.cancelCalls, 1);
    });

    test('transient error while completing is retried', () async {
      peer.completeErrors.add(const SocketException('blip'));
      final result = await newSender().send([makeFile('a.bin', 1500)]);
      expect(result.status, TransferStatus.completed);
      expect(peer.completeOrder, ['f1', 'f1']);
    });

    test('a failed chunk stops further chunks being started', () async {
      peer.putFailures['f1/0'] = [LsException(LsErrorCode.outOfRange)];
      final result = await newSender(chunkConcurrency: 1)
          .send([makeFile('a.bin', 10000)]);
      expect(result.status, TransferStatus.failed);
      expect(peer.putOrder, [('f1', 0)]);
    });
  });

  group('permission outcome (FR-06)', () {
    test('reject -> FAILED(REJECTED), nothing uploaded', () async {
      peer.rejectWith = FailureReason.rejected;
      final result = await newSender().send([makeFile('a.bin', 5000)]);
      expect(result.status, TransferStatus.failed);
      expect(result.failureReason, FailureReason.rejected);
      expect(result.sessionId, FakePeer.sessionId);
      expect(result.bytesSent, 0);
      expect(peer.calls, isNot(contains('putChunk')));
      expect(peer.calls, isNot(contains('finish')));
      final fin = events.last as SessionFinished;
      expect(fin.success, isFalse);
      expect(fin.reason, 'REJECTED');
    });

    test('peer-side timeout is passed through', () async {
      peer.rejectWith = FailureReason.timeout;
      final result = await newSender().send([makeFile('a.bin', 10)]);
      expect(result.failureReason, FailureReason.timeout);
    });

    test(
      'no answer within acceptTimeout -> FAILED(TIMEOUT) + cancel',
      () async {
        peer.neverAccept = true;
        peer.pollDelay = const Duration(milliseconds: 40);
        final result = await newSender(
          acceptTimeout: const Duration(milliseconds: 300),
        ).send([makeFile('a.bin', 5000)]);
        expect(result.status, TransferStatus.failed);
        expect(result.failureReason, FailureReason.timeout);
        expect(
          result.elapsed,
          greaterThanOrEqualTo(const Duration(milliseconds: 300)),
        );
        expect(result.elapsed, lessThan(const Duration(seconds: 5)));
        expect(peer.cancelCalls, 1);
        expect(peer.calls, isNot(contains('putChunk')));
      },
    );

    test('a hanging long-poll cannot outlive acceptTimeout', () async {
      peer.hangOnWait = true;
      final result = await newSender(
        acceptTimeout: const Duration(milliseconds: 200),
      ).send([makeFile('a.bin', 100)]);
      expect(result.failureReason, FailureReason.timeout);
      expect(result.elapsed, lessThan(const Duration(seconds: 5)));
      expect(peer.cancelCalls, 1);
    });

    test('createSession refusals map to failure reasons, no retries', () async {
      final expectations = <LsErrorCode, FailureReason>{
        LsErrorCode.pinRequired: FailureReason.rejected,
        LsErrorCode.pinInvalid: FailureReason.rejected,
        LsErrorCode.blocked: FailureReason.rejected,
        LsErrorCode.busy: FailureReason.rejected,
        LsErrorCode.insufficientStorage: FailureReason.diskFull,
        LsErrorCode.internal: FailureReason.protocolError,
      };
      for (final e in expectations.entries) {
        peer = FakePeer()..createError = LsException(e.key);
        final result = await newSender().send([
          makeFile('${e.key.wire}.bin', 10),
        ]);
        expect(result.status, TransferStatus.failed, reason: e.key.wire);
        expect(result.failureReason, e.value, reason: e.key.wire);
        expect(peer.calls, ['createSession'], reason: e.key.wire);
        expect(result.sessionId, isEmpty);
      }
    });

    test('createSession network error -> FAILED(NO_CONNECTION)', () async {
      peer.createError = const SocketException('unreachable');
      final result = await newSender().send([makeFile('a.bin', 10)]);
      expect(result.failureReason, FailureReason.noConnection);
      expect(peer.calls, ['createSession']);
    });
  });

  group('large files (> hashing limit)', () {
    test('sha256 is null in the manifest and supplied at /complete', () async {
      final data = content('big.bin', 3500);
      final f = makeFile('big.bin', 3500);
      final small = makeFile('s.bin', 5);
      final result = await newSender(hashLimitBytes: 100).send([f, small]);
      expect(result.status, TransferStatus.completed);
      final big = peer.request!.files.firstWhere(
        (x) => x.fileName == 'big.bin',
      );
      expect(big.sha256, isNull);
      expect(peer.completeSha[big.fileId], _sha(data));
      final s = peer.request!.files.firstWhere((x) => x.fileName == 's.bin');
      expect(s.sha256, isNotNull);
      expect(peer.completeSha[s.fileId], isNull);
    });
  });

  group('concurrency', () {
    test('never more than chunkConcurrency chunks in flight (3)', () async {
      peer.putDelay = const Duration(milliseconds: 25);
      final result = await newSender(chunkConcurrency: 3).send([
        makeFile('a.bin', 12000), // 12 chunks
      ]);
      expect(result.status, TransferStatus.completed);
      expect(peer.maxInFlight, 3);
      expect(peer.putOrder, hasLength(12));
    });

    test('chunkConcurrency 1 is strictly sequential', () async {
      peer.putDelay = const Duration(milliseconds: 5);
      await newSender(chunkConcurrency: 1).send([makeFile('a.bin', 6000)]);
      expect(peer.maxInFlight, 1);
      expect(peer.putOrder.map((p) => p.$2), [0, 1, 2, 3, 4, 5]);
    });

    test('chunkConcurrency 2 caps at 2', () async {
      peer.putDelay = const Duration(milliseconds: 15);
      await newSender(chunkConcurrency: 2).send([makeFile('a.bin', 9000)]);
      expect(peer.maxInFlight, 2);
    });

    test('files are sequential by default (fileConcurrency 1)', () async {
      peer.putDelay = const Duration(milliseconds: 10);
      await newSender().send([
        makeFile('a.bin', 4000),
        makeFile('b.bin', 5000),
      ]);
      final files = peer.putOrder.map((p) => p.$1).toList();
      expect(files.sublist(0, 4), everyElement('f1'));
      expect(files.sublist(4), everyElement('f2'));
    });

    test('fileConcurrency 2 x chunkConcurrency 2 stays within 4', () async {
      peer.putDelay = const Duration(milliseconds: 25);
      final result = await newSender(
        chunkConcurrency: 2,
        fileConcurrency: 2,
      ).send([makeFile('a.bin', 8000), makeFile('b.bin', 9000)]);
      expect(result.status, TransferStatus.completed);
      expect(peer.maxInFlight, 4);
      expect(reassembled('a.bin'), content('a.bin', 8000));
      expect(reassembled('b.bin'), content('b.bin', 9000));
    });
  });

  group('cancel()', () {
    test('cancels the peer session and ends FAILED(CANCELLED)', () async {
      peer.putDelay = const Duration(milliseconds: 30);
      final sender = newSender(chunkConcurrency: 1);
      peer.onPutStarted = (fid, idx) {
        if (idx == 1) unawaited(sender.cancel());
      };
      final result = await sender.send([makeFile('a.bin', 20000)]);
      expect(result.status, TransferStatus.failed);
      expect(result.failureReason, FailureReason.cancelled);
      expect(peer.cancelCalls, 1);
      expect(peer.cancelledSessions, [FakePeer.sessionId]);
      expect(peer.finishCalls, 0);
      expect(peer.putOrder.length, lessThan(20));
    });

    group('before the createSession reply is read', () {
      // The receiver has created the session (its consent prompt is up) but the
      // reply has not reached the sender, so the sender does not know the id.
      // The cancel must not be lost: the receiver would keep asking its user
      // until its own 120 s timeout.
      Future<void> expectCancelledAfterGate(
        FileSender sender,
        Future<SendResult> sending,
      ) async {
        await peer.createEntered.future;
        await sender.cancel();
        expect(peer.cancelCalls, 0, reason: 'no session id to cancel yet');
        peer.createGate!.complete();
        final result = await sending;

        expect(result.status, TransferStatus.failed);
        expect(result.failureReason, FailureReason.cancelled);
        expect(result.sessionId, FakePeer.sessionId);
        expect(result.bytesSent, 0);
        expect(peer.cancelledSessions, [FakePeer.sessionId]);
        expect(peer.cancelsAnswered, 1, reason: 'send waits for /cancel');
        // No files are transferred, nothing else is asked of the peer.
        expect(peer.calls, ['createSession', 'cancel']);
        expect(peer.received, isEmpty);
        expect(events.whereType<SessionCreated>().single.outgoing, isTrue);
        final fin = events.whereType<SessionFinished>().single;
        expect(fin.success, isFalse);
        expect(fin.reason, FailureReason.cancelled.wire);
        expect(fin.sessionId, FakePeer.sessionId);
        expect(events.last, same(fin));
      }

      test('the peer is told when the reply arrives (pending)', () async {
        peer.createGate = Completer<void>();
        final sender = newSender();
        final sending = sender.send([makeFile('a.bin', 100)]);
        await expectCancelledAfterGate(sender, sending);
      });

      test('the peer is told when the reply says IN_PROGRESS', () async {
        peer.createAccepted = true;
        peer.createGate = Completer<void>();
        final sender = newSender();
        final sending = sender.send([makeFile('a.bin', 100)]);
        await expectCancelledAfterGate(sender, sending);
      });

      test('a double cancel in that window sends one /cancel', () async {
        peer.createGate = Completer<void>();
        final sender = newSender();
        final sending = sender.send([makeFile('a.bin', 100)]);
        await peer.createEntered.future;
        await sender.cancel();
        await sender.cancel();
        peer.createGate!.complete();
        await sender.cancel();
        final result = await sending;
        expect(result.failureReason, FailureReason.cancelled);
        expect(peer.cancelCalls, 1);
      });

      test(
        'createSession failing after the cancel still ends CANCELLED',
        () async {
          peer.createGate = Completer<void>();
          peer.createError = const SocketException('gone');
          final sender = newSender();
          final sending = sender.send([makeFile('a.bin', 100)]);
          await peer.createEntered.future;
          await sender.cancel();
          peer.createGate!.complete();
          final result = await sending;
          expect(result.failureReason, FailureReason.cancelled);
          expect(result.sessionId, isEmpty);
          expect(peer.cancelCalls, 0, reason: 'there is no session');
        },
      );
    });

    group('before anything is sent', () {
      test('cancel() on an idle sender is harmless', () async {
        final sender = newSender();
        await sender.cancel();
        await sender.cancel();
        expect(peer.calls, isEmpty);
        // ... and does not poison the next send.
        final result = await sender.send([makeFile('a.bin', 100)]);
        expect(result.isSuccess, isTrue);
        expect(peer.cancelCalls, 0);
      });

      test(
        'cancel() while the manifest is built: no session is created',
        () async {
          final sender = newSender();
          final sending = sender.send([makeFile('a.bin', 5000)]);
          // send() has registered its run synchronously, before any await.
          await sender.cancel();
          final result = await sending;
          expect(result.status, TransferStatus.failed);
          expect(result.failureReason, FailureReason.cancelled);
          expect(result.sessionId, isEmpty);
          expect(peer.calls, isEmpty);
          final fin = events.whereType<SessionFinished>().single;
          expect(fin.sessionId, isEmpty);
          expect(fin.reason, FailureReason.cancelled.wire);
          expect(events.whereType<SessionCreated>(), isEmpty);
        },
      );
    });

    group('while waiting for the receiver to accept', () {
      test('cancel() tells the peer and nothing is uploaded', () async {
        peer.neverAccept = true;
        final sender = newSender();
        final sending = sender.send([makeFile('a.bin', 100)]);
        await untilCalled('waitSession');
        await sender.cancel();
        final result = await sending;
        expect(result.failureReason, FailureReason.cancelled);
        expect(result.sessionId, FakePeer.sessionId);
        expect(peer.cancelledSessions, [FakePeer.sessionId]);
        expect(peer.calls.where((c) => c == 'putChunk'), isEmpty);
        expect(peer.finishCalls, 0);
      });
    });

    group('after the session was accepted', () {
      test('cancel() mid-transfer still tells the peer once', () async {
        peer.putDelay = const Duration(milliseconds: 20);
        final sender = newSender(chunkConcurrency: 1);
        final sending = sender.send([makeFile('a.bin', 20000)]);
        await untilCalled('putChunk');
        await sender.cancel();
        final result = await sending;
        expect(result.failureReason, FailureReason.cancelled);
        expect(peer.cancelledSessions, [FakePeer.sessionId]);
        expect(peer.finishCalls, 0);
        expect(peer.putOrder.length, lessThan(20));
        expect(events.whereType<SessionFinished>().single.reason, 'CANCELLED');
      });

      test('send() resolves only after /cancel was answered', () async {
        peer.putDelay = const Duration(milliseconds: 20);
        peer.cancelDelay = const Duration(milliseconds: 150);
        final sender = newSender(chunkConcurrency: 1);
        final sending = sender.send([makeFile('a.bin', 20000)]);
        await untilCalled('putChunk');
        unawaited(sender.cancel());
        final result = await sending;
        expect(result.failureReason, FailureReason.cancelled);
        expect(peer.cancelsAnswered, 1);
      });

      test('a double cancel (even concurrent) sends one /cancel', () async {
        peer.putDelay = const Duration(milliseconds: 20);
        final sender = newSender(chunkConcurrency: 1);
        final sending = sender.send([makeFile('a.bin', 20000)]);
        await untilCalled('putChunk');
        await Future.wait([sender.cancel(), sender.cancel()]);
        await sender.cancel();
        final result = await sending;
        await sender.cancel(); // and once more after it ended
        expect(result.failureReason, FailureReason.cancelled);
        expect(peer.cancelCalls, 1);
      });

      test('cancel() after the send completed changes nothing', () async {
        final sender = newSender();
        final result = await sender.send([makeFile('a.bin', 100)]);
        await sender.cancel();
        expect(result.isSuccess, isTrue);
        expect(peer.cancelCalls, 0);
      });

      test(
        'the receiver ending the session is not answered with /cancel',
        () async {
          // Peer-initiated cancel (the receiver's user pressed Cancel): the
          // sender learns it from an error and must not echo a /cancel.
          peer.putFailures['f1/1'] = [LsException(LsErrorCode.cancelled)];
          final sender = newSender(chunkConcurrency: 1);
          final result = await sender.send([makeFile('a.bin', 5000)]);
          expect(result.failureReason, FailureReason.cancelled);
          expect(peer.cancelCalls, 0);
        },
      );
    });
  });
}

/// Wraps a [FakePeer] but answers /state with an absurd range.
class _HostileStatePeer implements PeerClient {
  _HostileStatePeer(this.inner);
  final FakePeer inner;

  @override
  Future<FileState> fileState(
    String sid,
    String fid, {
    required String token,
  }) async {
    final real = await inner.fileState(sid, fid, token: token);
    return FileState(
      receivedRanges: [
        [0, 1 << 62],
        [-5, 2],
        [7],
      ],
      chunkCount: real.chunkCount,
    );
  }

  @override
  Future<SessionStatus> createSession(SessionRequest r) =>
      inner.createSession(r);
  @override
  Future<SessionStatus> waitSession(String sid, {int waitSeconds = 25}) =>
      inner.waitSession(sid, waitSeconds: waitSeconds);
  @override
  Future<void> putChunk(
    String sid,
    String fid,
    int index,
    Stream<List<int>> body, {
    required int length,
    required String chunkSha256,
    required String token,
  }) => inner.putChunk(
    sid,
    fid,
    index,
    body,
    length: length,
    chunkSha256: chunkSha256,
    token: token,
  );
  @override
  Future<FileVerification> completeFile(
    String sid,
    String fid, {
    required String token,
    String? sha256,
  }) => inner.completeFile(sid, fid, token: token, sha256: sha256);
  @override
  Future<SessionStatus> finish(String sid) => inner.finish(sid);
  @override
  Future<void> cancel(String sid) => inner.cancel(sid);
  @override
  Future<DeviceInfo> info() => inner.info();
  @override
  Future<DeviceInfo> register(DeviceInfo self) => inner.register(self);
  @override
  void close() {}
}
