// Inc 4 acceptance: the cheap items of the docs/plans/inc4.md section 4.1
// negative checklist that no existing test covers:
//   * a truncated chunk after a cut is not marked received
//   * a duplicate PUT after a reconnect is idempotent
//   * a /state answer with out-of-range / overlapping / inverted ranges is
//     rejected by the sender (no chunk skipped on the strength of it)
//   * disk full when a transfer is resumed keeps the partial file and bitmap
// Each test name starts with the guard it protects.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:libreshare_core/libreshare_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/test_data.dart';

const int cs = 64 * 1024; // smallest legal chunk size
const rxDev = DeviceInfo(deviceId: 'rx-id', alias: 'Rx', platform: 'linux');
const txDev = DeviceInfo(deviceId: 'tx-id', alias: 'Tx', platform: 'linux');

Uint8List bytes(int n, int seed) {
  final r = Random(seed);
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    b[i] = r.nextInt(256);
  }
  return b;
}

String shaHex(List<int> b) => sha256.convert(b).toString();

FileItem itemOf(Uint8List data, String name) => FileItem(
  fileId: 'f',
  fileName: name,
  size: data.length,
  chunkCount: (data.length + cs - 1) ~/ cs,
  sha256: shaHex(data),
  modified: DateTime.utc(2026, 11, 1, 10),
);

SessionRequest requestFor(FileItem it) => SessionRequest(
  sender: txDev,
  files: [it],
  totalSize: it.size,
  chunkSize: cs,
);

Future<void> put(
  FileReceiver rx,
  String sid,
  String token,
  Uint8List data,
  int index, {
  int? sendOnly, // truncate: only this many bytes of the chunk are sent
}) {
  final start = index * cs;
  final end = min(start + cs, data.length);
  final good = data.sublist(start, end);
  final body = sendOnly == null ? good : good.sublist(0, sendOnly);
  return rx.putChunk(
    sid,
    'f',
    index,
    Stream<List<int>>.fromIterable([body]),
    token: token,
    chunkSha256: shaHex(good),
  );
}

/// A receiver whose /state lies.
class LyingStateReceiver extends FileReceiver {
  LyingStateReceiver({
    required super.self,
    required super.downloadDir,
    required this.lie,
  }) : super(autoAccept: true, freeSpaceProbe: (_) async => null);

  final ChunkRanges lie;
  final List<String> calls = [];

  @override
  Future<FileState> fileState(
    String sessionId,
    String fileId, {
    required String token,
  }) async {
    final real = await super.fileState(sessionId, fileId, token: token);
    return FileState(receivedRanges: lie, chunkCount: real.chunkCount);
  }

  @override
  Future<void> putChunk(
    String sessionId,
    String fileId,
    int index,
    Stream<List<int>> body, {
    required String token,
    String? chunkSha256,
  }) {
    calls.add('put:$index');
    return super.putChunk(
      sessionId,
      fileId,
      index,
      body,
      token: token,
      chunkSha256: chunkSha256,
    );
  }

  @override
  Future<FileVerification> completeFile(
    String sessionId,
    String fileId, {
    required String token,
    String? sha256,
  }) {
    calls.add('complete');
    return super.completeFile(sessionId, fileId, token: token, sha256: sha256);
  }
}

void main() {
  late Directory tmp;
  late Directory dl;
  final receivers = <FileReceiver>[];

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ls_inc4_neg_');
    dl = Directory(p.join(tmp.path, 'dl'))..createSync();
  });
  tearDown(() {
    for (final r in receivers) {
      r.dispose();
    }
    receivers.clear();
    tmp.deleteSync(recursive: true);
  });

  FileReceiver newRx({FreeSpaceProbe? probe}) {
    final r = FileReceiver(
      self: rxDev,
      downloadDir: dl,
      autoAccept: true,
      freeSpaceProbe: probe ?? (_) async => null,
    );
    receivers.add(r);
    return r;
  }

  group('truncated chunk after a cut', () {
    test(
      'guard truncated-not-marked-received: a chunk whose body ends early '
      'is rejected, absent from /state, and sent again in full later',
      () async {
        final data = bytes(3 * cs, 1);
        final rx = newRx();
        final st = await rx.createSession(
          requestFor(itemOf(data, 't.bin')),
          remoteAddress: '127.0.0.1',
        );
        final tok = st.acceptedFiles['f']!.token;
        await put(rx, st.sessionId, tok, data, 0);
        await expectLater(
          put(rx, st.sessionId, tok, data, 1, sendOnly: cs ~/ 3),
          throwsA(isA<LsException>()),
        );
        final state = await rx.fileState(st.sessionId, 'f', token: tok);
        expect(state.receivedRanges, [
          [0, 0],
        ], reason: 'the cut chunk 1 must not be recorded');
        await put(rx, st.sessionId, tok, data, 1);
        await put(rx, st.sessionId, tok, data, 2);
        await rx.completeFile(st.sessionId, 'f', token: tok);
        expect(
          await sha256OfFileHex(File(p.join(dl.path, 't.bin'))),
          shaHex(data),
        );
      },
    );

    test('guard aborted-chunk-keeps-file-hash-valid: a connection that dies '
        'MID-body (stream error) and the same chunk sent again in the same '
        'session still gives a verifiable file (the running whole-file '
        'hash must not keep the aborted bytes)', () async {
      final data = bytes(3 * cs, 6);
      final rx = newRx();
      final st = await rx.createSession(
        requestFor(itemOf(data, 'a.bin')),
        remoteAddress: '127.0.0.1',
      );
      final tok = st.acceptedFiles['f']!.token;
      await put(rx, st.sessionId, tok, data, 0);
      Stream<List<int>> dying() async* {
        yield data.sublist(cs, cs + 1000);
        throw const SocketException('connection reset by peer');
      }

      await expectLater(
        rx.putChunk(
          st.sessionId,
          'f',
          1,
          dying(),
          token: tok,
          chunkSha256: shaHex(data.sublist(cs, 2 * cs)),
        ),
        throwsA(anything),
      );
      await put(rx, st.sessionId, tok, data, 1);
      await put(rx, st.sessionId, tok, data, 2);
      final v = await rx.completeFile(st.sessionId, 'f', token: tok);
      expect(v.verified, isTrue);
      expect(
        await sha256OfFileHex(File(p.join(dl.path, 'a.bin'))),
        shaHex(data),
      );
    });

    test('guard truncated-longer-than-declared: a body longer than the chunk '
        'is rejected and not recorded', () async {
      final data = bytes(2 * cs, 2);
      final rx = newRx();
      final st = await rx.createSession(
        requestFor(itemOf(data, 'l.bin')),
        remoteAddress: '127.0.0.1',
      );
      final tok = st.acceptedFiles['f']!.token;
      await expectLater(
        rx.putChunk(
          st.sessionId,
          'f',
          0,
          Stream<List<int>>.fromIterable([data.sublist(0, cs + 5)]),
          token: tok,
          chunkSha256: shaHex(data.sublist(0, cs)),
        ),
        throwsA(isA<LsException>()),
      );
      expect(
        (await rx.fileState(st.sessionId, 'f', token: tok)).receivedRanges,
        isEmpty,
      );
    });
  });

  group('duplicate PUT after a reconnect', () {
    test('guard duplicate-put-idempotent: the same chunk twice (and a third '
        'time with a different piece size) succeeds, counts once and leaves '
        'the file identical', () async {
      final data = bytes(3 * cs, 3);
      final events = <LsEvent>[];
      final rx = FileReceiver(
        self: rxDev,
        downloadDir: dl,
        autoAccept: true,
        freeSpaceProbe: (_) async => null,
        onEvent: events.add,
      );
      receivers.add(rx);
      final st = await rx.createSession(
        requestFor(itemOf(data, 'd.bin')),
        remoteAddress: '127.0.0.1',
      );
      final tok = st.acceptedFiles['f']!.token;
      await put(rx, st.sessionId, tok, data, 1);
      await put(rx, st.sessionId, tok, data, 1);
      await put(rx, st.sessionId, tok, data, 1);
      await put(rx, st.sessionId, tok, data, 0);
      await put(rx, st.sessionId, tok, data, 2);
      final state = await rx.fileState(st.sessionId, 'f', token: tok);
      expect(state.receivedRanges, [
        [0, 2],
      ]);
      final progress = events.whereType<FileProgress>().toList();
      expect(
        progress.last.bytesDone,
        data.length,
        reason: 'duplicate PUTs must not inflate the byte count',
      );
      expect(
        progress.map((e) => e.bytesDone).every((b) => b <= data.length),
        isTrue,
      );
      await rx.completeFile(st.sessionId, 'f', token: tok);
      expect(
        await sha256OfFileHex(File(p.join(dl.path, 'd.bin'))),
        shaHex(data),
      );
    });
  });

  group('/state with impossible ranges', () {
    const bad = <String, ChunkRanges>{
      'out of range [0,50] on a 3-chunk file': [
        [0, 50],
      ],
      'negative start [-5,1]': [
        [-5, 1],
      ],
      'overlapping [[0,1],[1,2]]': [
        [0, 1],
        [1, 2],
      ],
      'inverted [2,0]': [
        [2, 0],
      ],
      'wrong shape [0,1,2]': [
        [0, 1, 2],
      ],
    };
    for (final e in bad.entries) {
      test('guard state-ranges-rejected: ${e.key} -> FAILED(PROTOCOL_ERROR), '
          'no chunk skipped on its strength, no complete sent', () async {
        final data = bytes(3 * cs, 4);
        final rx = LyingStateReceiver(
          self: rxDev,
          downloadDir: dl,
          lie: e.value,
        );
        receivers.add(rx);
        final server = ApiServer(
          handler: rx,
          bindAddress: InternetAddress.loopbackIPv4,
          preferredPort: 0,
          enableRateLimit: false,
        );
        final port = await server.start();
        addTearDown(() => server.stop(force: true));
        final file = File(p.join(tmp.path, 'src', 's.bin'))
          ..createSync(recursive: true)
          ..writeAsBytesSync(data);
        final client = ApiClient(host: '127.0.0.1', port: port);
        final sender = FileSender(
          client: client,
          self: txDev,
          chunker: const Chunker(cs),
          retryDelays: const [Duration(milliseconds: 10)],
        );
        final res = await sender
            .send([file])
            .timeout(const Duration(seconds: 30));
        client.close();
        expect(res.status, TransferStatus.failed, reason: '$res');
        expect(res.failureReason, FailureReason.protocolError, reason: '$res');
        expect(
          rx.calls.where((c) => c == 'complete'),
          isEmpty,
          reason: 'complete was sent after a bogus /state: ${rx.calls}',
        );
      });
    }
  });

  group('disk full when resuming', () {
    test('guard resume-diskfull-keeps-state: a restarted receiver without '
        'free space refuses with INSUFFICIENT_STORAGE and leaves the partial '
        'file and the bitmap untouched; once space is back the transfer '
        'resumes', () async {
      final data = bytes(10 * cs, 5);
      final it = itemOf(data, 'big.bin');
      final rx1 = newRx();
      final st1 = await rx1.createSession(
        requestFor(it),
        remoteAddress: '127.0.0.1',
      );
      final tok1 = st1.acceptedFiles['f']!.token;
      for (var i = 0; i < 9; i++) {
        await put(rx1, st1.sessionId, tok1, data, i);
      }
      rx1.dispose(); // "crash": chunks 0..7 persisted
      final part = File(p.join(dl.path, 'big.bin.lspart'));
      final side = File('${part.path}.json');
      expect(part.existsSync() && side.existsSync(), isTrue);
      final before = side.readAsStringSync();
      final partLen = part.lengthSync();

      final full = newRx(probe: (_) async => 0);
      await expectLater(
        full.createSession(requestFor(it), remoteAddress: '127.0.0.1'),
        throwsA(
          isA<LsException>().having(
            (e) => e.code,
            'code',
            LsErrorCode.insufficientStorage,
          ),
        ),
      );
      expect(part.existsSync(), isTrue, reason: 'partial file was deleted');
      expect(side.existsSync(), isTrue, reason: 'sidecar was deleted');
      expect(side.readAsStringSync(), before, reason: 'bitmap changed');
      expect(part.lengthSync(), partLen);
      expect((jsonDecode(before) as Map<String, Object?>)['received'], [
        [0, 7],
      ]);

      final back = newRx();
      final st = await back.createSession(
        requestFor(it),
        remoteAddress: '127.0.0.1',
      );
      expect(st.acceptedFiles['f']!.receivedRanges, [
        [0, 7],
      ]);
    });
  });
}
