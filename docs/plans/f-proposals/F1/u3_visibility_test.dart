// U3 Visibility Test: verifies widgets/receive_card.dart visibility selector
// (Everyone, Contacts only, Nobody) and real-engine enforcement against
// trusted contacts and strangers over loopback.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/providers/engine_provider.dart';
import 'package:libreshare_app/widgets/app_theme.dart';
import 'package:libreshare_app/widgets/receive_card.dart';
import 'package:libreshare_core/libreshare_core.dart';
import 'package:libreshare_core/src/discovery/testing/in_memory_multicast.dart';

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

Future<LibreShareEngine> createVisibilityEngine({
  required String name,
  required String ip,
  required Directory sandbox,
  required InMemoryMulticastBus bus,
  ReceiveMode initialMode = const ReceiveAlways(),
  ReceiveVisibility initialVisibility = ReceiveVisibility.everyone,
}) async {
  final secDir = Directory(pj(sandbox.path, 'security'))
    ..createSync(recursive: true);
  final wiring = await SecurityWiring.open(
    directory: secDir,
    deviceId: '$name-visibility-id',
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
    discovery: DiscoveryConfig(
      multicastTransport: () => bus.createTransport(address: ip),
      interfaces: FakeIfaces(),
      autoScan: false,
      announceSchedule: const [],
      announceInterval: const Duration(hours: 1),
      interfacePoll: const Duration(hours: 1),
    ),
    receiveConfig: ReceiveConfig(initialMode: initialMode),
  );
  await engine.start();
  if (initialVisibility != ReceiveVisibility.everyone) {
    await engine.receive.setVisibility(initialVisibility);
  }
  return engine;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ReceiveCard visibility selector (U3)', () {
    testWidgets(
      'ReceiveCard renders SegmentedButton with Key(visibility-selector) and choices Everyone, Contacts only, Nobody',
      (tester) async {
        HttpOverrides.global = null;
        final bus = InMemoryMulticastBus();
        final aSandbox = Directory.systemTemp.createTempSync('ls_vis_ui_');
        addTearDown(() => aSandbox.deleteSync(recursive: true));

        final engineA = (await tester.runAsync(
          () => createVisibilityEngine(
            name: 'Alice',
            ip: '127.0.0.31',
            sandbox: aSandbox,
            bus: bus,
          ),
        ))!;
        addTearDown(() => engineA.dispose(force: true));

        final h = (await tester.runAsync(
          () => AppHarness.create(
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
          UncontrolledProviderScope(
            container: h.container,
            child: MaterialApp(
              theme: buildTheme(Brightness.light),
              home: const Scaffold(
                body: SingleChildScrollView(
                  child: ReceiveCard(showVisibility: true),
                ),
              ),
            ),
          ),
        );
        await tester.settle();

        expect(
          find.byKey(const Key('visibility-selector')),
          findsOneWidget,
          reason: 'ReceiveCard must have a SegmentedButton with Key(visibility-selector)',
        );
        expect(
          find.byKey(const Key('visibility-segment-everyone')),
          findsOneWidget,
          reason: 'Everyone segment must have Key(visibility-segment-everyone)',
        );
        expect(
          find.byKey(const Key('visibility-segment-contacts')),
          findsOneWidget,
          reason: 'Contacts only segment must have Key(visibility-segment-contacts)',
        );
        expect(
          find.byKey(const Key('visibility-segment-nobody')),
          findsOneWidget,
          reason: 'Nobody segment must have Key(visibility-segment-nobody)',
        );
      },
      timeout: kSixtySeconds,
    );

    testWidgets(
      'When set to contacts: Engine B (trusted contact) discovers Engine A and transfers; Engine C (stranger) receives 404 on GET /info and cannot see Engine A in discovery',
      (tester) async {
        HttpOverrides.global = null;
        final bus = InMemoryMulticastBus();
        final aSandbox = Directory.systemTemp.createTempSync('ls_vis_a_cont_');
        addTearDown(() => aSandbox.deleteSync(recursive: true));
        final bSandbox = Directory.systemTemp.createTempSync('ls_vis_b_cont_');
        addTearDown(() => bSandbox.deleteSync(recursive: true));
        final cSandbox = Directory.systemTemp.createTempSync('ls_vis_c_cont_');
        addTearDown(() => cSandbox.deleteSync(recursive: true));

        final (engineA, engineB, engineC) = (await tester.runAsync(() async {
          final a = await createVisibilityEngine(
            name: 'Alice',
            ip: '127.0.0.32',
            sandbox: aSandbox,
            bus: bus,
            initialVisibility: ReceiveVisibility.contacts,
          );
          final b = await createVisibilityEngine(
            name: 'Bob',
            ip: '127.0.0.33',
            sandbox: bSandbox,
            bus: bus,
          );
          final c = await createVisibilityEngine(
            name: 'Charlie',
            ip: '127.0.0.34',
            sandbox: cSandbox,
            bus: bus,
          );
          return (a, b, c);
        }))!;
        addTearDown(() => engineA.dispose(force: true));
        addTearDown(() => engineB.dispose(force: true));
        addTearDown(() => engineC.dispose(force: true));

        // Alice and Bob are mutual trusted contacts
        await tester.runAsync(() async {
          await engineA.addContact(
            deviceId: engineB.self.deviceId,
            fingerprint: engineB.ownFingerprint,
            alias: engineB.self.alias,
            trust: PeerTrust.trusted,
          );
          await engineB.addContact(
            deviceId: engineA.self.deviceId,
            fingerprint: engineA.ownFingerprint,
            alias: engineA.self.alias,
            trust: PeerTrust.trusted,
          );
        });

        // Charlie is a stranger (no contact entry on Alice)

        final h = (await tester.runAsync(
          () => AppHarness.create(
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
          UncontrolledProviderScope(
            container: h.container,
            child: MaterialApp(
              theme: buildTheme(Brightness.light),
              home: const Scaffold(
                body: SingleChildScrollView(
                  child: ReceiveCard(showVisibility: true),
                ),
              ),
            ),
          ),
        );
        await tester.settle();

        // Select Contacts only via UI
        expect(
          find.byKey(const Key('visibility-segment-contacts')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('visibility-segment-contacts')));
        await tester.settleUntil(
          () =>
              engineA.receive.settings.visibility == ReceiveVisibility.contacts,
          what: 'Engine A visibility set to contacts',
        );

        // Engine B (trusted contact) can query /info successfully
        final bobInfo = await tester.runAsync(
          () => engineB.peerInfo('127.0.0.32', engineA.port),
        );
        expect(bobInfo?.deviceId, equals(engineA.self.deviceId));

        // Engine B can transfer files to Engine A
        final testFile = File(pj(bSandbox.path, 'transfer_sample.txt'))
          ..writeAsStringSync('Hello Alice from trusted Bob');
        final sendResult = await tester.runAsync(
          () => engineB.sendFiles(
            [testFile],
            host: '127.0.0.32',
            port: engineA.port,
          ),
        );
        expect(
          sendResult?.isSuccess,
          isTrue,
          reason: 'trusted contact transfer must succeed',
        );
        expect(
          File(pj(aSandbox.path, 'rx', 'transfer_sample.txt')).existsSync(),
          isTrue,
        );

        // Engine C (stranger) receives 404 on GET /info
        Object? strangerErr;
        await tester.runAsync(() async {
          try {
            await engineC.peerInfo('127.0.0.32', engineA.port);
          } catch (e) {
            strangerErr = e;
          }
        });
        expect(
          strangerErr,
          isA<LsException>().having(
            (e) => e.code,
            'code',
            LsErrorCode.notFound,
          ),
          reason:
              'stranger receives 404 on /info while Contacts only is active',
        );

        // Engine C (stranger) cannot see Engine A in discovery
        expect(
          engineC.currentDevices.any(
            (d) => d.info.deviceId == engineA.self.deviceId,
          ),
          isFalse,
          reason: 'stranger must not see Contacts-only device in discovery',
        );
      },
      timeout: kSixtySeconds,
    );

    testWidgets(
      'When set to nobody: neither Engine B nor Engine C discovers Engine A',
      (tester) async {
        HttpOverrides.global = null;
        final bus = InMemoryMulticastBus();
        final aSandbox = Directory.systemTemp.createTempSync('ls_vis_a_nob_');
        addTearDown(() => aSandbox.deleteSync(recursive: true));
        final bSandbox = Directory.systemTemp.createTempSync('ls_vis_b_nob_');
        addTearDown(() => bSandbox.deleteSync(recursive: true));
        final cSandbox = Directory.systemTemp.createTempSync('ls_vis_c_nob_');
        addTearDown(() => cSandbox.deleteSync(recursive: true));

        final (engineA, engineB, engineC) = (await tester.runAsync(() async {
          final a = await createVisibilityEngine(
            name: 'Alice',
            ip: '127.0.0.35',
            sandbox: aSandbox,
            bus: bus,
          );
          final b = await createVisibilityEngine(
            name: 'Bob',
            ip: '127.0.0.36',
            sandbox: bSandbox,
            bus: bus,
          );
          final c = await createVisibilityEngine(
            name: 'Charlie',
            ip: '127.0.0.37',
            sandbox: cSandbox,
            bus: bus,
          );
          return (a, b, c);
        }))!;
        addTearDown(() => engineA.dispose(force: true));
        addTearDown(() => engineB.dispose(force: true));
        addTearDown(() => engineC.dispose(force: true));

        await tester.runAsync(
          () => engineA.addContact(
            deviceId: engineB.self.deviceId,
            fingerprint: engineB.ownFingerprint,
            alias: engineB.self.alias,
            trust: PeerTrust.trusted,
          ),
        );

        final h = (await tester.runAsync(
          () => AppHarness.create(
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
          UncontrolledProviderScope(
            container: h.container,
            child: MaterialApp(
              theme: buildTheme(Brightness.light),
              home: const Scaffold(
                body: SingleChildScrollView(
                  child: ReceiveCard(showVisibility: true),
                ),
              ),
            ),
          ),
        );
        await tester.settle();

        // Select Nobody via UI
        expect(
          find.byKey(const Key('visibility-segment-nobody')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('visibility-segment-nobody')));
        await tester.settleUntil(
          () => engineA.receive.state is Off,
          what: 'Engine A receive mode turned off (Nobody)',
        );

        expect(engineA.isListening, isFalse);

        // Neither Bob nor Charlie discovers Alice
        expect(
          engineB.currentDevices.any(
            (d) => d.info.deviceId == engineA.self.deviceId,
          ),
          isFalse,
          reason: 'Bob must not discover Alice when Alice is set to nobody',
        );
        expect(
          engineC.currentDevices.any(
            (d) => d.info.deviceId == engineA.self.deviceId,
          ),
          isFalse,
          reason: 'Charlie must not discover Alice when Alice is set to nobody',
        );
      },
      timeout: kSixtySeconds,
    );

    testWidgets(
      'When set to everyone: both Engine B and Engine C can discover Engine A',
      (tester) async {
        HttpOverrides.global = null;
        final bus = InMemoryMulticastBus();
        final aSandbox = Directory.systemTemp.createTempSync('ls_vis_a_ev_');
        addTearDown(() => aSandbox.deleteSync(recursive: true));
        final bSandbox = Directory.systemTemp.createTempSync('ls_vis_b_ev_');
        addTearDown(() => bSandbox.deleteSync(recursive: true));
        final cSandbox = Directory.systemTemp.createTempSync('ls_vis_c_ev_');
        addTearDown(() => cSandbox.deleteSync(recursive: true));

        final (engineA, engineB, engineC) = (await tester.runAsync(() async {
          final a = await createVisibilityEngine(
            name: 'Alice',
            ip: '127.0.0.38',
            sandbox: aSandbox,
            bus: bus,
            initialVisibility: ReceiveVisibility.contacts,
          );
          final b = await createVisibilityEngine(
            name: 'Bob',
            ip: '127.0.0.39',
            sandbox: bSandbox,
            bus: bus,
          );
          final c = await createVisibilityEngine(
            name: 'Charlie',
            ip: '127.0.0.40',
            sandbox: cSandbox,
            bus: bus,
          );
          return (a, b, c);
        }))!;
        addTearDown(() => engineA.dispose(force: true));
        addTearDown(() => engineB.dispose(force: true));
        addTearDown(() => engineC.dispose(force: true));

        final h = (await tester.runAsync(
          () => AppHarness.create(
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
          UncontrolledProviderScope(
            container: h.container,
            child: MaterialApp(
              theme: buildTheme(Brightness.light),
              home: const Scaffold(
                body: SingleChildScrollView(
                  child: ReceiveCard(showVisibility: true),
                ),
              ),
            ),
          ),
        );
        await tester.settle();

        // Select Everyone via UI
        expect(
          find.byKey(const Key('visibility-segment-everyone')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('visibility-segment-everyone')));
        await tester.settleUntil(
          () =>
              engineA.receive.settings.visibility == ReceiveVisibility.everyone,
          what: 'Engine A visibility set to everyone',
        );

        // Both Bob and Charlie can query /info
        final bInfo = await tester.runAsync(
          () => engineB.peerInfo('127.0.0.38', engineA.port),
        );
        expect(bInfo?.deviceId, equals(engineA.self.deviceId));

        final cInfo = await tester.runAsync(
          () => engineC.peerInfo('127.0.0.38', engineA.port),
        );
        expect(cInfo?.deviceId, equals(engineA.self.deviceId));
      },
      timeout: kSixtySeconds,
    );
  });
}
