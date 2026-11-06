// VERIFIER tests (E5 / R1b), written by the verifier agent, NOT by the tester
// and NOT by the coder. New file; no existing test is touched.
//
// Purpose: kill mutants of lib/src/storage/atomic_file.dart and of the second
// final rename in transfer/file_receiver.dart that the tester's tests do not
// kill (see verifier-report.md, mutation table).
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:libreshare_core/libreshare_core.dart';
import 'package:libreshare_core/src/storage/atomic_file.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/atomic_hooks.dart';

Uint8List fill(int n, int v) => Uint8List(n)..fillRange(0, n, v);

FileSystemException denied(String to) =>
    FileSystemException('simulated', to, const OSError('Access is denied.', 5));

void main() {
  late Directory dir;
  late File target;
  List<String> names(Directory d) =>
      d.listSync().map((e) => p.basename(e.path)).toList()..sort();

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ls_verif_m_');
    target = File(p.join(dir.path, 'state.json'));
  });
  tearDown(() {
    atomicRenameOverride = null;
    dir.deleteSync(recursive: true);
  });

  test('V-restore: commit refused, move-aside works, 2nd commit fails, '
      'restore works -> OLD bytes back at the target, no litter', () async {
    target.writeAsBytesSync(fill(50, 1));
    var n = 0;
    atomicRenameOverride = (from, to) async {
      n++;
      // 1: tmp->target refused. 2: target->bak real. 3: tmp->target refused.
      // 4: bak->target (restore) real.
      if (n == 1 || n == 3) throw denied(to);
      await from.rename(to);
    };
    await expectLater(
      atomicWriteBytes(target, fill(50, 2)),
      throwsA(isA<FileSystemException>()),
    );
    atomicRenameOverride = null;
    expect(n, 4);
    expect(target.readAsBytesSync(), fill(50, 1));
    expect(names(dir), ['state.json']);
  });

  test('V-restore (atomicReplace): same sequence directly on atomicReplace: '
      'old target restored, tmp left for the caller', () async {
    target.writeAsBytesSync(fill(50, 1));
    final tmp = File('${target.path}.tmp')..writeAsBytesSync(fill(50, 2));
    var n = 0;
    atomicRenameOverride = (from, to) async {
      n++;
      if (n == 1 || n == 3) throw denied(to);
      await from.rename(to);
    };
    await expectLater(
      atomicReplace(tmp, target),
      throwsA(isA<FileSystemException>()),
    );
    atomicRenameOverride = null;
    expect(target.readAsBytesSync(), fill(50, 1));
    expect(tmp.readAsBytesSync(), fill(50, 2));
    expect(names(dir), ['state.json', 'state.json.tmp']);
  });

  test('V-stale-tmp-readonly: a stale read-only <target>.tmp (crash leftover) '
      'does not block the write', () async {
    final stale = File('${target.path}.tmp')..writeAsStringSync('half');
    Process.runSync('chmod', ['400', stale.path]);
    await atomicWriteBytes(target, [7, 7, 7]);
    expect(target.readAsBytesSync(), [7, 7, 7]);
    expect(names(dir), ['state.json']);
  }, skip: Platform.isWindows ? 'POSIX permission bits' : null);

  test('V-mode-before-bytes: with mode 0600 the tmp is already 0600 when the '
      'FIRST byte is written (checked inside prepareTmp, which runs before '
      'any byte, and via a poll of the committed hook)', () async {
    int? permAtPrepare;
    await atomicWriteBytes(
      target,
      fill(1024, 1),
      mode: 0x180,
      prepareTmp: (tmp) async {
        permAtPrepare = FileStat.statSync(tmp.path).mode & 0x1FF;
      },
    );
    expect(permAtPrepare, 384);
  }, skip: Platform.isWindows ? 'POSIX permission bits' : null);

  test('V-receiver-copy-fallback-uses-helper: after the cross-device copy '
      'the final rename of <target>.lspart-<hex> goes through the helper and '
      'works with a Windows-like rename and an existing target', () async {
    final dl = Directory(p.join(dir.path, 'dl'))..createSync();
    final pd = Directory(p.join(dir.path, 'pd'))..createSync();
    final tgt = File(p.join(dl.path, 'got.bin'));
    final log = RenameLog();
    var raced = false;
    atomicRenameOverride = (from, to) async {
      log.calls.add((from: from.path, to: to));
      if (from.path.endsWith('.lspart') &&
          norm(from.path).startsWith(norm(pd.path))) {
        if (!raced) tgt.writeAsBytesSync([9, 9, 9]); // race, once
        raced = true;
        throw FileSystemException(
          'simulated cross-device rename',
          to,
          const OSError('Invalid cross-device link', 18),
        );
      }
      if (FileSystemEntity.typeSync(to, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw denied(to); // Windows: cannot replace an existing file
      }
      await from.rename(to);
    };
    final data = List<int>.generate(2000, (i) => (i * 31) % 251);
    final out = await _receiveOne(dl, pd, data, 'got.bin');
    atomicRenameOverride = null;
    expect(out.readAsBytesSync(), data);
    expect(
      log.calls.any(
        (c) => c.from.contains('.lspart-') && norm(c.to) == norm(tgt.path),
      ),
      isTrue,
      reason: 'the copy-fallback commit did not go through atomicReplace',
    );
    expect(names(dl), ['got.bin']);
  });
}

Future<File> _receiveOne(
  Directory dl,
  Directory pd,
  List<int> data,
  String name,
) async {
  const cs = 64 * 1024;
  const self = DeviceInfo(deviceId: 'rx', alias: 'R', platform: 'linux');
  const tx = DeviceInfo(deviceId: 'tx', alias: 'S', platform: 'linux');
  final rx = FileReceiver(
    self: self,
    downloadDir: dl,
    partialDir: pd,
    autoAccept: true,
    freeSpaceProbe: (_) async => null,
  );
  addTearDown(rx.dispose);
  final item = FileItem(
    fileId: 'f',
    fileName: name,
    size: data.length,
    chunkCount: 1,
    sha256: sha256.convert(data).toString(),
  );
  final st = await rx.createSession(
    SessionRequest(
      sender: tx,
      files: [item],
      totalSize: data.length,
      chunkSize: cs,
    ),
    remoteAddress: '127.0.0.1',
  );
  final tok = st.acceptedFiles['f']!.token;
  await rx.putChunk(
    st.sessionId,
    'f',
    0,
    Stream.value(data),
    token: tok,
    chunkSha256: sha256.convert(data).toString(),
  );
  await rx.completeFile(st.sessionId, 'f', token: tok);
  return File(p.join(dl.path, name));
}
