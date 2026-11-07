// E5 / R1b: resume_store, receive_settings_store, file_secret_store and the
// final move in file_receiver must all commit through the shared helper
// (lib/src/storage/atomic_file.dart). Proof by observation: a rename hook
// (`atomicRenameOverride`) sees the store's commit, and the stores survive a
// Windows-like rename that refuses to replace an existing file, or a rename
// that fails outright (OLD data intact, no tmp litter).
//
// Every test name starts with the guard it protects.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:libreshare_core/libreshare_core.dart';
import 'package:libreshare_core/src/storage/atomic_file.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/atomic_hooks.dart';

Uint8List b(List<int> v) => Uint8List.fromList(v);

void main() {
  late Directory dir;

  List<String> names(Directory d) =>
      d.listSync().map((e) => p.basename(e.path)).toList()..sort();

  setUp(() => dir = Directory.systemTemp.createTempSync('ls_atomic_ad_'));
  tearDown(() {
    atomicRenameOverride = null;
    dir.deleteSync(recursive: true);
  });

  group('ResumeStore sidecar', () {
    File partial() => File(p.join(dir.path, 'rx', 'm.mkv.lspart'));
    const chunk = 64 * 1024;

    Future<ResumeStore> open() => ResumeStore.open(
      partialFile: partial(),
      size: 10 * chunk,
      chunkSize: chunk,
      chunkCount: 10,
      sha256: 'ab' * 32,
      modified: DateTime.utc(2026, 10, 30, 10),
      clock: const SystemClock(),
      persistEvery: 1,
    );

    test('guard resume_store-uses-helper: persisting the sidecar commits '
        'through the shared rename', () async {
      final s = await open();
      final log = RenameLog();
      atomicRenameOverride = recordingRename(log);
      await s.markReceived(0);
      expect(
        log.sawDestination(ResumeStore.sidecarFor(partial()).path),
        isTrue,
      );
    });

    test('guard resume_store-replace-fallback: Windows-like rename, many '
        'persists: sidecar stays valid and current, no litter', () async {
      final s = await open();
      atomicRenameOverride = windowsLikeRename(RenameLog());
      await s.markReceived(0);
      await s.markReceived(1);
      await s.markReceived(5);
      atomicRenameOverride = null;
      final j = jsonDecode(
        ResumeStore.sidecarFor(partial()).readAsStringSync(),
      ) as Map<String, Object?>;
      expect(j['received'], [
        [0, 1],
        [5, 5],
      ]);
      expect(names(partial().parent), ['m.mkv.lspart.json']);
    });

    test('guard resume_store-cleanup: the rename fails -> persist throws, '
        'the OLD sidecar is intact, no .tmp litter', () async {
      final s = await open();
      await s.markReceived(0);
      final before = ResumeStore.sidecarFor(partial()).readAsStringSync();
      atomicRenameOverride = failingRename(RenameLog());
      await expectLater(s.markReceived(1), throwsA(isA<FileSystemException>()));
      atomicRenameOverride = null;
      expect(ResumeStore.sidecarFor(partial()).readAsStringSync(), before);
      expect(names(partial().parent), ['m.mkv.lspart.json']);
    });
  });

  group('FileReceiveSettingsStore', () {
    final persisted = ReceivePersisted(
      settings: const ReceiveSettings(autostart: true),
    );
    final other = ReceivePersisted(
      settings: const ReceiveSettings(
        defaultMode: ReceiveFor(Duration(minutes: 5)),
      ),
    );

    test('guard receive_settings-uses-helper: save commits through the '
        'shared rename', () async {
      final store = FileReceiveSettingsStore(dir);
      final log = RenameLog();
      atomicRenameOverride = recordingRename(log);
      await store.save(persisted);
      expect(log.sawDestination(store.file.path), isTrue);
    });

    test('guard receive_settings-replace-fallback: Windows-like rename, '
        'save twice: second value loads, no litter', () async {
      final store = FileReceiveSettingsStore(dir);
      atomicRenameOverride = windowsLikeRename(RenameLog());
      await store.save(persisted);
      await store.save(other);
      atomicRenameOverride = null;
      expect(await store.load(), other);
      expect(names(dir), ['receive_settings.json']);
    });

    test('guard receive_settings-cleanup: rename fails -> save throws, OLD '
        'settings still load, no .tmp litter', () async {
      final store = FileReceiveSettingsStore(dir);
      await store.save(persisted);
      atomicRenameOverride = failingRename(RenameLog());
      await expectLater(store.save(other), throwsA(isA<FileSystemException>()));
      atomicRenameOverride = null;
      expect(await store.load(), persisted);
      expect(names(dir), ['receive_settings.json']);
    });
  });

  group('FileSecretStore', () {
    final skipPerm = Platform.isWindows
        ? 'POSIX permission bits do not exist on Windows'
        : null;
    int perm(String path) => FileStat.statSync(path).mode & 0x1FF;

    test('guard secret_store-uses-helper: put commits through the shared '
        'rename', () async {
      final store = FileSecretStore(Directory(p.join(dir.path, 's')));
      final log = RenameLog();
      atomicRenameOverride = recordingRename(log);
      await store.put('pin', b([1, 2, 3]));
      expect(log.sawDestination(store.fileFor('pin').path), isTrue);
    });

    test('guard secret_store-replace-fallback+0600: Windows-like rename, '
        'put twice: new value reads back and the file is still 0600', () async {
      final store = FileSecretStore(Directory(p.join(dir.path, 's')));
      atomicRenameOverride = windowsLikeRename(RenameLog());
      await store.put('pin', b([1, 2, 3]));
      await store.put('pin', b([4, 5]));
      atomicRenameOverride = null;
      expect(await store.get('pin'), b([4, 5]));
      expect(perm(store.fileFor('pin').path), 384); // 0o600
      expect(perm(store.directory.path), 448); // 0o700
      expect(names(store.directory), [p.basename(store.fileFor('pin').path)]);
    }, skip: skipPerm);

    test('guard secret_store-0600-through-helper: the file written through '
        'the helper is 0600 even when the rename is observed/hooked', () async {
      final store = FileSecretStore(Directory(p.join(dir.path, 's')));
      final log = RenameLog();
      atomicRenameOverride = recordingRename(log);
      await store.put('k', b([9]));
      atomicRenameOverride = null;
      expect(log.sawDestination(store.fileFor('k').path), isTrue);
      expect(perm(store.fileFor('k').path), 384);
    }, skip: skipPerm);

    test('guard secret_store-cleanup: rename fails -> put throws '
        'SecretStoreException, OLD secret intact, no litter', () async {
      final store = FileSecretStore(Directory(p.join(dir.path, 's')));
      await store.put('pin', b([1, 2, 3]));
      atomicRenameOverride = failingRename(RenameLog());
      await expectLater(
        store.put('pin', b([7, 7])),
        throwsA(isA<SecretStoreException>()),
      );
      atomicRenameOverride = null;
      expect(await store.get('pin'), b([1, 2, 3]));
      expect(names(store.directory), [p.basename(store.fileFor('pin').path)]);
    });
  });

  group('FileReceiver final move', () {
    const cs = 64 * 1024;
    const self = DeviceInfo(deviceId: 'rx', alias: 'R', platform: 'linux');
    const tx = DeviceInfo(deviceId: 'tx', alias: 'S', platform: 'linux');

    Future<File> receiveOne(Directory dl, List<int> data) async {
      final rx = FileReceiver(
        self: self,
        downloadDir: dl,
        autoAccept: true,
        freeSpaceProbe: (_) async => null,
      );
      addTearDown(rx.dispose);
      final item = FileItem(
        fileId: 'f',
        fileName: 'got.bin',
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
      return File(p.join(dl.path, 'got.bin'));
    }

    test('guard receiver-final-move-uses-helper: the .lspart -> target move '
        'goes through the shared rename', () async {
      final dl = Directory(p.join(dir.path, 'dl'))..createSync();
      final log = RenameLog();
      atomicRenameOverride = recordingRename(log);
      final data = List<int>.generate(1000, (i) => i % 251);
      final out = await receiveOne(dl, data);
      atomicRenameOverride = null;
      expect(out.readAsBytesSync(), data);
      expect(log.sawDestination(out.path), isTrue);
    });

    test('guard receiver-final-move-windows: with a Windows-like rename the '
        'transfer still completes and leaves no .lspart', () async {
      final dl = Directory(p.join(dir.path, 'dl'))..createSync();
      atomicRenameOverride = windowsLikeRename(RenameLog());
      final data = List<int>.generate(777, (i) => (i * 7) % 256);
      final out = await receiveOne(dl, data);
      atomicRenameOverride = null;
      expect(out.readAsBytesSync(), data);
      expect(names(dl).where((n) => n.contains('.lspart')), isEmpty);
    });
  });
}
