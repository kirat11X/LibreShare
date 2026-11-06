// D1 round-2 S3 (docs/plans/d1-fixes.md): the sender's PIN dialog works end to
// end THROUGH THE UI against a real secure receiver: the app engine is the
// sender (startSend -> pin-dialog -> pin-field -> pin-submit), Bob is a second
// real engine with a Fixed PIN. Keys used: pin-dialog, pin-field (existing),
// pin-submit (NEW), failure-text (existing). Nothing here calls
// engine.sendFiles(pin:) for the send under test.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/providers/router_provider.dart';
import 'package:libreshare_app/providers/transfers_provider.dart';

import 'helpers/d1b_helpers.dart';
import 'helpers/harness.dart';

const String correctPin = '381920';

class Rig {
  Rig(this.h, this.bob, this.file, this.key, this.logs);
  final AppHarness h;
  final SecureBob bob;
  final File file;
  final String key;
  final LogCapture logs;
}

Future<Rig> startRig(WidgetTester tester, String bobIp) async {
  tester.useTallSurface();
  final logs = LogCapture();
  addTearDown(logs.stop);
  final h = (await tester.runAsync(AppHarness.create))!;
  final bob = (await tester.runAsync(
    () => SecureBob.start(h.sandbox, bobIp, pin: correctPin),
  ))!;
  await bootApp(tester, h);
  final file = h.makeFile('document.txt', 256);
  final key = h.container.read(transfersProvider.notifier).startSend(
    bob.device,
    [h.pick(file)],
  );
  unawaited(h.container.read(routerProvider).push('/transfer/$key'));
  await tester.pump();
  await tester.settleUntil(
    () => shown(find.byKey(const Key('pin-dialog'))),
    what: 'the PIN dialog',
  );
  return Rig(h, bob, file, key, logs);
}

Future<void> finish(WidgetTester tester, Rig r) async {
  r.logs.stop(); // debugPrint is restored before the test ends
  await tester.stopApp(r.h);
  await tester.runAsync(r.bob.close);
}

Future<void> submit(WidgetTester tester, String pin) async {
  await tester.enterText(find.byKey(const Key('pin-field')), pin);
  await tester.pump();
  expect(
    find.byKey(const Key('pin-submit')),
    findsOneWidget,
    reason: 'S3: the dialog needs a submit button with the key pin-submit',
  );
  await tester.tap(find.byKey(const Key('pin-submit')));
  await tester.pump();
}

List<TransferView> views(Rig r) => r.h.container.read(transfersProvider);

void expectNoPinAnywhere(Rig r, String pin) {
  for (final v in views(r)) {
    expect(v.toString(), isNot(contains(pin)));
    expect(v.key, isNot(contains(pin)));
    expect(v.sessionId ?? '', isNot(contains(pin)));
  }
  expect(views(r).toString(), isNot(contains(pin)));
  final loc = r.h.container
      .read(routerProvider)
      .routeInformationProvider
      .value
      .uri
      .toString();
  expect(loc, isNot(contains(pin)), reason: 'the PIN is never a route param');
  expect(r.logs.contains(pin), isFalse, reason: 'the PIN is never logged');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('S3 sender PIN dialog, two real engines', () {
    testWidgets(
      'positive twin: the correct PIN submitted with the button completes the transfer; the PIN is nowhere',
      (tester) async {
        final r = await startRig(tester, '127.0.0.31');
        expect(r.bob.incomingSessions, 0, reason: 'refused before any session');
        await submit(tester, correctPin);
        await tester.settleUntil(
          () => views(r).any((v) => v.phase == TransferPhase.completed),
          what: 'the transfer completing after the PIN was submitted',
          maxRounds: 400,
        );
        expect(
          views(r).where((v) => v.phase == TransferPhase.completed),
          hasLength(1),
        );
        expect(find.byKey(const Key('pin-dialog')), findsNothing);
        final got = r.bob.received.where(
          (f) => baseName(f.path) == 'document.txt',
        );
        expect(got, hasLength(1), reason: 'the file arrived at Bob');
        expect(got.single.readAsBytesSync(), r.file.readAsBytesSync());
        expectNoPinAnywhere(r, correctPin);
        await finish(tester, r);
      },
      timeout: kSixtySeconds,
    );

    testWidgets(
      'positive twin: the keyboard submit (onSubmitted) works like the button',
      (tester) async {
        final r = await startRig(tester, '127.0.0.32');
        await tester.enterText(find.byKey(const Key('pin-field')), correctPin);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        await tester.settleUntil(
          () => views(r).any((v) => v.phase == TransferPhase.completed),
          what: 'the transfer completing after the keyboard submit',
          maxRounds: 400,
        );
        expect(r.bob.received, hasLength(1));
        expectNoPinAnywhere(r, correctPin);
        await finish(tester, r);
      },
      timeout: kSixtySeconds,
    );

    testWidgets(
      'negative twin: a wrong PIN shows exactly "That PIN was not accepted." (no digits, no attempt count) and nothing arrives',
      (tester) async {
        final r = await startRig(tester, '127.0.0.33');
        await submit(tester, '000000');
        await tester.settleUntil(
          () => shown(find.text(kWrongPin)),
          what: 'the wrong-PIN message',
          maxRounds: 300,
        );
        expect(find.text(kWrongPin), findsAtLeastNWidgets(1));
        for (final t in visibleTexts()) {
          if (t.contains('PIN was not accepted')) {
            expect(t, kWrongPin, reason: 'exact wording only');
          }
          final lower = t.toLowerCase();
          for (final bad in const [
            'attempt',
            'tries',
            'remaining',
            'strike',
            'blocked',
          ]) {
            expect(lower.contains(bad), isFalse, reason: 'no counts: $bad');
          }
        }
        expect(
          visibleTexts().where((t) => t.contains('000000')),
          isEmpty,
          reason: 'the entered digits are not echoed',
        );
        expect(r.bob.received, isEmpty);
        expectNoPinAnywhere(r, '000000');
        expectNoPinAnywhere(r, correctPin);
        await finish(tester, r);
      },
      timeout: kSixtySeconds,
    );

    for (final bad in const ['12345', 'abcdef', '12a456']) {
      testWidgets(
        'negative twin: "$bad" is rejected with a visible message and no send is started',
        (tester) async {
          final r = await startRig(
            tester,
            bad == '12345'
                ? '127.0.0.34'
                : (bad == 'abcdef' ? '127.0.0.35' : '127.0.0.36'),
          );
          final before = views(r).length;
          await submit(tester, bad);
          await tester.settle(ms: 100, rounds: 3);
          expect(
            find.textContaining('6 digits'),
            findsAtLeastNWidgets(1),
            reason: 'S3: a visible validation message (^[0-9]{6}\$)',
          );
          expect(find.byKey(const Key('pin-dialog')), findsOneWidget);
          expect(views(r), hasLength(before), reason: 'no new transfer');
          expect(r.bob.incomingSessions, 0);
          expect(r.bob.received, isEmpty);
          await finish(tester, r);
        },
        timeout: kSixtySeconds,
      );
    }

    testWidgets(
      'a "blocked" refusal shows the neutral sentence (no counts, no time, no digits)',
      (tester) async {
        tester.useTallSurface();
        final logs = LogCapture();
        addTearDown(logs.stop);
        final h = (await tester.runAsync(AppHarness.create))!;
        final bob = (await tester.runAsync(
          () => SecureBob.start(h.sandbox, '127.0.0.37', pin: correctPin),
        ))!;
        await bootApp(tester, h);
        final f = h.makeFile('block.txt', 64);
        // Five wrong PINs from the app's own address block it (core API:
        // this is only the setup of the blocked state).
        await tester.runAsync(() async {
          for (var i = 0; i < 5; i++) {
            await h.engine.sendFiles(
              [f],
              host: bob.ip,
              port: bob.engine.port,
              pin: '00000$i',
            );
          }
        });
        final key = h.container.read(transfersProvider.notifier).startSend(
          bob.device,
          [h.pick(f)],
        );
        unawaited(h.container.read(routerProvider).push('/transfer/$key'));
        await tester.pump();
        await tester.settleUntil(
          () =>
              shown(find.byKey(const Key('failure-text'))) ||
              shown(find.byKey(const Key('pin-dialog'))),
          what: 'the refusal of a blocked source',
          maxRounds: 300,
        );
        expect(find.text(kBlockedText), findsOneWidget);
        expect(
          find.byKey(const Key('failure-text')).evaluate().isEmpty
              ? ''
              : tester.widget<Text>(find.byKey(const Key('failure-text'))).data,
          kBlockedText,
        );
        expect(RegExp(r'\d').hasMatch(kBlockedText), isFalse);
        expect(bob.received, isEmpty);
        logs.stop();
        await tester.stopApp(h);
        await tester.runAsync(bob.close);
      },
      timeout: kSixtySeconds,
    );
  });
}
