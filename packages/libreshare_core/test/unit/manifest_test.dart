import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:libreshare_core/src/model/device.dart';
import 'package:libreshare_core/src/model/session_models.dart';
import 'package:libreshare_core/src/protocol.dart';
import 'package:libreshare_core/src/transfer/chunker.dart';
import 'package:libreshare_core/src/transfer/hashing.dart';
import 'package:libreshare_core/src/transfer/manifest.dart';
import 'package:test/test.dart';

const _sender = DeviceInfo(
  deviceId: 'dev-1',
  alias: 'Sender',
  platform: 'linux',
);

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ls_manifest_');
  });
  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  File write(String name, List<int> bytes) =>
      File('${tmp.path}/$name')..writeAsBytesSync(bytes);

  String shaHex(List<int> b) => crypto.sha256.convert(b).toString();

  group('ManifestBuilder.build', () {
    test('fills every FileItem field for a single file', () async {
      final data = List<int>.generate(2500, (i) => i & 0xFF);
      final f = write('report.pdf', data);
      final items = await const ManifestBuilder(chunker: Chunker(1000))
          .build([f]);
      expect(items, hasLength(1));
      final it = items.single;
      expect(it.fileId, 'f1');
      expect(it.fileName, 'report.pdf');
      expect(it.relativePath, isNull);
      expect(it.size, 2500);
      expect(it.mime, 'application/pdf');
      expect(it.chunkCount, 3);
      expect(it.sha256, shaHex(data));
      expect(it.modified, isNotNull);
      expect(it.modified!.isUtc, isTrue);
      final delta = it.modified!.difference(f.lastModifiedSync().toUtc()).abs();
      expect(delta, lessThan(const Duration(seconds: 1)));
    });

    test('empty file: 0 chunks, empty-string sha256', () async {
      final f = write('empty.txt', const []);
      final it = (await const ManifestBuilder().build([f])).single;
      expect(it.size, 0);
      expect(it.chunkCount, 0);
      expect(it.sha256, kSha256Empty);
      expect(it.mime, 'text/plain');
    });

    test('sorts smallest first and numbers ids f1..fN in that order', () async {
      final big = write('big.bin', List.filled(500, 1));
      final small = write('small.bin', List.filled(5, 2));
      final empty = write('empty.bin', const []);
      final mid = write('mid.bin', List.filled(50, 3));
      final items = await const ManifestBuilder().build([
        big,
        small,
        empty,
        mid,
      ]);
      expect(items.map((e) => e.fileName), [
        'empty.bin',
        'small.bin',
        'mid.bin',
        'big.bin',
      ]);
      expect(items.map((e) => e.fileId), ['f1', 'f2', 'f3', 'f4']);
      expect(items.map((e) => e.size), [0, 5, 50, 500]);
    });

    test('equal sizes keep the caller order (stable sort)', () async {
      final b = write('b.bin', List.filled(10, 1));
      final a = write('a.bin', List.filled(10, 2));
      final c = write('c.bin', List.filled(10, 3));
      final items = await const ManifestBuilder().build([b, a, c]);
      expect(items.map((e) => e.fileName), ['b.bin', 'a.bin', 'c.bin']);
    });

    test('buildEntries pairs each item with its source file', () async {
      final big = write('big.bin', List.filled(500, 1));
      final small = write('small.bin', List.filled(5, 2));
      final entries = await const ManifestBuilder().buildEntries([big, small]);
      expect(entries.map((e) => e.item.fileId), ['f1', 'f2']);
      expect(entries[0].file.path, small.path);
      expect(entries[1].file.path, big.path);
    });

    test('unknown extension falls back to application/octet-stream', () async {
      final f = write('data.zzzunknown', [1, 2, 3]);
      final it = (await const ManifestBuilder().build([f])).single;
      expect(it.mime, 'application/octet-stream');
    });

    test('mime comes from the extension', () async {
      final png = write('a.png', [1]);
      final txt = write('b.txt', [1, 2]);
      final items = await const ManifestBuilder().build([png, txt]);
      expect(items.firstWhere((e) => e.fileName == 'a.png').mime, 'image/png');
      expect(items.firstWhere((e) => e.fileName == 'b.txt').mime, 'text/plain');
    });

    test('fileName is only the basename (no directory components)', () async {
      final dir = await Directory('${tmp.path}/sub/dir')
          .create(recursive: true);
      final f = File('${dir.path}/inner.txt')..writeAsStringSync('x');
      final it = (await const ManifestBuilder().build([f])).single;
      expect(it.fileName, 'inner.txt');
      expect(it.relativePath, isNull);
    });

    test('sha256 is null above the hashing limit (spec 4.3)', () async {
      final f = write('over.bin', List.filled(20, 7));
      final items = await const ManifestBuilder(
        chunker: Chunker(8),
        maxHashedSize: 19,
      ).build([f]);
      expect(items.single.sha256, isNull);
      expect(items.single.chunkCount, 3);
    });

    test('sha256 is present exactly at the hashing limit', () async {
      final data = List.filled(19, 7);
      final f = write('at.bin', data);
      final it = (await const ManifestBuilder(maxHashedSize: 19).build([f]))
          .single;
      expect(it.sha256, shaHex(data));
    });

    test(
      'default hashing limit is 2 GiB: sparse 2 GiB + 1 -> null sha',
      () async {
        expect(kManifestHashLimit, 2 * 1024 * 1024 * 1024);
        const size = 2 * 1024 * 1024 * 1024 + 1;
        final f = File('${tmp.path}/sparse.bin');
        final raf = await f.open(mode: FileMode.write);
        await raf.truncate(size);
        await raf.close();
        final it = (await const ManifestBuilder().build([f])).single;
        expect(it.size, size);
        expect(it.sha256, isNull);
        expect(it.chunkCount, 513); // ceil((2 GiB + 1) / 4 MiB)
      },
    );

    test(
      'control characters and separators are stripped from fileName',
      () async {
        final f = write('bad\nna\tme\u0007.txt', [1]);
        final it = (await const ManifestBuilder().build([f])).single;
        expect(it.fileName, isNot(contains('\n')));
        expect(it.fileName, isNot(contains('\t')));
        expect(
          it.fileName.codeUnits.every((c) => c >= 0x20 && c != 0x7F),
          isTrue,
        );
        expect(it.fileName, endsWith('.txt'));
      },
    );

    test('missing file throws FileSystemException', () async {
      await expectLater(
        const ManifestBuilder().build([File('${tmp.path}/nope.bin')]),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('a directory is rejected', () async {
      await expectLater(
        const ManifestBuilder().build([File(tmp.path)]),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('empty input yields an empty manifest', () async {
      expect(await const ManifestBuilder().build(const []), isEmpty);
    });

    test('too many files is rejected', () async {
      final f = write('x.bin', [1]);
      await expectLater(
        const ManifestBuilder().build(List.filled(kMaxFilesPerSession + 1, f)),
        throwsArgumentError,
      );
    });
  });

  group('ManifestBuilder.sanitizeDisplayName', () {
    test('plain names are unchanged', () {
      expect(
        ManifestBuilder.sanitizeDisplayName('Report 2026.pdf'),
        'Report 2026.pdf',
      );
      expect(ManifestBuilder.sanitizeDisplayName('日本語.txt'), '日本語.txt');
    });

    test('control chars and path separators are replaced', () {
      expect(ManifestBuilder.sanitizeDisplayName('a/b\\c.txt'), 'a_b_c.txt');
      expect(ManifestBuilder.sanitizeDisplayName('a\u0000b\u001Fc'), 'a_b_c');
    });

    test('empty or dot-only names get a placeholder', () {
      expect(ManifestBuilder.sanitizeDisplayName(''), 'file');
      expect(ManifestBuilder.sanitizeDisplayName('..'), 'file');
      expect(ManifestBuilder.sanitizeDisplayName('  '), 'file');
    });
  });

  group('ManifestBuilder.buildSessionRequest', () {
    test('totalSize is the sum, chunkSize comes from the chunker', () async {
      final a = write('a.bin', List.filled(100, 1));
      final b = write('b.bin', List.filled(250, 2));
      final z = write('z.bin', const []);
      const builder = ManifestBuilder(chunker: Chunker(64));
      final items = await builder.build([a, b, z]);
      final req = builder.buildSessionRequest(
        sender: _sender,
        files: items,
        pin: '123456',
      );
      expect(req.totalSize, 350);
      expect(req.chunkSize, 64);
      expect(req.pin, '123456');
      expect(req.sender.deviceId, 'dev-1');
      expect(req.files, hasLength(3));
      expect(req.tunnelOffer, isNull);
    });

    test(
      'defaults to the protocol chunk size and survives a JSON round trip',
      () async {
        final a = write('a.bin', List.filled(10, 1));
        const builder = ManifestBuilder();
        final items = await builder.build([a]);
        final req = builder.buildSessionRequest(sender: _sender, files: items);
        expect(req.chunkSize, kChunkSize);
        expect(req.pin, isNull);
        final back = SessionRequest.fromJson(
          (jsonDecode(jsonEncode(req.toJson())) as Map).cast<String, Object?>(),
        );
        expect(back.totalSize, 10);
        expect(back.files.single.fileId, 'f1');
        expect(back.files.single.sha256, items.single.sha256);
        expect(back.files.single.chunkCount, 1);
      },
    );
  });
}
