import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:libreshare_core/src/transfer/chunker.dart';
import 'package:libreshare_core/src/transfer/hashing.dart';
import 'package:test/test.dart';

const _emptyHex =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
const _abcHex =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

/// Deterministic non-trivial pattern of [n] bytes.
Uint8List pattern(int n) {
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    b[i] = (i * 31 + (i >> 8) * 7 + 13) & 0xFF;
  }
  return b;
}

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ls_hashing_');
  });
  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  File write(String name, List<int> bytes) =>
      File('${tmp.path}/$name')..writeAsBytesSync(bytes);

  group('sha256OfBytes', () {
    test('known vectors', () {
      expect(sha256OfBytes(const []), _emptyHex);
      expect(sha256OfBytes(utf8.encode('abc')), _abcHex);
      expect(kSha256Empty, _emptyHex);
    });

    test('is lowercase 64-hex', () {
      final h = sha256OfBytes(pattern(1000));
      expect(h, matches(RegExp(r'^[0-9a-f]{64}$')));
    });
  });

  group('sha256OfStream', () {
    test('empty stream', () async {
      expect(await sha256OfStream(const Stream<List<int>>.empty()), _emptyHex);
    });

    test('"abc" in one piece and in single-byte pieces', () async {
      final bytes = utf8.encode('abc');
      expect(await sha256OfStream(Stream.value(bytes)), _abcHex);
      expect(
        await sha256OfStream(Stream.fromIterable(bytes.map((b) => [b]))),
        _abcHex,
      );
    });

    test('uneven chunk boundaries do not change the digest', () async {
      final data = pattern(300000);
      final expected = crypto.sha256.convert(data).toString();
      final pieces = <List<int>>[];
      var off = 0;
      var step = 1;
      while (off < data.length) {
        final end = (off + step).clamp(0, data.length);
        pieces.add(data.sublist(off, end));
        off = end;
        step = step * 3 + 1;
      }
      expect(await sha256OfStream(Stream.fromIterable(pieces)), expected);
    });

    test('propagates stream errors', () async {
      final s = Stream<List<int>>.multi((c) {
        c.add([1, 2, 3]);
        c.addError(StateError('boom'));
        c.close();
      });
      await expectLater(sha256OfStream(s), throwsStateError);
    });
  });

  group('sha256OfFile', () {
    test('empty file', () async {
      expect(await sha256OfFile(write('empty', const [])), _emptyHex);
    });

    test('"abc"', () async {
      expect(await sha256OfFile(write('abc', utf8.encode('abc'))), _abcHex);
    });

    test('10 MiB pattern equals package:crypto', () async {
      final data = pattern(10 * 1024 * 1024);
      final f = write('ten', data);
      final expected = crypto.sha256.convert(data).toString();
      expect(await sha256OfFile(f), expected);
    });

    test('missing file throws FileSystemException', () async {
      await expectLater(
        sha256OfFile(File('${tmp.path}/nope')),
        throwsA(isA<FileSystemException>()),
      );
    });

    test(
      'runs off the calling isolate (event loop stays responsive)',
      () async {
        // 64 MiB of zeros: hashing takes long enough for a timer to fire.
        final f = File('${tmp.path}/zeros');
        final raf = await f.open(mode: FileMode.write);
        await raf.truncate(64 * 1024 * 1024);
        await raf.close();
        var ticks = 0;
        final timer = Stream<void>.periodic(const Duration(milliseconds: 5))
            .listen((_) => ticks++);
        final h = await sha256OfFile(f);
        await timer.cancel();
        expect(h, matches(RegExp(r'^[0-9a-f]{64}$')));
        expect(ticks, greaterThan(0));
      },
    );
  });

  group('sha256OfChunk', () {
    test('hashes exactly the chunk range', () async {
      const chunker = Chunker(1000);
      final data = pattern(2500);
      final f = write('c', data);
      for (final r in chunker.ranges(data.length)) {
        final expected = crypto.sha256
            .convert(data.sublist(r.start, r.end))
            .toString();
        expect(await sha256OfChunk(f, r), expected);
      }
    });

    test('large chunks (isolate path) match package:crypto', () async {
      const chunker = Chunker(1024 * 1024);
      final data = pattern(2 * 1024 * 1024 + 123);
      final f = write('big_chunks', data);
      for (final r in chunker.ranges(data.length)) {
        final expected = crypto.sha256
            .convert(data.sublist(r.start, r.end))
            .toString();
        expect(await sha256OfChunk(f, r), expected);
      }
    });

    test('throws when the file is shorter than the range', () async {
      const chunker = Chunker(1000);
      final f = write('short', pattern(1500));
      final r = chunker.range(2500, 2); // [2000,2500) but file has 1500 bytes
      await expectLater(
        sha256OfChunk(f, r),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
}
