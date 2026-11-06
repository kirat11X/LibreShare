import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:libreshare_core/src/clock.dart';
import 'package:libreshare_core/src/model/device.dart';
import 'package:libreshare_core/src/model/events.dart';
import 'package:libreshare_core/src/model/file_item.dart';
import 'package:libreshare_core/src/model/ls_exception.dart';
import 'package:libreshare_core/src/model/session_models.dart';
import 'package:libreshare_core/src/model/transfer_status.dart';
import 'package:libreshare_core/src/transfer/file_receiver.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const int cs = 64 * 1024; // smallest legal chunk size keeps tests fast

const self = DeviceInfo(
  deviceId: 'rx-id',
  alias: 'Receiver',
  platform: 'linux',
);
const senderDev = DeviceInfo(
  deviceId: 'tx-id',
  alias: 'Sender',
  platform: 'linux',
);

Matcher throwsLs(LsErrorCode code) =>
    throwsA(isA<LsException>().having((e) => e.code, 'code', code));

Uint8List randomBytes(int n, [int seed = 1]) {
  final r = Random(seed);
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    b[i] = r.nextInt(256);
  }
  return b;
}

String shaHex(List<int> b) => sha256.convert(b).toString();

class TFile {
  TFile(
    this.id,
    this.name,
    this.data, {
    this.relativePath,
    this.hashInManifest = true,
    this.modified,
    this.manifestSha,
  });
  final String id;
  final String name;
  final Uint8List data;
  final String? relativePath;
  final bool hashInManifest;
  final DateTime? modified;
  final String? manifestSha; // override (e.g. wrong hash)

  int get chunkCount => data.isEmpty ? 0 : (data.length + cs - 1) ~/ cs;

  FileItem toItem() => FileItem(
    fileId: id,
    fileName: name,
    relativePath: relativePath,
    size: data.length,
    chunkCount: chunkCount,
    sha256: manifestSha ?? (hashInManifest ? shaHex(data) : null),
    modified: modified,
  );
}

SessionRequest request(
  List<TFile> files, {
  int chunkSize = cs,
  int? totalSize,
  List<FileItem>? items,
}) {
  final its = items ?? files.map((f) => f.toItem()).toList();
  return SessionRequest(
    sender: senderDev,
    files: its,
    totalSize: totalSize ?? its.fold<int>(0, (a, f) => a + f.size),
    chunkSize: chunkSize,
  );
}

void main() {
  late Directory tmp;
  late Directory dl;
  late List<LsEvent> events;
  final receivers = <FileReceiver>[];

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ls_receiver_');
    dl = Directory(p.join(tmp.path, 'Downloads'))..createSync();
    events = [];
  });
  tearDown(() {
    for (final r in receivers) {
      r.dispose();
    }
    receivers.clear();
    tmp.deleteSync(recursive: true);
  });

  FileReceiver newReceiver({
    bool autoAccept = true,
    Duration permissionTimeout = const Duration(seconds: 120),
    Directory? partialDir,
    Directory? downloadDir,
    Clock clock = const SystemClock(),
    Future<int?> Function(Directory)? probe,
  }) {
    final r = FileReceiver(
      self: self,
      downloadDir: downloadDir ?? dl,
      partialDir: partialDir,
      autoAccept: autoAccept,
      clock: clock,
      onEvent: events.add,
      permissionTimeout: permissionTimeout,
      freeSpaceProbe: probe ?? (_) async => null,
    );
    receivers.add(r);
    return r;
  }

  Future<void> sendChunk(
    FileReceiver rx,
    String sid,
    TFile f,
    String token,
    int index, {
    bool withHash = true,
    List<int>? override,
    int pieceSize = 20000,
  }) {
    final start = index * cs;
    final end = min(start + cs, f.data.length);
    final bytes = override ?? f.data.sublist(start, end);
    Stream<List<int>> body() async* {
      for (var i = 0; i < bytes.length; i += pieceSize) {
        yield bytes.sublist(i, min(i + pieceSize, bytes.length));
      }
    }

    return rx.putChunk(
      sid,
      f.id,
      index,
      body(),
      token: token,
      chunkSha256: withHash ? shaHex(f.data.sublist(start, end)) : null,
    );
  }

  Future<void> sendAll(
    FileReceiver rx,
    String sid,
    TFile f,
    String token, {
    bool withHash = true,
    bool parallel = false,
    Iterable<int>? only,
  }) async {
    final idx = only ?? List.generate(f.chunkCount, (i) => i);
    if (parallel) {
      await Future.wait([
        for (final i in idx)
          sendChunk(rx, sid, f, token, i, withHash: withHash),
      ]);
    } else {
      for (final i in idx) {
        await sendChunk(rx, sid, f, token, i, withHash: withHash);
      }
    }
  }

  Future<(String, Map<String, AcceptedFile>)> open(
    FileReceiver rx,
    List<TFile> files,
  ) async {
    final st = await rx.createSession(
      request(files),
      remoteAddress: '127.0.0.1',
    );
    expect(st.status, TransferStatus.inProgress);
    return (st.sessionId, st.acceptedFiles);
  }

  File finalFile(String rel) => File(p.join(dl.path, rel));

  List<String> lspartLeftovers() => dl
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.contains('.lspart'))
      .map((f) => f.path)
      .toList();

  group('happy path', () {
    test(
      'multi-file transfer is byte-identical (incl. 0 B, 1 B, chunk edges)',
      () async {
        final rx = newReceiver();
        final files = [
          TFile('f0', 'empty.bin', Uint8List(0)),
          TFile('f1', 'one.bin', randomBytes(1, 1)),
          TFile('f2', 'cs-1.bin', randomBytes(cs - 1, 2)),
          TFile('f3', 'cs.bin', randomBytes(cs, 3)),
          TFile('f4', 'cs+1.bin', randomBytes(cs + 1, 4)),
          TFile('f5', 'big.bin', randomBytes(3 * cs + 12345, 5)),
        ];
        final st = await rx.createSession(
          request(files),
          remoteAddress: '10.0.0.2',
        );
        expect(st.status, TransferStatus.inProgress);
        expect(st.failureReason, isNull);
        expect(st.acceptedFiles.keys, files.map((f) => f.id));
        final tokens = st.acceptedFiles.values.map((a) => a.token).toSet();
        expect(tokens.length, files.length, reason: 'tokens are unique');
        for (final a in st.acceptedFiles.values) {
          expect(a.receivedRanges, isEmpty);
          // 128-bit b64url, no padding
          expect(RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(a.token), isTrue);
        }
        expect(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ).hasMatch(st.sessionId),
          isTrue,
          reason: 'uuid v4 session id',
        );

        for (final f in files) {
          final token = st.acceptedFiles[f.id]!.token;
          final fs0 = await rx.fileState(st.sessionId, f.id, token: token);
          expect(fs0.chunkCount, f.chunkCount);
          expect(fs0.receivedRanges, isEmpty);
          await sendAll(rx, st.sessionId, f, token);
          final fs1 = await rx.fileState(st.sessionId, f.id, token: token);
          expect(
            fs1.receivedRanges,
            f.chunkCount == 0
                ? isEmpty
                : [
                    [0, f.chunkCount - 1],
                  ],
          );
          final v = await rx.completeFile(st.sessionId, f.id, token: token);
          expect(v.verified, isTrue);
          expect(v.sha256, shaHex(f.data));
          expect(finalFile(f.name).readAsBytesSync(), f.data, reason: f.name);
        }
        final fin = await rx.finish(st.sessionId);
        expect(fin.status, TransferStatus.completed);
        expect(lspartLeftovers(), isEmpty);
        expect(
          events.whereType<FileSaved>().map((e) => e.fileId),
          files.map((f) => f.id),
        );
        final done = events.whereType<SessionFinished>().single;
        expect(done.success, isTrue);
        expect(events.whereType<SessionCreated>().single.outgoing, isFalse);
        expect(events.whereType<FileProgress>(), isNotEmpty);
        final last = events.whereType<FileProgress>().last;
        expect(last.bytesDone, last.bytesTotal);

        final again = await rx.getSession(st.sessionId);
        expect(again.status, TransferStatus.completed);
        expect(again.acceptedFiles, isEmpty, reason: 'tokens end at COMPLETED');
      },
    );

    test(
      'chunks sent in parallel and out of order assemble correctly',
      () async {
        final rx = newReceiver();
        final f = TFile('f', 'par.bin', randomBytes(7 * cs + 99, 9));
        final (sid, acc) = await open(rx, [f]);
        final order = List.generate(f.chunkCount, (i) => i)..shuffle(Random(3));
        await Future.wait([
          for (final i in order) sendChunk(rx, sid, f, acc['f']!.token, i),
        ]);
        await rx.completeFile(sid, 'f', token: acc['f']!.token);
        expect(finalFile('par.bin').readAsBytesSync(), f.data);
      },
    );

    test('no per-chunk hash header: whole-file hash still protects', () async {
      final rx = newReceiver();
      final f = TFile('f', 'nohash.bin', randomBytes(2 * cs + 5, 10));
      final (sid, acc) = await open(rx, [f]);
      await sendAll(rx, sid, f, acc['f']!.token, withHash: false);
      final v = await rx.completeFile(sid, 'f', token: acc['f']!.token);
      expect(v.verified, isTrue);
      expect(finalFile('nohash.bin').readAsBytesSync(), f.data);
    });

    test('manifest sha256 null: hash supplied at /complete', () async {
      final rx = newReceiver();
      final f = TFile(
        'f',
        'late.bin',
        randomBytes(cs + 7, 11),
        hashInManifest: false,
      );
      final (sid, acc) = await open(rx, [f]);
      final tok = acc['f']!.token;
      await sendAll(rx, sid, f, tok);
      // neither manifest nor body hash: cannot verify
      await expectLater(
        rx.completeFile(sid, 'f', token: tok),
        throwsLs(LsErrorCode.badRequest),
      );
      final v = await rx.completeFile(
        sid,
        'f',
        token: tok,
        sha256: shaHex(f.data).toUpperCase(),
      );
      expect(v.verified, isTrue);
      expect(v.sha256, shaHex(f.data));
      expect(finalFile('late.bin').readAsBytesSync(), f.data);
    });

    test('wrong sha256 supplied at /complete -> VERIFY_FAILED', () async {
      final rx = newReceiver();
      final f = TFile(
        'f',
        'late.bin',
        randomBytes(cs + 7, 12),
        hashInManifest: false,
      );
      final (sid, acc) = await open(rx, [f]);
      await sendAll(rx, sid, f, acc['f']!.token);
      await expectLater(
        rx.completeFile(sid, 'f', token: acc['f']!.token, sha256: 'a' * 64),
        throwsLs(LsErrorCode.verifyFailed),
      );
      expect(finalFile('late.bin').existsSync(), isFalse);
    });

    test('completeFile is idempotent once verified', () async {
      final rx = newReceiver();
      final f = TFile('f', 'a.bin', randomBytes(100, 13));
      final (sid, acc) = await open(rx, [f]);
      await sendAll(rx, sid, f, acc['f']!.token);
      final v1 = await rx.completeFile(sid, 'f', token: acc['f']!.token);
      final v2 = await rx.completeFile(sid, 'f', token: acc['f']!.token);
      expect(v2.sha256, v1.sha256);
      expect(finalFile('a.bin').readAsBytesSync(), f.data);
    });

    test('modified time from the manifest is applied', () async {
      final rx = newReceiver();
      final mtime = DateTime.utc(2020, 5, 17, 8, 30);
      final f = TFile('f', 'old.txt', randomBytes(10, 14), modified: mtime);
      final (sid, acc) = await open(rx, [f]);
      await sendAll(rx, sid, f, acc['f']!.token);
      await rx.completeFile(sid, 'f', token: acc['f']!.token);
      expect(
        finalFile('old.txt').lastModifiedSync().toUtc().millisecondsSinceEpoch,
        mtime.millisecondsSinceEpoch,
      );
    });

    test('relativePath folder structure is recreated inside the dir', () async {
      final rx = newReceiver();
      final f = TFile(
        'f',
        'x.jpg',
        randomBytes(10, 15),
        relativePath: 'photos\\2024/trip',
      );
      final (sid, acc) = await open(rx, [f]);
      await sendAll(rx, sid, f, acc['f']!.token);
      await rx.completeFile(sid, 'f', token: acc['f']!.token);
      expect(
        File(p.join(dl.path, 'photos', '2024', 'trip', 'x.jpg'))
            .readAsBytesSync(),
        f.data,
      );
    });

    test(
      'partialDir: partial lives elsewhere and is moved on complete',
      () async {
        final part = Directory(p.join(tmp.path, 'partials'));
        final rx = newReceiver(partialDir: part);
        final f = TFile(
          'f',
          'a.bin',
          randomBytes(3 * cs, 16),
          relativePath: 'd',
        );
        final (sid, acc) = await open(rx, [f]);
        await sendChunk(rx, sid, f, acc['f']!.token, 0);
        expect(part.existsSync(), isTrue);
        expect(
          part.listSync().where((e) => e.path.endsWith('.lspart')),
          isNotEmpty,
        );
        expect(
          lspartLeftovers(),
          isEmpty,
          reason: 'nothing partial in downloads',
        );
        await sendAll(rx, sid, f, acc['f']!.token, only: [1, 2]);
        await rx.completeFile(sid, 'f', token: acc['f']!.token);
        expect(File(p.join(dl.path, 'd', 'a.bin')).readAsBytesSync(), f.data);
        expect(part.listSync(), isEmpty);
      },
    );

    test('partial file is named <name>.lspart next to the target', () async {
      final rx = newReceiver();
      final f = TFile('f', 'big.bin', randomBytes(2 * cs, 17));
      final (sid, acc) = await open(rx, [f]);
      await sendChunk(rx, sid, f, acc['f']!.token, 1);
      expect(File(p.join(dl.path, 'big.bin.lspart')).existsSync(), isTrue);
      expect(finalFile('big.bin').existsSync(), isFalse);
    });
  });

  group('chunk validation', () {
    late FileReceiver rx;
    late TFile f;
    late String sid;
    late String tok;

    setUp(() async {
      rx = newReceiver();
      f = TFile('f', 'a.bin', randomBytes(3 * cs + 10, 20));
      final (s, acc) = await open(rx, [f]);
      sid = s;
      tok = acc['f']!.token;
    });

    test('corrupted chunk -> 422, NOT recorded, resend succeeds', () async {
      final bad = Uint8List.fromList(f.data.sublist(0, cs))..[100] ^= 0xff;
      await expectLater(
        sendChunk(rx, sid, f, tok, 0, override: bad),
        throwsLs(LsErrorCode.chunkHashMismatch),
      );
      expect(
        (await rx.fileState(sid, 'f', token: tok)).receivedRanges,
        isEmpty,
      );
      await sendChunk(rx, sid, f, tok, 0);
      expect((await rx.fileState(sid, 'f', token: tok)).receivedRanges, [
        [0, 0],
      ]);
      // the corrupt bytes were overwritten: finish the transfer and compare
      await sendAll(rx, sid, f, tok, only: [1, 2, 3]);
      await rx.completeFile(sid, 'f', token: tok);
      expect(finalFile('a.bin').readAsBytesSync(), f.data);
    });

    test(
      'corrupt duplicate of a recorded chunk is rejected and harmless',
      () async {
        await sendChunk(rx, sid, f, tok, 1);
        final bad = Uint8List.fromList(f.data.sublist(cs, 2 * cs))..[5] ^= 1;
        await expectLater(
          sendChunk(rx, sid, f, tok, 1, override: bad),
          throwsLs(LsErrorCode.chunkHashMismatch),
        );
        expect((await rx.fileState(sid, 'f', token: tok)).receivedRanges, [
          [1, 1],
        ]);
        await sendAll(rx, sid, f, tok, only: [0, 2, 3]);
        await rx.completeFile(sid, 'f', token: tok);
        expect(finalFile('a.bin').readAsBytesSync(), f.data);
      },
    );

    test('malformed chunk hash header -> 400', () async {
      await expectLater(
        rx.putChunk(
          sid,
          'f',
          0,
          Stream.value(f.data.sublist(0, cs)),
          token: tok,
          chunkSha256: 'xyz',
        ),
        throwsLs(LsErrorCode.badRequest),
      );
    });

    test('duplicate chunk is idempotent', () async {
      await sendChunk(rx, sid, f, tok, 2);
      await sendChunk(rx, sid, f, tok, 2);
      await sendChunk(rx, sid, f, tok, 2);
      expect((await rx.fileState(sid, 'f', token: tok)).receivedRanges, [
        [2, 2],
      ]);
      await sendAll(rx, sid, f, tok, only: [0, 1, 3]);
      await sendChunk(rx, sid, f, tok, 0); // duplicate after others
      final progress = events.whereType<FileProgress>().last;
      expect(progress.bytesDone, f.data.length);
      await rx.completeFile(sid, 'f', token: tok);
      expect(finalFile('a.bin').readAsBytesSync(), f.data);
    });

    test('concurrent duplicates of the same chunk are counted once', () async {
      await Future.wait([
        for (var i = 0; i < 5; i++) sendChunk(rx, sid, f, tok, 1),
      ]);
      expect((await rx.fileState(sid, 'f', token: tok)).receivedRanges, [
        [1, 1],
      ]);
      final progress = events.whereType<FileProgress>().last;
      expect(progress.bytesDone, cs);
    });

    test('index out of range -> 416', () async {
      for (final i in [-1, 4, 5, 1000000]) {
        await expectLater(
          rx.putChunk(sid, 'f', i, Stream.value(<int>[1, 2, 3]), token: tok),
          throwsLs(LsErrorCode.outOfRange),
          reason: 'index $i',
        );
      }
    });

    test(
      'body longer than the chunk -> 416; shorter -> 400; not recorded',
      () async {
        await expectLater(
          sendChunk(
            rx,
            sid,
            f,
            tok,
            0,
            override: Uint8List(cs + 1),
            withHash: false,
          ),
          throwsLs(LsErrorCode.outOfRange),
        );
        await expectLater(
          sendChunk(
            rx,
            sid,
            f,
            tok,
            0,
            override: Uint8List(cs - 1),
            withHash: false,
          ),
          throwsLs(LsErrorCode.badRequest),
        );
        // the last chunk is 10 bytes long, not 64 KiB
        await expectLater(
          sendChunk(
            rx,
            sid,
            f,
            tok,
            3,
            override: Uint8List(11),
            withHash: false,
          ),
          throwsLs(LsErrorCode.outOfRange),
        );
        await expectLater(
          sendChunk(
            rx,
            sid,
            f,
            tok,
            3,
            override: Uint8List(9),
            withHash: false,
          ),
          throwsLs(LsErrorCode.badRequest),
        );
        expect(
          (await rx.fileState(sid, 'f', token: tok)).receivedRanges,
          isEmpty,
        );
      },
    );

    test('any chunk of a 0-byte file is out of range', () async {
      final z = TFile('z', 'z.bin', Uint8List(0));
      final (s2, acc2) = await open(rx, [z]);
      await expectLater(
        rx.putChunk(s2, 'z', 0, const Stream.empty(), token: acc2['z']!.token),
        throwsLs(LsErrorCode.outOfRange),
      );
    });

    test('bad token -> 401 on every file endpoint', () async {
      final other = TFile('g', 'g.bin', randomBytes(10, 21));
      final (s2, acc2) = await open(rx, [other]);
      for (final bad in [
        '',
        'nope',
        '${tok}x',
        tok.substring(1),
        acc2['g']!.token,
      ]) {
        await expectLater(
          sendChunk(rx, sid, f, bad, 0),
          throwsLs(LsErrorCode.tokenInvalid),
          reason: 'putChunk token "$bad"',
        );
        await expectLater(
          rx.fileState(sid, 'f', token: bad),
          throwsLs(LsErrorCode.tokenInvalid),
        );
        await expectLater(
          rx.completeFile(sid, 'f', token: bad),
          throwsLs(LsErrorCode.tokenInvalid),
        );
      }
      // a token from another session / file is not accepted either
      await expectLater(
        rx.fileState(s2, 'g', token: tok),
        throwsLs(LsErrorCode.tokenInvalid),
      );
      expect(
        (await rx.fileState(sid, 'f', token: tok)).receivedRanges,
        isEmpty,
      );
    });

    test('unknown session / file -> 404', () async {
      await expectLater(rx.getSession('nope'), throwsLs(LsErrorCode.notFound));
      await expectLater(
        rx.fileState('nope', 'f', token: tok),
        throwsLs(LsErrorCode.notFound),
      );
      await expectLater(
        rx.fileState(sid, 'nope', token: tok),
        throwsLs(LsErrorCode.notFound),
      );
      await expectLater(
        sendChunk(rx, 'nope', f, tok, 0),
        throwsLs(LsErrorCode.notFound),
      );
      await expectLater(
        rx.completeFile('nope', 'f', token: tok),
        throwsLs(LsErrorCode.notFound),
      );
      await expectLater(rx.finish('nope'), throwsLs(LsErrorCode.notFound));
      await expectLater(rx.cancel('nope'), throwsLs(LsErrorCode.notFound));
    });
  });

  group('verification', () {
    test('completing with missing chunks -> 409 MISSING_CHUNKS', () async {
      final rx = newReceiver();
      final f = TFile('f', 'a.bin', randomBytes(3 * cs, 30));
      final (sid, acc) = await open(rx, [f]);
      await sendAll(rx, sid, f, acc['f']!.token, only: [0, 2]);
      await expectLater(
        rx.completeFile(sid, 'f', token: acc['f']!.token),
        throwsLs(LsErrorCode.missingChunks),
      );
      expect(finalFile('a.bin').existsSync(), isFalse);
      // session still usable: send the missing chunk and complete
      await sendAll(rx, sid, f, acc['f']!.token, only: [1]);
      await rx.completeFile(sid, 'f', token: acc['f']!.token);
      expect(finalFile('a.bin').readAsBytesSync(), f.data);
    });

    test('whole-file hash mismatch -> VERIFY_FAILED, partial deleted, session FAILED', () async {
      final rx = newReceiver();
      final good = randomBytes(2 * cs + 3, 31);
      final f = TFile(
        'f',
        'a.bin',
        good,
        manifestSha: shaHex(
          randomBytes(10, 99),
        ), // manifest promises other bytes
      );
      final f2 = TFile('g', 'g.bin', randomBytes(5, 32));
      final (sid, acc) = await open(rx, [f, f2]);
      await sendAll(rx, sid, f, acc['f']!.token);
      expect(File(p.join(dl.path, 'a.bin.lspart')).existsSync(), isTrue);
      await expectLater(
        rx.completeFile(sid, 'f', token: acc['f']!.token),
        throwsLs(LsErrorCode.verifyFailed),
      );
      expect(finalFile('a.bin').existsSync(), isFalse);
      expect(File(p.join(dl.path, 'a.bin.lspart')).existsSync(), isFalse);
      expect(File(p.join(dl.path, 'a.bin.lspart.json')).existsSync(), isFalse);
      final st = await rx.getSession(sid);
      expect(st.status, TransferStatus.failed);
      expect(st.failureReason, FailureReason.verifyFailed);
      expect(
        events.whereType<SessionFinished>().single.reason,
        FailureReason.verifyFailed.wire,
      );
      expect(events.whereType<FileSaved>(), isEmpty);
      // nothing more is accepted
      await expectLater(
        sendChunk(rx, sid, f2, acc['g']!.token, 0),
        throwsLs(LsErrorCode.wrongState),
      );
      await expectLater(rx.finish(sid), throwsLs(LsErrorCode.wrongState));
    });

    test(
      'finish before all files are verified -> 409; then succeeds',
      () async {
        final rx = newReceiver();
        final a = TFile('a', 'a.bin', randomBytes(10, 33));
        final b = TFile('b', 'b.bin', randomBytes(cs + 1, 34));
        final (sid, acc) = await open(rx, [a, b]);
        await expectLater(rx.finish(sid), throwsLs(LsErrorCode.wrongState));
        await sendAll(rx, sid, a, acc['a']!.token);
        await rx.completeFile(sid, 'a', token: acc['a']!.token);
        await expectLater(rx.finish(sid), throwsLs(LsErrorCode.wrongState));
        await sendAll(rx, sid, b, acc['b']!.token);
        // chunks sent but not completed yet
        await expectLater(rx.finish(sid), throwsLs(LsErrorCode.wrongState));
        await rx.completeFile(sid, 'b', token: acc['b']!.token);
        expect((await rx.finish(sid)).status, TransferStatus.completed);
        // idempotent
        expect((await rx.finish(sid)).status, TransferStatus.completed);
        // no chunk accepted after COMPLETED
        await expectLater(
          sendChunk(rx, sid, a, acc['a']!.token, 0),
          throwsLs(LsErrorCode.wrongState),
        );
      },
    );
  });

  group('file system safety', () {
    test('traversal in fileName lands inside the download dir', () async {
      final rx = newReceiver();
      final names = [
        '../../etc/passwd',
        '..\\..\\windows\\system32',
        '/etc/shadow',
        'C:\\Windows\\evil.dll',
        'CON',
        'nul.txt',
        '....//....//x',
      ];
      final files = [
        for (var i = 0; i < names.length; i++)
          TFile('f$i', names[i], randomBytes(10 + i, 40 + i)),
      ];
      final (sid, acc) = await open(rx, files);
      for (final f in files) {
        await sendAll(rx, sid, f, acc[f.id]!.token);
        await rx.completeFile(sid, f.id, token: acc[f.id]!.token);
      }
      for (final e in events.whereType<FileSaved>()) {
        expect(p.isWithin(dl.path, e.path), isTrue, reason: e.path);
        expect(p.dirname(e.path), dl.path);
        expect(File(e.path).existsSync(), isTrue);
      }
      expect(File(p.join(dl.path, 'passwd')).readAsBytesSync(), files[0].data);
      expect(File(p.join(dl.path, '_CON')).existsSync(), isTrue);
      expect(File(p.join(dl.path, '_nul.txt')).existsSync(), isTrue);
      expect(File(p.join(tmp.path, 'etc')).existsSync(), isFalse);
    });

    test('".." in relativePath rejects the whole session', () async {
      final rx = newReceiver();
      final f = TFile(
        'f',
        'x.txt',
        randomBytes(3, 50),
        relativePath: '../../etc',
      );
      await expectLater(
        rx.createSession(request([f]), remoteAddress: 'x'),
        throwsLs(LsErrorCode.badRequest),
      );
      expect(dl.listSync(), isEmpty);
    });

    test(
      'symlink inside the download dir cannot redirect a write outside',
      () async {
        final outside = Directory(p.join(tmp.path, 'outside'))..createSync();
        Link(p.join(dl.path, 'link')).createSync(outside.path);
        final victim = File(p.join(outside.path, 'victim.txt'))
          ..writeAsStringSync('precious');
        Link(p.join(dl.path, 'victim.txt')).createSync(victim.path);

        final rx = newReceiver();
        final a = TFile(
          'a',
          'evil.txt',
          randomBytes(20, 51),
          relativePath: 'link/sub',
        );
        final b = TFile('b', 'victim.txt', randomBytes(20, 52));
        final (sid, acc) = await open(rx, [a, b]);
        for (final f in [a, b]) {
          await sendAll(rx, sid, f, acc[f.id]!.token);
          await rx.completeFile(sid, f.id, token: acc[f.id]!.token);
        }
        expect(outside.listSync().map((e) => p.basename(e.path)), [
          'victim.txt',
        ]);
        expect(victim.readAsStringSync(), 'precious');
        for (final e in events.whereType<FileSaved>()) {
          expect(p.isWithin(dl.path, e.path), isTrue);
          expect(FileSystemEntity.isLinkSync(e.path), isFalse);
        }
      },
    );

    test(
      'never overwrites: existing file and same-session duplicates get (n)',
      () async {
        finalFile('a.txt').writeAsStringSync('orig');
        final rx = newReceiver();
        final f1 = TFile('f1', 'a.txt', randomBytes(11, 53));
        final f2 = TFile('f2', 'a.txt', randomBytes(12, 54));
        final f3 = TFile(
          'f3',
          'A.txt',
          randomBytes(13, 55),
        ); // case-insensitive FS safe
        final (sid, acc) = await open(rx, [f1, f2, f3]);
        for (final f in [f1, f2, f3]) {
          await sendAll(rx, sid, f, acc[f.id]!.token);
          await rx.completeFile(sid, f.id, token: acc[f.id]!.token);
        }
        expect(finalFile('a.txt').readAsStringSync(), 'orig');
        final saved = events
            .whereType<FileSaved>()
            .map((e) => p.basename(e.path))
            .toList();
        expect(saved.toSet().length, 3, reason: 'distinct names: $saved');
        expect(saved[0], 'a (1).txt');
        expect(saved[1], 'a (2).txt');
        expect(File(p.join(dl.path, saved[0])).readAsBytesSync(), f1.data);
        expect(File(p.join(dl.path, saved[1])).readAsBytesSync(), f2.data);
      },
    );

    test('target created while the transfer runs is not overwritten', () async {
      final rx = newReceiver();
      final f = TFile('f', 'race.txt', randomBytes(30, 56));
      final (sid, acc) = await open(rx, [f]);
      await sendAll(rx, sid, f, acc['f']!.token);
      finalFile('race.txt').writeAsStringSync('someone else wrote this');
      await rx.completeFile(sid, 'f', token: acc['f']!.token);
      expect(
        finalFile('race.txt').readAsStringSync(),
        'someone else wrote this',
      );
      expect(finalFile('race (1).txt').readAsBytesSync(), f.data);
    });

    test('foreign <name>.lspart (no sidecar) is never clobbered', () async {
      File(p.join(dl.path, 'x.bin.lspart')).writeAsStringSync('user data');
      final rx = newReceiver();
      final f = TFile('f', 'x.bin', randomBytes(30, 57));
      final (sid, acc) = await open(rx, [f]);
      await sendAll(rx, sid, f, acc['f']!.token);
      await rx.completeFile(sid, 'f', token: acc['f']!.token);
      expect(
        File(p.join(dl.path, 'x.bin.lspart')).readAsStringSync(),
        'user data',
      );
      expect(finalFile('x (1).bin').readAsBytesSync(), f.data);
    });

    test('very long file names still work (.lspart suffix must fit)', () async {
      final rx = newReceiver();
      final f = TFile('f', '${'n' * 400}.bin', randomBytes(30, 58));
      final (sid, acc) = await open(rx, [f]);
      await sendAll(rx, sid, f, acc['f']!.token);
      await rx.completeFile(sid, 'f', token: acc['f']!.token);
      final saved = events.whereType<FileSaved>().single.path;
      expect(utf8.encode(p.basename(saved)).length, lessThanOrEqualTo(255));
      expect(
        utf8.encode('${p.basename(saved)}.lspart.json.tmp').length,
        lessThanOrEqualTo(255),
      );
      expect(p.basename(saved), endsWith('.bin'));
      expect(File(saved).readAsBytesSync(), f.data);
    });
  });

  group('createSession validation', () {
    late FileReceiver rx;
    setUp(() => rx = newReceiver());

    Future<void> expectRejected(SessionRequest r, LsErrorCode code) =>
        expectLater(rx.createSession(r, remoteAddress: 'x'), throwsLs(code));

    FileItem item({
      String id = 'f',
      String name = 'a.bin',
      int size = 10,
      int? chunkCount,
      String? sha,
    }) => FileItem(
      fileId: id,
      fileName: name,
      size: size,
      chunkCount: chunkCount ?? ((size + cs - 1) ~/ cs),
      sha256: sha,
    );

    test(
      'no files',
      () => expectRejected(request([], items: []), LsErrorCode.badRequest),
    );

    test('more than 10,000 files -> 413', () async {
      final items = [for (var i = 0; i < 10001; i++) item(id: 'f$i', size: 0)];
      await expectRejected(request([], items: items), LsErrorCode.tooLarge);
    });

    test('exactly 10,000 files (all the same name) accepted quickly', () async {
      final items = [for (var i = 0; i < 10000; i++) item(id: 'f$i', size: 0)];
      final sw = Stopwatch()..start();
      final st = await rx.createSession(
        request([], items: items),
        remoteAddress: 'x',
      );
      expect(st.acceptedFiles.length, 10000);
      expect(sw.elapsed, lessThan(const Duration(seconds: 20)));
    });

    test(
      'negative size',
      () => expectRejected(
        request([], items: [item(size: -1, chunkCount: 0)], totalSize: -1),
        LsErrorCode.badRequest,
      ),
    );

    test('sizes do not sum to totalSize', () async {
      await expectRejected(
        request(
          [],
          items: [
            item(size: 10),
            item(id: 'g', size: 5),
          ],
          totalSize: 16,
        ),
        LsErrorCode.badRequest,
      );
      await expectRejected(
        request([], items: [item(size: 10)], totalSize: 9),
        LsErrorCode.badRequest,
      );
    });

    test(
      'absurd sizes cannot overflow the sum',
      () => expectRejected(
        request(
          [],
          items: [
            item(size: 1 << 62, chunkCount: 1),
            item(id: 'g', size: 1 << 62, chunkCount: 1),
          ],
          totalSize: 0,
        ),
        LsErrorCode.tooLarge,
      ),
    );

    test('bad chunk sizes', () async {
      for (final bad in [
        0,
        -1,
        1000,
        cs - 1,
        cs + 1,
        3 * cs,
        32 * 1024,
        32 * 1024 * 1024,
      ]) {
        await expectRejected(
          request([], items: [item(size: 10, chunkCount: 1)], chunkSize: bad),
          LsErrorCode.badRequest,
        );
      }
    });

    test('legal chunk sizes: 64 KiB, 4 MiB (default), 16 MiB', () async {
      for (final ok in [cs, 4 * 1024 * 1024, 16 * 1024 * 1024]) {
        final st = await rx.createSession(
          request([], items: [item(size: 10, chunkCount: 1)], chunkSize: ok),
          remoteAddress: 'x',
        );
        expect(st.status, TransferStatus.inProgress, reason: '$ok');
      }
    });

    test('chunkCount inconsistent with size', () async {
      await expectRejected(
        request([], items: [item(size: cs + 1, chunkCount: 1)]),
        LsErrorCode.badRequest,
      );
      await expectRejected(
        request([], items: [item(size: 0, chunkCount: 1)]),
        LsErrorCode.badRequest,
      );
      await expectRejected(
        request([], items: [item(size: 10, chunkCount: 0)]),
        LsErrorCode.badRequest,
      );
    });

    test('duplicate / empty / oversized fileId', () async {
      await expectRejected(
        request(
          [],
          items: [
            item(id: 'f'),
            item(id: 'f'),
          ],
          totalSize: 20,
        ),
        LsErrorCode.badRequest,
      );
      await expectRejected(
        request([], items: [item(id: '')]),
        LsErrorCode.badRequest,
      );
      await expectRejected(
        request([], items: [item(id: 'x' * 129)]),
        LsErrorCode.badRequest,
      );
    });

    test('malformed sha256 in manifest', () async {
      for (final bad in ['abc', 'g' * 64, 'a' * 63, 'a' * 65]) {
        await expectRejected(
          request([], items: [item(sha: bad)]),
          LsErrorCode.badRequest,
        );
      }
    });

    test('insufficient free space -> 507 (totalSize + margin)', () async {
      final r2 = newReceiver(probe: (_) async => 64 * 1024 * 1024 + 99);
      await expectLater(
        r2.createSession(
          request([], items: [item(size: 100, chunkCount: 1)]),
          remoteAddress: 'x',
        ),
        throwsLs(LsErrorCode.insufficientStorage),
      );
      final r3 = newReceiver(probe: (_) async => 64 * 1024 * 1024 + 100);
      final st = await r3.createSession(
        request([], items: [item(size: 100, chunkCount: 1)]),
        remoteAddress: 'x',
      );
      expect(st.status, TransferStatus.inProgress);
    });

    test('unknown free space does not block', () async {
      final r2 = newReceiver(probe: (_) async => null);
      final st = await r2.createSession(
        request([], items: [item()]),
        remoteAddress: 'x',
      );
      expect(st.status, TransferStatus.inProgress);
    });

    test('real free-space probe works on this machine', () async {
      final r2 = FileReceiver(self: self, downloadDir: dl);
      receivers.add(r2);
      final st = await r2.createSession(
        request([], items: [item()]),
        remoteAddress: 'x',
      );
      expect(st.status, TransferStatus.inProgress);
    });
  });

  group('permission flow (autoAccept = false)', () {
    test('PENDING until accept; long-poll wakes on change', () async {
      final rx = newReceiver(autoAccept: false);
      final f = TFile('f', 'a.bin', randomBytes(50, 60));
      final st = await rx.createSession(request([f]), remoteAddress: 'x');
      expect(st.status, TransferStatus.pending);
      expect(st.acceptedFiles, isEmpty, reason: 'no tokens before consent');
      expect(rx.pendingSessionIds, [st.sessionId]);
      expect(rx.requestFor(st.sessionId)!.files.single.fileId, 'f');
      expect(dl.listSync(), isEmpty, reason: 'nothing on disk before consent');

      // long-poll that times out unchanged
      final sw = Stopwatch()..start();
      final same = await rx.getSession(
        st.sessionId,
        wait: const Duration(milliseconds: 150),
      );
      expect(same.status, TransferStatus.pending);
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(120));

      // long-poll that is woken by accept()
      final polled = rx.getSession(
        st.sessionId,
        wait: const Duration(seconds: 10),
      );
      sw
        ..reset()
        ..start();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await rx.accept(st.sessionId);
      final after = await polled;
      expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
      expect(after.status, TransferStatus.inProgress);
      expect(after.acceptedFiles['f']!.token, isNotEmpty);
      expect(rx.pendingSessionIds, isEmpty);

      final tok = after.acceptedFiles['f']!.token;
      await sendAll(rx, st.sessionId, f, tok);
      await rx.completeFile(st.sessionId, 'f', token: tok);
      expect((await rx.finish(st.sessionId)).status, TransferStatus.completed);
      expect(finalFile('a.bin').readAsBytesSync(), f.data);
    });

    test('long-poll on a terminal session returns immediately', () async {
      final rx = newReceiver(autoAccept: false);
      final st = await rx.createSession(
        request([TFile('f', 'a.bin', randomBytes(5, 61))]),
        remoteAddress: 'x',
      );
      await rx.reject(st.sessionId);
      final sw = Stopwatch()..start();
      final r = await rx.getSession(
        st.sessionId,
        wait: const Duration(seconds: 20),
      );
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
      expect(r.status, TransferStatus.failed);
    });

    test('reject -> FAILED(REJECTED); no files, no chunks', () async {
      final rx = newReceiver(autoAccept: false);
      final f = TFile('f', 'a.bin', randomBytes(5, 62));
      final st = await rx.createSession(request([f]), remoteAddress: 'x');
      final polled = rx.getSession(
        st.sessionId,
        wait: const Duration(seconds: 10),
      );
      await rx.reject(st.sessionId);
      final after = await polled;
      expect(after.status, TransferStatus.failed);
      expect(after.failureReason, FailureReason.rejected);
      expect(after.acceptedFiles, isEmpty);
      await expectLater(
        rx.accept(st.sessionId),
        throwsLs(LsErrorCode.wrongState),
      );
      await expectLater(
        rx.reject(st.sessionId),
        throwsLs(LsErrorCode.wrongState),
      );
      expect(dl.listSync(), isEmpty);
      final fin = events.whereType<SessionFinished>().single;
      expect(fin.success, isFalse);
      expect(fin.reason, 'REJECTED');
    });

    test('no answer -> FAILED(TIMEOUT) after permissionTimeout', () async {
      final rx = newReceiver(
        autoAccept: false,
        permissionTimeout: const Duration(milliseconds: 80),
      );
      final st = await rx.createSession(
        request([TFile('f', 'a.bin', randomBytes(5, 63))]),
        remoteAddress: 'x',
      );
      final r = await rx.getSession(
        st.sessionId,
        wait: const Duration(seconds: 10),
      );
      expect(r.status, TransferStatus.failed);
      expect(r.failureReason, FailureReason.timeout);
      await expectLater(
        rx.accept(st.sessionId),
        throwsLs(LsErrorCode.wrongState),
      );
      expect(rx.pendingSessionIds, isEmpty);
    });

    test('accepting in time cancels the timeout', () async {
      final rx = newReceiver(
        autoAccept: false,
        permissionTimeout: const Duration(milliseconds: 100),
      );
      final st = await rx.createSession(
        request([TFile('f', 'a.bin', randomBytes(5, 64))]),
        remoteAddress: 'x',
      );
      await rx.accept(st.sessionId);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(
        (await rx.getSession(st.sessionId)).status,
        TransferStatus.inProgress,
      );
    });

    test('cancel while PENDING -> FAILED(CANCELLED)', () async {
      final rx = newReceiver(autoAccept: false);
      final st = await rx.createSession(
        request([TFile('f', 'a.bin', randomBytes(5, 65))]),
        remoteAddress: 'x',
      );
      await rx.cancel(st.sessionId);
      final r = await rx.getSession(st.sessionId);
      expect(r.status, TransferStatus.failed);
      expect(r.failureReason, FailureReason.cancelled);
    });

    test('accept/reject unknown session -> 404', () async {
      final rx = newReceiver(autoAccept: false);
      await expectLater(rx.accept('nope'), throwsLs(LsErrorCode.notFound));
      await expectLater(rx.reject('nope'), throwsLs(LsErrorCode.notFound));
    });

    test('chunks before consent are refused', () async {
      final rx = newReceiver(autoAccept: false);
      final f = TFile('f', 'a.bin', randomBytes(5, 66));
      final st = await rx.createSession(request([f]), remoteAddress: 'x');
      await expectLater(
        sendChunk(rx, st.sessionId, f, 'guess', 0),
        throwsLs(LsErrorCode.tokenInvalid),
      );
      await expectLater(
        rx.fileState(st.sessionId, 'f', token: 'guess'),
        throwsLs(LsErrorCode.tokenInvalid),
      );
    });
  });

  group('cancel', () {
    test(
      'FAILED(CANCELLED), partials and sidecars deleted, finals kept',
      () async {
        final rx = newReceiver();
        final done = TFile('a', 'done.bin', randomBytes(10, 70));
        final part = TFile('b', 'part.bin', randomBytes(3 * cs, 71));
        final (sid, acc) = await open(rx, [done, part]);
        await sendAll(rx, sid, done, acc['a']!.token);
        await rx.completeFile(sid, 'a', token: acc['a']!.token);
        await sendAll(rx, sid, part, acc['b']!.token, only: [0, 1]);
        expect(File(p.join(dl.path, 'part.bin.lspart')).existsSync(), isTrue);

        await rx.cancel(sid);
        final st = await rx.getSession(sid);
        expect(st.status, TransferStatus.failed);
        expect(st.failureReason, FailureReason.cancelled);
        expect(lspartLeftovers(), isEmpty);
        expect(finalFile('done.bin').readAsBytesSync(), done.data);
        expect(finalFile('part.bin').existsSync(), isFalse);
        // sender gets 410 on further requests
        await expectLater(
          sendChunk(rx, sid, part, acc['b']!.token, 2),
          throwsLs(LsErrorCode.cancelled),
        );
        await expectLater(
          rx.completeFile(sid, 'b', token: acc['b']!.token),
          throwsLs(LsErrorCode.cancelled),
        );
        await expectLater(rx.finish(sid), throwsLs(LsErrorCode.cancelled));
        // idempotent
        await rx.cancel(sid);
        expect(
          events.whereType<SessionFinished>().single.reason,
          FailureReason.cancelled.wire,
        );
      },
    );

    test('cancel after COMPLETED is a no-op', () async {
      final rx = newReceiver();
      final f = TFile('f', 'a.bin', randomBytes(10, 72));
      final (sid, acc) = await open(rx, [f]);
      await sendAll(rx, sid, f, acc['f']!.token);
      await rx.completeFile(sid, 'f', token: acc['f']!.token);
      await rx.finish(sid);
      await rx.cancel(sid);
      expect((await rx.getSession(sid)).status, TransferStatus.completed);
      expect(finalFile('a.bin').existsSync(), isTrue);
    });
  });

  group('resume', () {
    test('receiver restart: bitmap is reloaded from the sidecar', () async {
      final f = TFile(
        'f',
        'resume.bin',
        randomBytes(10 * cs, 80),
        modified: DateTime.utc(2026, 10, 30, 10),
      );
      final rx1 = newReceiver();
      final (sid1, acc1) = await open(rx1, [f]);
      await sendAll(
        rx1,
        sid1,
        f,
        acc1['f']!.token,
        only: List.generate(9, (i) => i),
      );
      // "crash": rx1 is abandoned (chunks 0..7 were persisted at the 8th chunk)
      rx1.dispose();

      final rx2 = newReceiver();
      final st = await rx2.createSession(request([f]), remoteAddress: 'x');
      final acc = st.acceptedFiles['f']!;
      expect(acc.receivedRanges, [
        [0, 7],
      ]);
      expect(
        (await rx2.fileState(
          st.sessionId,
          'f',
          token: acc.token,
        )).receivedRanges,
        [
          [0, 7],
        ],
      );
      await sendAll(rx2, st.sessionId, f, acc.token, only: [8, 9]);
      await rx2.completeFile(st.sessionId, 'f', token: acc.token);
      expect(finalFile('resume.bin').readAsBytesSync(), f.data);
      expect(lspartLeftovers(), isEmpty);
    });

    test(
      'changed manifest (different hash) discards the old partial',
      () async {
        final f = TFile('f', 'resume.bin', randomBytes(10 * cs, 81));
        final rx1 = newReceiver();
        final (sid1, acc1) = await open(rx1, [f]);
        await sendAll(
          rx1,
          sid1,
          f,
          acc1['f']!.token,
          only: List.generate(9, (i) => i),
        );
        rx1.dispose();

        final f2 = TFile('f', 'resume.bin', randomBytes(10 * cs, 82));
        final rx2 = newReceiver();
        final st = await rx2.createSession(request([f2]), remoteAddress: 'x');
        expect(st.acceptedFiles['f']!.receivedRanges, isEmpty);
        final tok = st.acceptedFiles['f']!.token;
        await sendAll(rx2, st.sessionId, f2, tok);
        await rx2.completeFile(st.sessionId, 'f', token: tok);
        expect(finalFile('resume.bin').readAsBytesSync(), f2.data);
      },
    );

    test(
      'sessions idle for more than 24 h disappear (injected Clock)',
      () async {
        var now = DateTime.utc(2026, 11, 1);
        final clock = _Clock(() => now);
        final rx = newReceiver(clock: clock);
        final f = TFile('f', 'a.bin', randomBytes(10, 83));
        final (sid, _) = await open(rx, [f]);
        now = now.add(const Duration(hours: 23));
        expect((await rx.getSession(sid)).status, TransferStatus.inProgress);
        now = now.add(const Duration(hours: 23)); // 23 h since last activity
        expect((await rx.getSession(sid)).status, TransferStatus.inProgress);
        now = now.add(const Duration(hours: 25));
        await expectLater(rx.getSession(sid), throwsLs(LsErrorCode.notFound));
      },
    );
  });

  group('misc', () {
    test('deviceInfo and register', () {
      final rx = newReceiver();
      expect(rx.deviceInfo.deviceId, 'rx-id');
      expect(rx.register(senderDev).deviceId, 'rx-id');
    });

    test('session ids are unique and unguessable-looking', () async {
      final rx = newReceiver();
      final ids = <String>{};
      for (var i = 0; i < 50; i++) {
        final st = await rx.createSession(
          request([TFile('f', 'a$i.bin', randomBytes(3, i))]),
          remoteAddress: 'x',
        );
        ids.add(st.sessionId);
      }
      expect(ids.length, 50);
    });

    test('tokens never appear in logs or exception messages', () async {
      final rx = newReceiver();
      final f = TFile('f', 'a.bin', randomBytes(3 * cs, 90));
      final (sid, acc) = await open(rx, [f]);
      final tok = acc['f']!.token;
      try {
        await rx.completeFile(sid, 'f', token: tok);
        fail('expected MISSING_CHUNKS');
      } on LsException catch (e) {
        expect(e.message.contains(tok), isFalse);
      }
      try {
        await rx.fileState(sid, 'f', token: 'wrong-$tok');
        fail('expected TOKEN_INVALID');
      } on LsException catch (e) {
        expect(e.message.contains(tok), isFalse);
      }
    });
  });
}

class _Clock implements Clock {
  _Clock(this._now);
  final DateTime Function() _now;
  @override
  DateTime now() => _now();
}
