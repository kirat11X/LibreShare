// U3 Pairing Test: verifies UI-driven QR pairing using real in-process engines,
// mutual contact establishment with PeerTrust.trusted, rejection of reused and
// expired invites with visible status messages, absence of the secret token s=
// in logs, widget toString, and semantics, and layout stability at 360x640.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/providers/engine_provider.dart';
import 'package:libreshare_core/libreshare_core.dart';
import 'package:logging/logging.dart';

import 'helpers/d1b_helpers.dart';
import 'helpers/harness.dart';

class _PrebuiltEngineNotifier extends EngineNotifier {
  _PrebuiltEngineNotifier(this._engine);
  final LibreShareEngine _engine;

  @override
  Future<LibreShareEngine> build() async => _engine;

  @override
  Future<void> shutdown() async {}
}

/// Automatically accepts pairing requests on the inviter engine when prompted.
Timer autoAcceptPairPrompt(LibreShareEngine engine) {
  return Zone.root.createPeriodicTimer(const Duration(milliseconds: 25), (t) {
    if (!engine.isStarted) {
      t.cancel();
      return;
    }
    if (engine.pairing.pendingPrompt != null) {
      engine.pairing.decide(accept: true);
    }
  });
}

Future<LibreShareEngine> createSecureEngine({
  required String name,
  required String ip,
  required Directory sandbox,
  Clock clock = const SystemClock(),
}) async {
  final secDir = Directory(pj(sandbox.path, 'security'))
    ..createSync(recursive: true);
  final wiring = await SecurityWiring.open(
    directory: secDir,
    deviceId: '$name-device-id',
  );
  final rxDir = Directory(pj(sandbox.path, 'rx'))..createSync(recursive: true);
  final engine = LibreShareEngine(
    self: DeviceInfo(
      deviceId: wiring.identity.identity.deviceId,
      alias: name,
      platform: 'linux',
    ),
    downloadDir: rxDir,
    bindAddress: InternetAddress(ip),
    preferredPort: 0,
    autoAccept: true,
    security: wiring,
    clock: clock,
    receiveConfig: const ReceiveConfig(initialMode: ReceiveAlways()),
  );
  await engine.start();
  return engine;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UI-driven QR pairing flow (U3)', () {
    testWidgets(
      'positive twin: Engine A creates invite, Engine B redeems via pair-paste-field and pair-redeem-button -> both engines become trusted contacts',
      (tester) async {
        HttpOverrides.global = null;
        final aSandbox = Directory.systemTemp.createTempSync('ls_pair_a_pos_');
        addTearDown(() => aSandbox.deleteSync(recursive: true));
        final bSandbox = Directory.systemTemp.createTempSync('ls_pair_b_pos_');
        addTearDown(() => bSandbox.deleteSync(recursive: true));

        final (engineA, engineB) = (await tester.runAsync(() async {
          final a = await createSecureEngine(
            name: 'Alice',
            ip: '127.0.0.21',
            sandbox: aSandbox,
          );
          final b = await createSecureEngine(
            name: 'Bob',
            ip: '127.0.0.22',
            sandbox: bSandbox,
          );
          return (a, b);
        }))!;
        addTearDown(() => engineA.dispose(force: true));
        addTearDown(() => engineB.dispose(force: true));
        final promptTimer = autoAcceptPairPrompt(engineA);
        addTearDown(promptTimer.cancel);

        final inviteUri = engineA.createPairInvite();
        expect(inviteUri, contains('libreshare://pair?'));

        final h = (await tester.runAsync(
          () => AppHarness.create(
            initialLocation: '/pair',
            overrides: [
              engineProvider.overrideWith(
                () => _PrebuiltEngineNotifier(engineB),
              ),
              engineOrNullProvider.overrideWithValue(engineB),
            ],
          ),
        ))!;
        addTearDown(() => h.dispose());

        await tester.pumpWidget(h.app);
        await tester.settle();

        // Verify UI components exist
        expect(
          find.byKey(const Key('pair-paste-field')),
          findsOneWidget,
          reason: 'paste field must exist on the pair screen',
        );
        expect(
          find.byKey(const Key('pair-redeem-button')),
          findsOneWidget,
          reason: 'redeem button must exist on the pair screen',
        );

        // Paste invite URI and redeem
        await tester.enterText(
          find.byKey(const Key('pair-paste-field')),
          inviteUri,
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('pair-redeem-button')));
        await tester.settle(ms: 50, rounds: 10);

        // Both engines must list each other with PeerTrust.trusted
        await tester.settleUntil(() {
          final aHasB = engineA.currentContacts.any(
            (c) =>
                c.deviceId == engineB.self.deviceId &&
                c.trust == PeerTrust.trusted,
          );
          final bHasA = engineB.currentContacts.any(
            (c) =>
                c.deviceId == engineA.self.deviceId &&
                c.trust == PeerTrust.trusted,
          );
          return aHasB && bHasA;
        }, what: 'both engines establish mutual trusted pairing');

        expect(
          find.byKey(const Key('pair-status-message')),
          findsOneWidget,
          reason: 'pair status message must be visible upon completion',
        );
        expect(
          find.textContaining('Alice'),
          findsWidgets,
          reason: 'status message or UI reflects paired peer alias',
        );
      },
      timeout: kSixtySeconds,
    );

    testWidgets(
      'negative twin: reused invite is rejected with visible message on pair-status-message',
      (tester) async {
        HttpOverrides.global = null;
        final aSandbox = Directory.systemTemp.createTempSync(
          'ls_pair_a_reused_',
        );
        addTearDown(() => aSandbox.deleteSync(recursive: true));
        final bSandbox = Directory.systemTemp.createTempSync(
          'ls_pair_b_reused_',
        );
        addTearDown(() => bSandbox.deleteSync(recursive: true));
        final cSandbox = Directory.systemTemp.createTempSync(
          'ls_pair_c_reused_',
        );
        addTearDown(() => cSandbox.deleteSync(recursive: true));

        final (engineA, engineB, engineC) = (await tester.runAsync(() async {
          final a = await createSecureEngine(
            name: 'Alice',
            ip: '127.0.0.23',
            sandbox: aSandbox,
          );
          final c = await createSecureEngine(
            name: 'Charlie',
            ip: '127.0.0.24',
            sandbox: cSandbox,
          );
          final b = await createSecureEngine(
            name: 'Bob',
            ip: '127.0.0.25',
            sandbox: bSandbox,
          );
          return (a, b, c);
        }))!;
        addTearDown(() => engineA.dispose(force: true));
        addTearDown(() => engineB.dispose(force: true));
        addTearDown(() => engineC.dispose(force: true));
        final promptTimer = autoAcceptPairPrompt(engineA);
        addTearDown(promptTimer.cancel);

        final inviteUri = engineA.createPairInvite();

        // Charlie redeems it first -> invite is spent
        final redeemedByCharlie = await tester.runAsync(
          () => engineC.redeemPairInvite(inviteUri),
        );
        expect(redeemedByCharlie, isTrue);

        // Now Bob attempts to redeem the same spent invite via UI
        final h = (await tester.runAsync(
          () => AppHarness.create(
            initialLocation: '/pair',
            overrides: [
              engineProvider.overrideWith(
                () => _PrebuiltEngineNotifier(engineB),
              ),
              engineOrNullProvider.overrideWithValue(engineB),
            ],
          ),
        ))!;
        addTearDown(() => h.dispose());

        await tester.pumpWidget(h.app);
        await tester.settle();

        expect(find.byKey(const Key('pair-paste-field')), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('pair-paste-field')),
          inviteUri,
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('pair-redeem-button')));
        await tester.settle(ms: 50, rounds: 10);

        expect(
          find.byKey(const Key('pair-status-message')),
          findsOneWidget,
          reason: 'status message must report rejection of reused invite',
        );

        // Bob must NOT have Alice as trusted contact
        expect(
          engineB.currentContacts.any(
            (c) => c.deviceId == engineA.self.deviceId,
          ),
          isFalse,
          reason: 'reused invite must not add contact',
        );
      },
      timeout: kSixtySeconds,
    );

    testWidgets(
      'negative twin: expired invite is rejected with visible message on pair-status-message',
      (tester) async {
        HttpOverrides.global = null;
        final aSandbox = Directory.systemTemp.createTempSync('ls_pair_a_exp_');
        addTearDown(() => aSandbox.deleteSync(recursive: true));
        final bSandbox = Directory.systemTemp.createTempSync('ls_pair_b_exp_');
        addTearDown(() => bSandbox.deleteSync(recursive: true));

        final clock = ManualClock();
        final (engineA, engineB) = (await tester.runAsync(() async {
          final a = await createSecureEngine(
            name: 'Alice',
            ip: '127.0.0.26',
            sandbox: aSandbox,
            clock: clock,
          );
          final b = await createSecureEngine(
            name: 'Bob',
            ip: '127.0.0.27',
            sandbox: bSandbox,
          );
          return (a, b);
        }))!;
        addTearDown(() => engineA.dispose(force: true));
        addTearDown(() => engineB.dispose(force: true));
        final promptTimer = autoAcceptPairPrompt(engineA);
        addTearDown(promptTimer.cancel);

        final inviteUri = engineA.createPairInvite();

        // Advance clock past the 10-minute invite TTL
        clock.advance(const Duration(minutes: 15));

        final h = (await tester.runAsync(
          () => AppHarness.create(
            initialLocation: '/pair',
            overrides: [
              engineProvider.overrideWith(
                () => _PrebuiltEngineNotifier(engineB),
              ),
              engineOrNullProvider.overrideWithValue(engineB),
            ],
          ),
        ))!;
        addTearDown(() => h.dispose());

        await tester.pumpWidget(h.app);
        await tester.settle();

        expect(find.byKey(const Key('pair-paste-field')), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('pair-paste-field')),
          inviteUri,
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('pair-redeem-button')));
        await tester.settle(ms: 50, rounds: 10);

        expect(
          find.byKey(const Key('pair-status-message')),
          findsOneWidget,
          reason: 'status message must report rejection of expired invite',
        );

        expect(
          engineB.currentContacts.any(
            (c) => c.deviceId == engineA.self.deviceId,
          ),
          isFalse,
          reason: 'expired invite must not add contact',
        );
      },
      timeout: kSixtySeconds,
    );

    testWidgets(
      'security invariant: secret token s= NEVER appears in any log record, toString, or semantics label',
      (tester) async {
        HttpOverrides.global = null;
        final logs = <LogRecord>[];
        final logSub = Logger.root.onRecord.listen(logs.add);
        addTearDown(logSub.cancel);

        final aSandbox = Directory.systemTemp.createTempSync('ls_pair_a_sec_');
        addTearDown(() => aSandbox.deleteSync(recursive: true));

        final engineA = (await tester.runAsync(
          () => createSecureEngine(
            name: 'Alice',
            ip: '127.0.0.28',
            sandbox: aSandbox,
          ),
        ))!;
        addTearDown(() => engineA.dispose(force: true));

        final inviteUri = engineA.createPairInvite();
        final secret = Uri.parse(inviteUri).queryParameters['s']!;
        expect(secret.length, 43);

        // Boot App for Engine A to show the invite UI (QR / invite display)
        final h = (await tester.runAsync(
          () => AppHarness.create(
            initialLocation: '/pair',
            overrides: [
              engineProvider.overrideWith(
                () => _PrebuiltEngineNotifier(engineA),
              ),
              engineOrNullProvider.overrideWithValue(engineA),
            ],
          ),
        ))!;
        addTearDown(() => h.dispose());

        await tester.pumpWidget(h.app);
        await tester.settle();

        // Screen must render pair-screen
        expect(
          find.byKey(const Key('pair-screen')),
          findsOneWidget,
          reason: 'pair-screen must render',
        );

        // Verify no log record leaks the secret token
        for (final r in logs) {
          expect(
            r.message.contains(secret),
            isFalse,
            reason: 'log record must not contain secret token s: ${r.message}',
          );
          expect(
            r.message.contains('s='),
            isFalse,
            reason: 'log record must not contain s= parameter: ${r.message}',
          );
        }

        // Verify no semantics label leaks the secret token
        expect(
          find.bySemanticsLabel(RegExp(RegExp.escape(secret))),
          findsNothing,
          reason: 'semantics label must not contain secret token',
        );

        // Verify no widget toString leaks s= secret
        for (final element in find.byType(Widget).evaluate()) {
          final str = element.widget.toString();
          expect(
            str.contains('s=$secret'),
            isFalse,
            reason: 'widget toString must not leak s=$secret: $str',
          );
        }
      },
      timeout: kSixtySeconds,
    );

    testWidgets(
      'layout and scaling: screen size 360x640 with textScaler 1.3 passes without RenderFlex overflow',
      (tester) async {
        HttpOverrides.global = null;
        tester.view.physicalSize = const Size(360, 640);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final aSandbox = Directory.systemTemp.createTempSync(
          'ls_pair_a_scale_',
        );
        addTearDown(() => aSandbox.deleteSync(recursive: true));

        final engineA = (await tester.runAsync(
          () => createSecureEngine(
            name: 'Alice',
            ip: '127.0.0.29',
            sandbox: aSandbox,
          ),
        ))!;
        addTearDown(() => engineA.dispose(force: true));

        final h = (await tester.runAsync(
          () => AppHarness.create(
            initialLocation: '/pair',
            overrides: [
              engineProvider.overrideWith(
                () => _PrebuiltEngineNotifier(engineA),
              ),
              engineOrNullProvider.overrideWithValue(engineA),
            ],
          ),
        ))!;
        addTearDown(() => h.dispose());

        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(
              size: Size(360, 640),
              textScaler: TextScaler.linear(1.3),
            ),
            child: h.app,
          ),
        );
        await tester.settle();

        expect(
          find.byKey(const Key('pair-screen')),
          findsOneWidget,
          reason: 'pair-screen must render at 360x640 with textScaler 1.3',
        );
        expect(
          tester.takeException(),
          isNull,
          reason:
              'no RenderFlex overflow allowed at 360x640 with textScaler 1.3',
        );
      },
      timeout: kSixtySeconds,
    );
  });
}
