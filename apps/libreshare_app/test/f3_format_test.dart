// F3 defect 11: one size formatter for the whole app, decimal units like the
// OS file manager. Convention (documented in docs/plans/f3-tests.md):
//   * 1 KB = 1000 B, 1 MB = 1000 KB, ... units B / KB / MB / GB / TB;
//   * bytes are whole numbers; every other unit shows two decimals below 10 and
//     one decimal from 10 up ("1.02 KB", "12.3 MB", "125.8 MB");
//   * a value that rounds up to 1000 moves to the next unit ("1.00 MB");
//   * negative sizes read as 0 B and never throw.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/providers/transfers_provider.dart';
import 'package:libreshare_app/services/file_picker_service.dart';
import 'package:libreshare_app/services/format.dart';

import 'helpers/f3_fakes.dart';
import 'helpers/harness.dart';

void main() {
  group('formatBytes: decimal convention', () {
    const cases = <int, String>{
      0: '0 B',
      1: '1 B',
      999: '999 B',
      1000: '1.00 KB',
      1023: '1.02 KB',
      1024: '1.02 KB',
      1500: '1.50 KB',
      9990: '9.99 KB',
      10000: '10.0 KB',
      301000: '301.0 KB',
      1000000: '1.00 MB',
      1048576: '1.05 MB',
      12345678: '12.3 MB',
      125829120: '125.8 MB',
      1000000000: '1.00 GB',
      5368709120: '5.37 GB',
      1000000000000: '1.00 TB',
    };
    for (final e in cases.entries) {
      test('${e.key} bytes is "${e.value}"', () {
        expect(formatBytes(e.key), e.value);
      });
    }

    test('120 MiB is no longer labelled "120 MB"', () {
      expect(formatBytes(120 * 1024 * 1024), isNot('120 MB'));
      expect(formatBytes(120 * 1024 * 1024), '125.8 MB');
    });

    test('a value that rounds to 1000 moves up a unit', () {
      expect(formatBytes(999999), '1.00 MB');
      expect(formatBytes(999999), isNot(contains('1000')));
      expect(formatBytes(999999999), '1.00 GB');
    });

    test('fractional input is accepted', () {
      expect(formatBytes(1500.0), '1.50 KB');
    });

    test('negative values read as 0 B and never throw', () {
      expect(formatBytes(-1), '0 B');
      expect(formatBytes(-125829120), '0 B');
      expect(formatBytes(-1e12), '0 B');
      expect(formatBytes(-0.5), '0 B');
    });

    test('speeds use the same formatter', () {
      expect(formatSpeed(1500000), '1.50 MB/s');
      expect(formatSpeed(512), '512 B/s');
      expect(formatSpeed(125829120), '125.8 MB/s');
    });
  });

  group('one formatter everywhere', () {
    test('no other file in lib/ divides by 1000/1024 or owns a size unit', () {
      final root = Directory('lib');
      expect(root.existsSync(), isTrue, reason: 'run from apps/libreshare_app');
      final offenders = <String>[];
      final divides = RegExp(
        r'/\s*(1000|1024)\b|\b(1000|1024)\s*\*\s*\d|<<\s*(10|20|30)\b',
      );
      final units = RegExp(r"'unit\.(kb|mb|gb|tb)'");
      for (final f in root.listSync(recursive: true).whereType<File>()) {
        final path = f.path;
        if (!path.endsWith('.dart')) continue;
        if (path.endsWith('services/format.dart')) continue;
        if (path.endsWith('l10n_strings.dart')) continue;
        final text = f.readAsStringSync();
        if (divides.hasMatch(text) || units.hasMatch(text)) offenders.add(path);
      }
      expect(offenders, isEmpty);
    });

    testWidgets('transfer screens show the decimal label', (tester) async {
      const big = 125829120; // 120 MiB
      await f3PumpTransfer(
        tester,
        F3StubTransfers([
          f3Outgoing(
            phase: TransferPhase.waiting,
            files: const [TransferFile(id: 'f1', name: 'big.bin', size: big)],
          ),
        ]),
      );
      expect(find.text('1 file, 125.8 MB'), findsOneWidget);
      expect(f3AllTexts(), isNot(contains('1 file, 120 MB')));
    });

    testWidgets('progress shows bytes and speed in decimal units', (
      tester,
    ) async {
      await f3PumpTransfer(
        tester,
        F3StubTransfers([
          f3Outgoing(
            files: const [
              TransferFile(
                id: 'f1',
                name: 'big.bin',
                size: 125829120,
                done: 62914560,
              ),
            ],
          ),
        ]),
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('overall-bytes'))).data,
        '62.9 MB / 125.8 MB',
      );
      expect(find.text('62.9 MB / 125.8 MB'), findsNWidgets(2)); // + file row
    });

    testWidgets('the finished screen shows the total in decimal units', (
      tester,
    ) async {
      await f3PumpTransfer(
        tester,
        F3StubTransfers([
          f3Outgoing(
            phase: TransferPhase.completed,
            files: const [
              TransferFile(
                id: 'f1',
                name: 'big.bin',
                size: 125829120,
                done: 125829120,
              ),
            ],
          ),
        ]),
      );
      expect(find.text('125.8 MB'), findsWidgets);
      expect(find.text('120 MB'), findsNothing);
    });

    testWidgets('the Send screen sums the selection in decimal units', (
      tester,
    ) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      h.picker.files = const [
        PickedFile(path: '/nowhere/a.bin', name: 'a.bin', size: 125829120),
        PickedFile(path: '/nowhere/b.bin', name: 'b.bin', size: 1000),
      ];
      await tester.startApp(h);
      await tester.tap(find.byKey(const Key('send-fab')));
      await tester.settleUntil(
        () => find.byKey(const Key('send-summary')).evaluate().isNotEmpty,
        what: 'send screen',
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('send-summary'))).data,
        '2 files selected (125.8 MB)',
      );
      expect(find.text('125.8 MB'), findsOneWidget); // a.bin row
      expect(find.text('1.00 KB'), findsOneWidget); // b.bin row
      await tester.stopApp(h);
    });
  });
}
