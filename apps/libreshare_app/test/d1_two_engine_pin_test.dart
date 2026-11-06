// D1 two-engine PIN test: verifies the sender-side PIN dialog (B1)
// working against a real secure receiver with fixed PIN enforcement,
// wrong PIN handling, and trusted contact exemption (two engines in one test,
// like core secure_two_engine_test).
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/providers/transfers_provider.dart';
import 'package:libreshare_app/screens/transfer_screen.dart';
import 'package:libreshare_app/widgets/app_theme.dart';
import 'package:libreshare_core/libreshare_core.dart';

import 'helpers/d1b_helpers.dart';
import 'helpers/harness.dart';

/// A(3): the user at the receiver compares the verification codes and presses
/// Accept. Without it a first-contact session waits for consent for ever and
/// `sendFiles` never completes. (The app's own sender needs no confirmation:
/// the sender only shows the code and waits for the receiver.)
void confirmSasOn(LibreShareEngine receiver) {
  receiver.events.listen((e) {
    if (e is SasReady && !e.outgoing) {
      unawaited(
        receiver.receiver.accept(e.sessionId).then((_) {}, onError: (_) {}),
      );
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Two-engine secure PIN transfer and dialog flow', () {
    const correctPin = '381920';

    test('positive twin: sender encounters pinRequired against real secure receiver, and transfer succeeds when correct PIN is provided', () async {
      // Alice: app engine under test
      final h = await AppHarness.create();
      addTearDown(() => h.dispose());
      await h.boot();

      // Bob: real secure receiver with Fixed PIN policy
      final bobSandbox = Directory.systemTemp.createTempSync('ls_bob_pin_');
      addTearDown(() => bobSandbox.deleteSync(recursive: true));
      final bobSecDir = Directory(pj(bobSandbox.path, 'security'))
        ..createSync(recursive: true);

      final bobWiring = await SecurityWiring.open(
        directory: bobSecDir,
        deviceId: 'bob-secure-id-1',
        pinPolicy: const PinPolicy(mode: PinMode.fixed),
        pin: correctPin,
      );
      addTearDown(bobWiring.close);

      final bobRxDir = Directory(pj(bobSandbox.path, 'rx'));
      final bobEngine = LibreShareEngine(
        self: DeviceInfo(
          deviceId: bobWiring.identity.identity.deviceId,
          alias: 'Bob',
          platform: 'linux',
        ),
        downloadDir: bobRxDir,
        bindAddress: InternetAddress('127.0.0.6'),
        preferredPort: 0,
        autoAccept: true,
        security: bobWiring,
        receiveConfig: const ReceiveConfig(initialMode: ReceiveAlways()),
      );
      await bobEngine.start();
      confirmSasOn(bobEngine);
      addTearDown(() => bobEngine.dispose(force: true));

      final bobDevice = DiscoveredDevice(
        info: bobEngine.deviceInfo,
        address: '127.0.0.6',
        lastSeen: DateTime.now(),
        source: DiscoverySource.manual,
      );

      final testFile = h.makeFile('document.txt', 256);
      final transfers = h.container.read(transfersProvider.notifier);
      final key = transfers.startSend(bobDevice, [h.pick(testFile)]);

      // Wait for receiver to refuse with PIN_REQUIRED
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final cur = transfers.find(key);
        if (cur != null && (cur.pinRequired || cur.isFinished)) break;
      }

      final viewBeforePin = transfers.find(key);
      expect(viewBeforePin, isNotNull, reason: 'transfer must exist in store');
      expect(
        viewBeforePin!.pinRequired,
        isTrue,
        reason: 'transfer must flag pinRequired when receiver enforces PIN',
      );
      expect(
        viewBeforePin.refusal,
        equals(LsErrorCode.pinRequired),
        reason: 'refusal must be pinRequired',
      );

      // When correct PIN is provided to the engine send, the transfer completes
      final resWithPin = await h.engine.sendFiles(
        [testFile],
        host: '127.0.0.6',
        port: bobEngine.port,
        pin: correctPin,
      );
      expect(
        resWithPin.isSuccess,
        isTrue,
        reason: 'sendFiles with correct PIN must succeed',
      );
      expect(
        File(pj(bobRxDir.path, 'document.txt')).existsSync(),
        isTrue,
        reason: 'the file arrived at Bob',
      );
    }, timeout: kSixtySeconds);

    testWidgets(
      'positive twin: sender-side PIN dialog (B1) renders when pinRequired is true and accepts 6 digits',
      (tester) async {
        final initialView = TransferView(
          key: 'pin-t1',
          sessionId: 's-pin-1',
          direction: TransferDirection.outgoing,
          phase: TransferPhase.waiting,
          peerAlias: 'Bob',
          peerPlatform: 'linux',
          peerAddress: '127.0.0.6',
          files: const [
            TransferFile(id: 'f1', name: 'document.txt', size: 256),
          ],
          createdAt: DateTime.now(),
          pinRequired: true,
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              transfersProvider.overrideWith(
                () => _FixedTransfers([initialView]),
              ),
            ],
            child: MaterialApp(
              theme: buildTheme(Brightness.light),
              home: const TransferScreen(transferKey: 'pin-t1'),
            ),
          ),
        );
        await tester.pump();

        // PIN dialog must be visible
        expect(
          find.byKey(const Key('pin-dialog')),
          findsOneWidget,
          reason: 'PIN dialog must be shown when pinRequired is true',
        );
        expect(find.byKey(const Key('pin-field')), findsOneWidget);

        // Enter 6 digits
        await tester.enterText(find.byKey(const Key('pin-field')), correctPin);
        await tester.pump();

        expect(find.text(correctPin), findsOneWidget);
        // A(7): typing alone proves nothing; the dialog must offer a real
        // submit (the end-to-end submit is in d1b_sender_dialog_test.dart).
        expect(
          find.byKey(const Key('pin-submit')),
          findsOneWidget,
          reason: 'S3: the dialog needs a submit button (pin-submit)',
        );
      },
      timeout: kSixtySeconds,
    );

    test('negative twin: wrong PIN causes refusal with pinInvalid and maps to "That PIN was not accepted." without attempt counts', () async {
      final h = await AppHarness.create();
      addTearDown(() => h.dispose());
      await h.boot();

      final bobSandbox = Directory.systemTemp.createTempSync('ls_bob_wrong_');
      addTearDown(() => bobSandbox.deleteSync(recursive: true));
      final bobSecDir = Directory(pj(bobSandbox.path, 'security'))
        ..createSync(recursive: true);

      final bobWiring = await SecurityWiring.open(
        directory: bobSecDir,
        deviceId: 'bob-secure-id-2',
        pinPolicy: const PinPolicy(mode: PinMode.fixed),
        pin: correctPin,
      );
      addTearDown(bobWiring.close);

      final bobRxDir = Directory(pj(bobSandbox.path, 'rx'));
      final bobEngine = LibreShareEngine(
        self: DeviceInfo(
          deviceId: bobWiring.identity.identity.deviceId,
          alias: 'Bob',
          platform: 'linux',
        ),
        downloadDir: bobRxDir,
        bindAddress: InternetAddress('127.0.0.7'),
        preferredPort: 0,
        security: bobWiring,
        receiveConfig: const ReceiveConfig(initialMode: ReceiveAlways()),
      );
      await bobEngine.start();
      confirmSasOn(bobEngine);
      addTearDown(() => bobEngine.dispose(force: true));

      final testFile = h.makeFile('wrong_doc.txt', 256);
      // Attempt send with wrong PIN '000000'
      final res = await h.engine.sendFiles(
        [testFile],
        host: '127.0.0.7',
        port: bobEngine.port,
        pin: '000000',
      );

      expect(res.isSuccess, isFalse, reason: 'Send with wrong PIN must fail');
      expect(res.failureReason, equals(FailureReason.rejected));
      expect(res.refusal, equals(LsErrorCode.pinInvalid));

      // Test the UI failureText mapping
      final failedView = TransferView(
        key: 'wrong-pin-t',
        sessionId: 's-wrong-pin',
        direction: TransferDirection.outgoing,
        phase: TransferPhase.failed,
        peerAlias: 'Bob',
        peerPlatform: 'linux',
        peerAddress: '127.0.0.7',
        files: const [TransferFile(id: 'f1', name: 'wrong_doc.txt', size: 256)],
        createdAt: DateTime.now(),
        failure: FailureReason.protocolError,
        refusal: LsErrorCode.pinInvalid,
      );

      final msg = failureText(failedView);
      expect(
        msg,
        equals('That PIN was not accepted.'),
        reason: 'pinInvalid must map to "That PIN was not accepted."',
      );

      // Security check: attempt counts must never be revealed
      final lower = msg.toLowerCase();
      for (final forbidden in const [
        'attempt',
        'tries',
        'remaining',
        'left',
        'strike',
      ]) {
        expect(
          lower.contains(forbidden),
          isFalse,
          reason: 'Must never disclose strike/attempt count: "$forbidden"',
        );
      }
    }, timeout: kSixtySeconds);

    test('positive twin: a trusted contact is exempt from the receiver PIN and sends directly without prompt', () async {
      final h = await AppHarness.create();
      addTearDown(() => h.dispose());
      await h.boot();

      final bobSandbox = Directory.systemTemp.createTempSync('ls_bob_exempt_');
      addTearDown(() => bobSandbox.deleteSync(recursive: true));
      final bobSecDir = Directory(pj(bobSandbox.path, 'security'))
        ..createSync(recursive: true);

      final bobWiring = await SecurityWiring.open(
        directory: bobSecDir,
        deviceId: 'bob-secure-id-3',
        pinPolicy: const PinPolicy(mode: PinMode.fixed, exemptContacts: true),
        pin: correctPin,
      );
      addTearDown(bobWiring.close);

      final bobRxDir = Directory(pj(bobSandbox.path, 'rx'));
      final bobEngine = LibreShareEngine(
        self: DeviceInfo(
          deviceId: bobWiring.identity.identity.deviceId,
          alias: 'Bob',
          platform: 'linux',
        ),
        downloadDir: bobRxDir,
        bindAddress: InternetAddress('127.0.0.8'),
        preferredPort: 0,
        autoAccept: true,
        security: bobWiring,
        receiveConfig: const ReceiveConfig(initialMode: ReceiveAlways()),
      );
      await bobEngine.start();
      confirmSasOn(bobEngine);
      addTearDown(() => bobEngine.dispose(force: true));

      // Pin Alice as a trusted contact in Bob's trust store
      final aliceFp =
          h.engine.identity?.fingerprint ?? h.engine.deviceInfo.fingerprint;
      expect(
        aliceFp.length,
        64,
        reason: 'Alice engine must have a 64-hex-digit fingerprint to pin as contact',
      );
      final aliceId = h.engine.identity?.deviceId ?? h.engine.self.deviceId;

      await bobWiring.trust.pin(
        deviceId: aliceId,
        fingerprint: aliceFp,
        alias: 'Alice',
        trust: PeerTrust.trusted,
      );

      final testFile = h.makeFile('exempt_doc.txt', 128);

      // Send without PIN from Alice to Bob
      final res = await h.engine.sendFiles(
        [testFile],
        host: '127.0.0.8',
        port: bobEngine.port,
      );

      expect(
        res.isSuccess,
        isTrue,
        reason:
            'transfer from trusted contact must succeed without entering PIN',
      );
    }, timeout: kSixtySeconds);
  });
}

class _FixedTransfers extends TransfersNotifier {
  _FixedTransfers(this._items);
  final List<TransferView> _items;

  @override
  List<TransferView> build() => _items;
}
