// F3 defect 10: on the empty Home the floating "Send files" button must never
// cover the "Scan network" / "Add by IP or QR" / "My QR code" buttons.
//
// Test fonts are wider than a phone's, so the one place where the overlap shows
// moves with the viewport height. The test therefore sweeps heights (including
// the required 360x640) at text scale 1.0 and 1.3, and checks two things:
//   * at rest (scrolled to the top) and at the end of the list, whatever part
//     of an empty-state button is visible in the list's viewport does not
//     intersect the floating button ("visible" = inside the list's viewport);
//   * scrolled to the end, every empty-state button is fully visible, i.e. the
//     user can reach and press all of them.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/harness.dart';

const _buttons = ['empty-scan', 'empty-add', 'empty-qr'];

/// The part of button [key] that is inside the list's viewport (what a person
/// can see and press), or null when none of it is.
Rect? _visible(WidgetTester tester, String key) {
  final f = find.byKey(Key(key));
  if (f.evaluate().isEmpty) return null;
  final r = tester.getRect(f);
  final v = r.intersect(tester.getRect(find.byType(Scrollable).first));
  return (v.width > 0 && v.height > 0) ? v : null;
}

Future<void> _scrollTo(WidgetTester tester, {required bool end}) async {
  await tester.drag(find.byType(ListView).first, Offset(0, end ? -6000 : 6000));
  await tester.pump(const Duration(seconds: 2));
}

void main() {
  for (final scale in [1.0, 1.3]) {
    testWidgets('the Send files button never covers an empty-state button '
        '(text scale $scale)', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      final h = (await tester.runAsync(AppHarness.create))!;
      tester.view.physicalSize = const Size(360, 640);
      await tester.startApp(h);

      const width = 360.0;
      final failures = <String>[];
      var checked = 0;
      for (var height = 560.0; height <= 1400; height += 20) {
        tester.view.physicalSize = Size(width, height);
        await tester.pump(const Duration(milliseconds: 100));
        final fab = tester.getRect(find.byKey(const Key('send-fab')));

        for (final end in [false, true]) {
          await _scrollTo(tester, end: end);
          for (final k in _buttons) {
            final v = _visible(tester, k);
            if (v == null) continue;
            checked++;
            if (v.overlaps(fab)) {
              failures.add(
                '$k at ${width.toInt()}x${height.toInt()} '
                '${end ? "scrolled to the end" : "at rest"}: $v vs button $fab',
              );
            }
          }
          if (end) {
            for (final k in _buttons) {
              final r = tester.getRect(find.byKey(Key(k)));
              final view = tester.getRect(find.byType(Scrollable).first);
              if (r.bottom > view.bottom + 0.5 || r.top < view.top - 0.5) {
                failures.add(
                  '$k not fully visible at the end of the list at '
                  '${width.toInt()}x${height.toInt()}: $r (list viewport $view)',
                );
              }
            }
          }
        }
      }
      expect(checked, greaterThan(20), reason: 'the sweep really looked');
      expect(failures, isEmpty, reason: failures.take(6).join('\n'));
      await tester.stopApp(h);
    });
  }

  testWidgets(
    '360x640: the required size, rects do not intersect at 1.0 and 1.3',
    (tester) async {
      for (final scale in [1.0, 1.3]) {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(360, 640);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        final h = (await tester.runAsync(AppHarness.create))!;
        await tester.startApp(h);
        final fab = tester.getRect(find.byKey(const Key('send-fab')));
        expect(fab.width, greaterThan(0));
        for (final end in [false, true]) {
          await _scrollTo(tester, end: end);
          for (final k in _buttons) {
            final f = find.byKey(Key(k));
            if (f.evaluate().isEmpty) continue;
            expect(
              tester.getRect(f).overlaps(fab),
              isFalse,
              reason: '$k at scale $scale (end: $end)',
            );
          }
        }
        // The three buttons exist at all (not "fixed" by removing them).
        await _scrollTo(tester, end: true);
        for (final k in _buttons) {
          expect(find.byKey(Key(k)), findsOneWidget, reason: k);
        }
        expect(find.byKey(const Key('send-fab')), findsOneWidget);
        await tester.stopApp(h);
      }
      tester.view.reset();
      tester.platformDispatcher.clearAllTestValues();
    },
  );
}
