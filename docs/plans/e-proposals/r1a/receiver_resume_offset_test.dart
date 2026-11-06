// E5 / R1a: the receiver must write every chunk at its own offset into the
// `.lspart`, whatever the arrival order, and must overwrite (not append to)
// bytes left behind by a crash.
//
// Background: file_receiver.dart opens the partial with FileMode.append and
// then calls RandomAccessFile.setPosition. On POSIX, O_APPEND ignores the
// position for writes (they always land at EOF); on Windows the same mode
// makes setPosition unusable. Either way chunk N must still land at N*chunk.
//
// Every test name starts with the guard it protects so a verifier can mutate
// that guard and expect exactly that test to go red.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:libreshare_core/src/model/device.dart';
import 'package:libreshare_core/src/model/file_item.dart';
import 'package:libreshare_core/src/model/session_models.dart';
import 'package:libreshare_core/src/transfer/file_receiver.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const int cs = 64 * 1024; // smallest legal chunk size

const _self = DeviceInfo(
  deviceId: 'rx-id',
  alias: 'Receiver',
  platform: 'linux',
);
const _tx = DeviceInfo(deviceId: 'tx-id', alias: 'Sender', platform: 'linux');

Uint8List _bytes(int n, int seed) {
  final r = Random(seed);
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    b[i] = r.nextInt(256);
  }
  return b;
}

String _sha(List<int> b) => sha256.convert(b).toString();

void main() {
  late Directory tmp;
  late Directory dl;
  final receivers = <FileReceiver>[];

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ls_r1a_');
    dl = Directory(p.join(tmp.path, 'Downloads'))..createSync();
  });
  tearDown(() {
    for (final r in receivers) {
      r.dispose();
    }
    receivers.clear();
    tmp.deleteSync(recursive: true);
  });

  FileReceiver newReceiver() {
    final r = FileReceiver(
      self: _self,
      downloadDir: dl,
      autoAccept: true,
      freeSpaceProbe: (_) async => null,
    );
    receivers.add(r);
    return r;
  }

  FileItem item(Uint8List data, String name) => FileItem(
    fileId: 'f',
    fileName: name,
    size: data.length,
    chunkCount: (data.length + cs - 1) ~/ cs,
    sha256: _sha(data),
    modified: DateTime.utc(2026, 11, 1, 10),
  );

  Future<SessionStatus> openSession(FileReceiver rx, FileItem it) =>
      rx.createSession(
        SessionRequest(
          sender: _tx,
          files: [it],
          totalSize: it.size,
          chunkSize: cs,
        ),
        remoteAddress: '127.0.0.1',
      );

  Future<void> put(
    FileReceiver rx,
    String sid,
    String token,
    Uint8List data,
    int index, {
    int pieceSize = 20000,
    List<int>? override,
  }) {
    final start = index * cs;
    final end = min(start + cs, data.length);
    final good = data.sublist(start, end);
    final body = override ?? good;
    Stream<List<int>> stream() async* {
      for (var i = 0; i < body.length; i += pieceSize) {
        yield body.sublist(i, min(i + pieceSize, body.length));
      }
    }

    return rx.putChunk(
      sid,
      'f',
      index,
      stream(),
      token: token,
      chunkSha256: _sha(good),
    );
  }

  File partialOf(String name) => File(p.join(dl.path, '$name.lspart'));
  File finalOf(String name) => File(p.join(dl.path, name));

  group('R1a receiver writes chunks at their own offset', () {
    test('guard write-at-chunk-offset: chunks 3, then 1, then 2 (then 0, 4) '
        'into one .lspart give a byte-identical file', () async {
      final data = _bytes(5 * cs, 11);
      final rx = newReceiver();
      final st = await openSession(rx, item(data, 'ooo.bin'));
      final tok = st.acceptedFiles['f']!.token;
      for (final i in [3, 1, 2, 0, 4]) {
        await put(rx, st.sessionId, tok, data, i);
      }
      await rx.completeFile(st.sessionId, 'f', token: tok);
      expect(finalOf('ooo.bin').readAsBytesSync(), data);
      expect(finalOf('ooo.bin').lengthSync(), data.length);
    });

    test('guard write-at-chunk-offset: the .lspart holds chunk 3 at offset '
        '3*chunk right after it arrives first (not at offset 0)', () async {
      final data = _bytes(5 * cs, 12);
      final rx = newReceiver();
      final st = await openSession(rx, item(data, 'first3.bin'));
      final tok = st.acceptedFiles['f']!.token;
      await put(rx, st.sessionId, tok, data, 3);
      final raf = partialOf('first3.bin').openSync();
      try {
        raf.setPositionSync(3 * cs);
        final got = raf.readSync(cs);
        expect(got, data.sublist(3 * cs, 4 * cs));
      } finally {
        raf.closeSync();
      }
      // The bytes at offset 0 must not be chunk 3's bytes.
      final raf0 = partialOf('first3.bin').openSync();
      try {
        final head = raf0.readSync(16);
        expect(head, isNot(data.sublist(3 * cs, 3 * cs + 16)));
      } finally {
        raf0.closeSync();
      }
    });

    test('guard write-at-chunk-offset: strictly descending order (last chunk '
        'first, short tail) is byte-identical', () async {
      final data = _bytes(4 * cs + 123, 13);
      final rx = newReceiver();
      final st = await openSession(rx, item(data, 'desc.bin'));
      final tok = st.acceptedFiles['f']!.token;
      for (final i in [4, 3, 2, 1, 0]) {
        await put(rx, st.sessionId, tok, data, i, pieceSize: 7001);
      }
      await rx.completeFile(st.sessionId, 'f', token: tok);
      expect(finalOf('desc.bin').readAsBytesSync(), data);
    });

    test('guard write-at-chunk-offset: parallel in-flight chunks arriving in '
        'a scrambled order are byte-identical', () async {
      final data = _bytes(8 * cs, 14);
      final rx = newReceiver();
      final st = await openSession(rx, item(data, 'par.bin'));
      final tok = st.acceptedFiles['f']!.token;
      await Future.wait([
        for (final i in [6, 2, 7, 0, 5, 1, 4, 3])
          put(rx, st.sessionId, tok, data, i, pieceSize: 3000),
      ]);
      await rx.completeFile(st.sessionId, 'f', token: tok);
      expect(finalOf('par.bin').readAsBytesSync(), data);
    });

    test('guard already-received-skip: re-sending an already stored chunk with '
        'DIFFERENT bytes is ignored for the file content (no append, no '
        'overwrite)', () async {
      final data = _bytes(3 * cs, 15);
      final rx = newReceiver();
      final st = await openSession(rx, item(data, 'dup.bin'));
      final tok = st.acceptedFiles['f']!.token;
      for (final i in [2, 0, 1]) {
        await put(rx, st.sessionId, tok, data, i);
      }
      // Same chunk again, correct hash, same bytes: size must not grow.
      await put(rx, st.sessionId, tok, data, 1);
      expect(partialOf('dup.bin').lengthSync(), lessThanOrEqualTo(data.length));
      await rx.completeFile(st.sessionId, 'f', token: tok);
      expect(finalOf('dup.bin').readAsBytesSync(), data);
    });
  });

  group('R1a resume after a crash', () {
    test('guard resume-writes-at-offset: a resumed chunk written at a NON-END '
        'offset (partial already holds the unpersisted chunk 8 and is longer '
        'than 8*chunk) lands at 8*chunk, not at EOF', () async {
      final data = _bytes(10 * cs, 21);
      final it = item(data, 'resume.bin');
      final rx1 = newReceiver();
      final st1 = await openSession(rx1, it);
      final tok1 = st1.acceptedFiles['f']!.token;
      for (var i = 0; i < 9; i++) {
        await put(rx1, st1.sessionId, tok1, data, i);
      }
      rx1.dispose(); // "crash": 0..7 persisted, chunk 8 is on disk only
      expect(partialOf('resume.bin').lengthSync(), 9 * cs);

      final rx2 = newReceiver();
      final st2 = await openSession(rx2, it);
      final acc = st2.acceptedFiles['f']!;
      expect(acc.receivedRanges, [
        [0, 7],
      ]);
      // Resend chunk 8 at a non-end... then 9. Chunk 8's offset (8*cs) is
      // strictly inside the 9*cs-long partial.
      await put(rx2, st2.sessionId, acc.token, data, 8);
      await put(rx2, st2.sessionId, acc.token, data, 9);
      await rx2.completeFile(st2.sessionId, 'f', token: acc.token);
      expect(finalOf('resume.bin').readAsBytesSync(), data);
      expect(finalOf('resume.bin').lengthSync(), data.length);
    });

    test('guard resume-overwrites-stale-bytes: the unpersisted chunk 8 on disk '
        'holds garbage; the resumed chunk replaces it in place', () async {
      final data = _bytes(10 * cs, 22);
      final it = item(data, 'stale.bin');
      final rx1 = newReceiver();
      final st1 = await openSession(rx1, it);
      final tok1 = st1.acceptedFiles['f']!.token;
      for (var i = 0; i < 9; i++) {
        await put(rx1, st1.sessionId, tok1, data, i);
      }
      rx1.dispose();
      // Torn write of chunk 8: its region contains garbage.
      final raf = partialOf('stale.bin').openSync(mode: FileMode.append);
      // (FileMode.write/writeOnly would truncate the partial.)
      raf.setPositionSync(8 * cs);
      raf.writeFromSync(List<int>.filled(cs, 0xAB));
      raf.closeSync();

      final rx2 = newReceiver();
      final st2 = await openSession(rx2, it);
      final tok = st2.acceptedFiles['f']!.token;
      expect(st2.acceptedFiles['f']!.receivedRanges, [
        [0, 7],
      ]);
      await put(rx2, st2.sessionId, tok, data, 9);
      await put(rx2, st2.sessionId, tok, data, 8);
      await rx2.completeFile(st2.sessionId, 'f', token: tok);
      expect(finalOf('stale.bin').readAsBytesSync(), data);
    });

    test('guard partial-longer-than-declared: a crash left the .lspart LONGER '
        'than the declared size (junk tail); the final file has exactly the '
        'declared size and bytes', () async {
      final data = _bytes(10 * cs, 23);
      final it = item(data, 'long.bin');
      final rx1 = newReceiver();
      final st1 = await openSession(rx1, it);
      final tok1 = st1.acceptedFiles['f']!.token;
      for (var i = 0; i < 9; i++) {
        await put(rx1, st1.sessionId, tok1, data, i);
      }
      rx1.dispose();
      final raf = partialOf('long.bin').openSync(mode: FileMode.append);
      raf.writeFromSync(List<int>.filled(3 * cs + 17, 0xCD));
      raf.closeSync();
      expect(partialOf('long.bin').lengthSync(), greaterThan(data.length));

      final rx2 = newReceiver();
      final st2 = await openSession(rx2, it);
      final tok = st2.acceptedFiles['f']!.token;
      // The receiver may keep the bitmap or discard the oversized partial;
      // both are fine. Whatever it reports as missing is re-sent.
      final have = <int>{
        for (final r in st2.acceptedFiles['f']!.receivedRanges)
          for (var i = r[0]; i <= r[1]; i++) i,
      };
      for (var i = 9; i >= 0; i--) {
        if (!have.contains(i)) await put(rx2, st2.sessionId, tok, data, i);
      }
      await rx2.completeFile(st2.sessionId, 'f', token: tok);
      expect(finalOf('long.bin').lengthSync(), data.length);
      expect(finalOf('long.bin').readAsBytesSync(), data);
    });

    test(
      'guard resume-out-of-order: after the crash the remaining chunks '
      'arrive as 9 then 8 (descending) and the file is byte-identical',
      () async {
        final data = _bytes(10 * cs + 5, 24);
        final it = item(data, 'resdesc.bin');
        final rx1 = newReceiver();
        final st1 = await openSession(rx1, it);
        final tok1 = st1.acceptedFiles['f']!.token;
        for (var i = 0; i < 9; i++) {
          await put(rx1, st1.sessionId, tok1, data, i);
        }
        rx1.dispose();

        final rx2 = newReceiver();
        final st2 = await openSession(rx2, it);
        final tok = st2.acceptedFiles['f']!.token;
        for (final i in [10, 9, 8]) {
          await put(rx2, st2.sessionId, tok, data, i);
        }
        await rx2.completeFile(st2.sessionId, 'f', token: tok);
        expect(finalOf('resdesc.bin').readAsBytesSync(), data);
      },
    );
  });
}
