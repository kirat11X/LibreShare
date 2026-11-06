// Verifier tests V6 / V7 (survivors z2 and z3): setPinMode rolls the in-memory
// mode back when the save fails; overlapping settings saves are serialised.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/providers/settings_provider.dart';
import 'package:libreshare_core/libreshare_core.dart';

import 'helpers/d1b_helpers.dart';
import 'helpers/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('V6 setPinMode: when the save fails the error is thrown and the in-memory mode is NOT left changed', () async {
    final h = await AppHarness.create();
    addTearDown(() => h.dispose());
    final slot = Directory(pj(h.supportDir.path, 'app_settings.json.tmp'))
      ..createSync(recursive: true);
    File(pj(slot.path, 'keep')).writeAsStringSync('x');
    final n = h.container.read(settingsProvider.notifier);
    expect(h.container.read(settingsProvider).pinMode, PinMode.off);
    await expectLater(n.setPinMode(PinMode.fixed), throwsA(anything));
    expect(
      h.container.read(settingsProvider).pinMode,
      PinMode.off,
      reason: 'the mode must not stay Fixed in memory when it was not saved',
    );
  }, timeout: kSixtySeconds);

  test('V7 two settings saves started together both succeed and the last one wins on disk', () async {
    final h = await AppHarness.create();
    addTearDown(() => h.dispose());
    final n = h.container.read(settingsProvider.notifier);
    await Future.wait([
      n.setAlias('Alias-One'),
      n.setAlias('Alias-Two'),
      n.setPinMode(PinMode.window),
    ]);
    final json = jsonDecode(
      File(pj(h.supportDir.path, 'app_settings.json')).readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(json['alias'], 'Alias-Two');
    expect(json['pinMode'], 'window');
  }, timeout: kSixtySeconds);
}
