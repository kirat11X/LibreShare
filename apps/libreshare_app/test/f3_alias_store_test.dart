// F3 defect 5: a name the user typed in Settings always wins over the
// device-derived default; the default only seeds a fresh install. These pin
// existing behaviour (green today) so the new device-name seam cannot break it.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/services/app_settings_store.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('ls_f3_alias_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('a fresh install takes the device-derived default', () async {
    final s = await AppSettingsStore(dir).loadOrCreate(defaultAlias: 'Pixel 8');
    expect(s.alias, 'Pixel 8');
  });

  test('a saved name beats a different default on the next start', () async {
    final store = AppSettingsStore(dir);
    final first = await store.loadOrCreate(defaultAlias: 'Pixel 8');
    await store.save(first.copyWith(alias: "Mira's phone"));
    final again = await AppSettingsStore(dir)
        .loadOrCreate(defaultAlias: 'Galaxy S24');
    expect(again.alias, "Mira's phone");
    expect(again.deviceId, first.deviceId);
  });

  test('the default is used again only when the saved name is blank', () async {
    final store = AppSettingsStore(dir);
    final first = await store.loadOrCreate(defaultAlias: 'Pixel 8');
    await store.save(first.copyWith(alias: '   '));
    final again = await AppSettingsStore(dir)
        .loadOrCreate(defaultAlias: 'Galaxy S24');
    expect(again.alias, 'Galaxy S24');
  });
}
