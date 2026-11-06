// FileReceiveSettingsStore / ReceiveSettings JSON (design 01 s1.5, s1.6):
// round trip, atomic write, corrupt file -> defaults.
import 'dart:convert';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late FileReceiveSettingsStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ls_receive_store_');
    store = FileReceiveSettingsStore(Directory(p.join(dir.path, 'nested')));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  final full = ReceivePersisted(
    settings: const ReceiveSettings(
      defaultMode: ReceiveFor(Duration(minutes: 90)),
      visibility: ReceiveVisibility.contacts,
      autostart: true,
      startHidden: false,
      androidWindow: Duration(hours: 12),
      receiveOnBoot: true,
    ),
    runtime: ReceiveRuntime(
      state: ReceiveRuntimeState.paused,
      pauseReason: PauseReason.noNetwork,
      offReason: OffReason.expired,
      mode: const ReceiveFor(Duration(seconds: 600)),
      until: DateTime.utc(2026, 11, 3, 18, 20),
      cleanStop: false,
    ),
  );

  test('missing file -> defaults', () async {
    final d = await store.load();
    expect(d, const ReceivePersisted());
    expect(d.settings.defaultMode, const ReceiveAlways());
    expect(d.runtime.state, ReceiveRuntimeState.off);
    expect(d.runtime.offReason, OffReason.neverEnabled);
    expect(d.settings.androidWindow, const Duration(hours: 6));
  });

  test('round trip, creating the directory', () async {
    await store.save(full);
    expect(await store.load(), full);
    expect(store.file.existsSync(), isTrue);
  });

  test('file format: v1 with the documented members', () async {
    await store.save(full);
    final j = jsonDecode(store.file.readAsStringSync()) as Map<String, Object?>;
    expect(j['v'], 1);
    expect(
      j.keys,
      containsAll([
        'defaultMode',
        'visibility',
        'autostart',
        'startHidden',
        'androidWindowMinutes',
        'receiveOnBoot',
        'runtime',
      ]),
    );
    expect(j['androidWindowMinutes'], 720);
    expect((j['runtime']! as Map)['cleanStop'], false);
    expect((j['runtime']! as Map)['until'], '2026-11-03T18:20:00.000Z');
  });

  test(
    'atomic write: no temp file is left and the old file survives a crash',
    () async {
      await store.save(full);
      await store.save(const ReceivePersisted());
      final names = store.directory
          .listSync()
          .map((e) => p.basename(e.path))
          .toList();
      expect(names, ['receive_settings.json']);

      // A crash between "write tmp" and "rename" leaves a stale .tmp: the real
      // file is untouched and the next save replaces the tmp.
      await store.save(full);
      File('${store.file.path}.tmp').writeAsStringSync('{"half');
      expect(await store.load(), full);
      await store.save(const ReceivePersisted());
      expect(await store.load(), const ReceivePersisted());
      expect(File('${store.file.path}.tmp').existsSync(), isFalse);
    },
  );

  test('concurrent saves are applied in order and never interleave', () async {
    final futures = [
      for (var i = 1; i <= 20; i++)
        store.save(
          ReceivePersisted(
            settings: ReceiveSettings(androidWindow: Duration(minutes: i)),
          ),
        ),
    ];
    await Future.wait(futures);
    expect(
      (await store.load()).settings.androidWindow,
      const Duration(minutes: 20),
    );
  });

  test('a failed save does not poison later saves', () async {
    // A directory where the file should be makes the rename fail.
    Directory(store.file.path).createSync(recursive: true);
    await expectLater(store.save(full), throwsA(isA<FileSystemException>()));
    Directory(store.file.path).deleteSync();
    await store.save(full);
    expect(await store.load(), full);
  });

  test('corrupt or hostile files -> defaults, never an exception', () async {
    store.directory.createSync(recursive: true);
    for (final content in <String>[
      '',
      '{',
      'not json',
      '[]',
      'null',
      '"str"',
      '\u0000\u0001',
      '{"v":1,"runtime":"x","defaultMode":5,"visibility":[],"androidWindowMinutes":"6"}',
    ]) {
      store.file.writeAsStringSync(content);
      expect(await store.load(), const ReceivePersisted(), reason: content);
    }
    store.file.writeAsBytesSync([0xff, 0xfe, 0x00]);
    expect(await store.load(), const ReceivePersisted());
  });

  test('member by member: wrong types fall back, good members stay', () async {
    store.directory.createSync(recursive: true);
    store.file.writeAsStringSync(
      jsonEncode({
        'v': 7, // a newer writer
        'unknownMember': {'x': 1},
        'defaultMode': {'kind': 'for', 'minutes': 10},
        'visibility': 'martians',
        'autostart': 'yes',
        'startHidden': false,
        'androidWindowMinutes': -5,
        'receiveOnBoot': true,
        'runtime': {
          'state': 'on',
          'mode': {'kind': 'always'},
          'until': 'not a date',
          'cleanStop': 'maybe',
          'pauseReason': 'gremlins',
        },
      }),
    );
    final d = await store.load();
    expect(d.settings.defaultMode, const ReceiveFor(Duration(minutes: 10)));
    expect(d.settings.visibility, ReceiveVisibility.everyone);
    expect(d.settings.autostart, isFalse);
    expect(d.settings.startHidden, isFalse);
    expect(d.settings.androidWindow, const Duration(hours: 6));
    expect(d.settings.receiveOnBoot, isTrue);
    expect(d.runtime.state, ReceiveRuntimeState.on);
    expect(d.runtime.mode, const ReceiveAlways());
    expect(d.runtime.until, isNull);
    expect(d.runtime.cleanStop, isTrue, reason: 'unknown => treated as clean');
    expect(d.runtime.pauseReason, isNull);
  });

  test('a stored defaultMode of Off or nonsense becomes Always', () {
    for (final mode in <Object?>[
      {'kind': 'off'},
      {'kind': 'for', 'minutes': 0},
      {'kind': 'for', 'seconds': -1},
      {'kind': 'warp'},
      'always',
      null,
    ]) {
      expect(
        ReceiveSettings.fromJson({'defaultMode': mode}).defaultMode,
        const ReceiveAlways(),
        reason: '$mode',
      );
    }
  });

  test('modeToJson / modeFromJson round trip', () {
    for (final m in <ReceiveMode>[
      const ReceiveOff(),
      const ReceiveAlways(),
      const ReceiveFor(Duration(minutes: 10)),
      const ReceiveFor(Duration(seconds: 90)),
    ]) {
      expect(modeFromJson(modeToJson(m)), m);
    }
  });

  test('InMemoryReceiveSettingsStore keeps the last save', () async {
    final s = InMemoryReceiveSettingsStore();
    expect(await s.load(), const ReceivePersisted());
    await s.save(full);
    expect(await s.load(), full);
    expect(s.saves, 1);
  });
}
