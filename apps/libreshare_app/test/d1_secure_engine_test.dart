// D1 secure engine tests: verifies that engineProvider builds a real secure
// engine with persistent identity, detects damaged keys, and rejects insecure peers.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/providers/transfers_provider.dart';
import 'package:libreshare_app/screens/transfer_screen.dart';
import 'package:libreshare_core/libreshare_core.dart';

import 'helpers/d1b_helpers.dart';
import 'helpers/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('engineProvider - secure profile and identity', () {
    test('positive twin: engine built by engineProvider has engine.identity != null and engine.deviceInfo.fingerprint non-empty', () async {
      final h = await AppHarness.create();
      addTearDown(() => h.dispose());
      await h.boot();

      final engine = h.engine;
      expect(
        engine.identity,
        isNotNull,
        reason: 'engineProvider must pass security: with an identity',
      );
      expect(
        engine.identity!.fingerprint,
        isNotEmpty,
        reason: 'identity must have non-empty fingerprint',
      );
      expect(
        engine.deviceInfo.fingerprint,
        isNotEmpty,
        reason: 'deviceInfo.fingerprint must be non-empty in secure profile',
      );
      expect(
        engine.deviceInfo.fingerprint,
        equals(engine.identity!.fingerprint),
      );
      expect(engine.ownFingerprint, isNotEmpty);
      expect(
        engine.deviceInfo.caps,
        containsAll(const ['sas', 'pair']),
        reason: 'secure profile must advertise sas and pair capabilities',
      );
    }, timeout: kSixtySeconds);

    test('negative twin: an engine built without security wiring has null identity and empty fingerprint', () async {
      final tempDir = Directory.systemTemp.createTempSync('ls_plaintext_');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final plaintextEngine = LibreShareEngine(
        self: const DeviceInfo(
          deviceId: 'plain-dev-1',
          alias: 'PlainDevice',
          platform: 'linux',
        ),
        downloadDir: tempDir,
      );
      addTearDown(() => plaintextEngine.dispose(force: true));

      expect(plaintextEngine.identity, isNull);
      expect(plaintextEngine.ownFingerprint, isEmpty);
      expect(plaintextEngine.deviceInfo.fingerprint, isEmpty);
      expect(plaintextEngine.deviceInfo.caps, isNot(contains('sas')));
    }, timeout: kSixtySeconds);
  });

  group('engineProvider - identity persistence across restarts', () {
    test('positive twin: second build with same support dir has the SAME fingerprint (identity persisted under <supportDir>/security)', () async {
      final h1 = await AppHarness.create();
      await h1.boot();

      final fp1 =
          h1.engine.identity?.fingerprint ?? h1.engine.deviceInfo.fingerprint;
      final securityDir = Directory(pj(h1.supportDir.path, 'security'));

      expect(
        securityDir.existsSync(),
        isTrue,
        reason: 'security directory must exist under supportDir',
      );
      expect(
        File(pj(securityDir.path, 'identity.json')).existsSync(),
        isTrue,
        reason: 'identity.json must exist in security directory',
      );
      await h1.dispose(deleteSandbox: false);

      final h2 = await AppHarness.create(reuseSandbox: h1.sandbox);
      addTearDown(() => h2.dispose());
      await h2.boot();

      final fp2 =
          h2.engine.identity?.fingerprint ?? h2.engine.deviceInfo.fingerprint;
      expect(fp1, isNotEmpty, reason: 'initial fingerprint must be non-empty');
      expect(
        fp2,
        equals(fp1),
        reason: 'rebuilt engine must reuse the persisted fingerprint',
      );
    }, timeout: kSixtySeconds);

    test('negative twin: a fresh support dir creates a different identity and fingerprint', () async {
      final h1 = await AppHarness.create();
      addTearDown(() => h1.dispose());
      await h1.boot();
      final fp1 =
          h1.engine.identity?.fingerprint ?? h1.engine.deviceInfo.fingerprint;

      final h2 = await AppHarness.create();
      addTearDown(() => h2.dispose());
      await h2.boot();
      final fp2 =
          h2.engine.identity?.fingerprint ?? h2.engine.deviceInfo.fingerprint;

      expect(fp1, isNotEmpty);
      expect(fp2, isNotEmpty);
      expect(
        fp2,
        isNot(equals(fp1)),
        reason: 'distinct support dirs must generate distinct identities',
      );
    }, timeout: kSixtySeconds);
  });

  group('engineProvider - damaged or missing private key', () {
    test(
      'positive twin: intact security directory loads identity cleanly',
      () async {
        final h1 = await AppHarness.create();
        await h1.boot();
        expect(h1.engine.identity, isNotNull);
        await h1.dispose(deleteSandbox: false);

        final h2 = await AppHarness.create(reuseSandbox: h1.sandbox);
        addTearDown(() => h2.dispose());
        await h2.boot();
        expect(h2.engine.identity, isNotNull);
      },
      timeout: kSixtySeconds,
    );

    test('negative twin: missing/damaged key causes provider to fail with IdentityLostException, not silently create new identity', () async {
      final h1 = await AppHarness.create();
      await h1.boot();
      final securityDir = Directory(pj(h1.supportDir.path, 'security'));
      final idJson = File(pj(securityDir.path, 'identity.json'));
      expect(
        idJson.existsSync(),
        isTrue,
        reason: 'identity.json must exist before corruption test',
      );
      final originalMetadata = idJson.readAsStringSync();
      await h1.dispose(deleteSandbox: false);

      // Find the secret key files and corrupt them
      final secrets = securityDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.secret'))
          .toList();
      expect(
        secrets,
        isNotEmpty,
        reason: 'secret file must be present in security directory',
      );
      for (final s in secrets) {
        s.writeAsStringSync('corrupt-private-key-bytes');
      }

      final h2 = await AppHarness.create(reuseSandbox: h1.sandbox);
      addTearDown(() => h2.dispose());

      await expectLater(
        h2.boot(),
        throwsA(isA<IdentityLostException>()),
        reason: 'damaged key must fail with IdentityLostException rather than regenerating',
      );
      // Ensure identity.json was not overwritten or replaced with a new identity
      expect(idJson.readAsStringSync(), equals(originalMetadata));
    }, timeout: kSixtySeconds);
  });

  group('engineProvider - insecure peer refusal', () {
    test('positive twin: allowInsecurePeers is false by default; a send to a plaintext peer (host:port path) is refused with InsecurePeerException, nothing is sent, and the older-version message is shown', () async {
      final h = await AppHarness.create();
      addTearDown(() => h.dispose());
      await h.boot();

      // A plaintext peer (startPeer uses LibreShareEngine without security:)
      final peer = await h.startPeer(
        'LegacyBob',
        mode: const ReceiveAlways(),
        discover: false,
      );
      final testFile = h.makeFile('sample.txt', 128);

      await expectLater(
        h.engine.sendFiles([testFile], host: peer.ip, port: peer.engine.port),
        throwsA(isA<InsecurePeerException>()),
        reason: 'allowInsecurePeers must be false: the downgrade is refused',
      );
      expect(
        peer.rx.existsSync() ? peer.rx.listSync() : const [],
        isEmpty,
        reason: 'nothing may reach a plaintext peer',
      );

      // The message the app shows for that refusal (TransferView.insecurePeer).
      final view = TransferView(
        key: 'insecure-t',
        direction: TransferDirection.outgoing,
        phase: TransferPhase.failed,
        peerAlias: 'LegacyBob',
        peerPlatform: 'android',
        peerAddress: peer.ip,
        files: const [TransferFile(id: 'f1', name: 'sample.txt', size: 128)],
        createdAt: DateTime.now(),
        failure: FailureReason.protocolError,
        insecurePeer: true,
      );
      expect(
        failureText(view),
        contains('uses an older version without encryption. Nothing was sent.'),
      );
    }, timeout: kSixtySeconds);

    // KNOWN LIMIT (docs/plans/d1-fixes.md Additions C, deferred): a plaintext
    // device chosen from the device list ends as noConnection, not as the
    // older-version text, because the engine's secure probe cannot resolve a
    // plaintext peer. It is fail-closed: this test pins only that.
    test('known limit: a plaintext device from the device list fails closed (nothing is sent, the transfer never completes)', () async {
      final h = await AppHarness.create();
      addTearDown(() => h.dispose());
      await h.boot();

      final peer = await h.startPeer('LegacyBob', mode: const ReceiveAlways());
      final testFile = h.makeFile('sample.txt', 128);
      final discovered = DiscoveredDevice(
        info: peer.engine.deviceInfo,
        address: peer.ip,
        lastSeen: DateTime.now(),
        source: DiscoverySource.manual,
      );
      final transfers = h.container.read(transfersProvider.notifier);
      final key = transfers.startSend(discovered, [h.pick(testFile)]);
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final cur = transfers.find(key);
        if (cur != null && cur.isFinished) break;
      }
      final transfer = transfers.find(key);
      expect(transfer, isNotNull);
      expect(transfer!.isFinished, isTrue, reason: 'the send ended');
      expect(
        transfer.phase,
        isNot(TransferPhase.completed),
        reason: 'a plaintext peer must never receive the files',
      );
      expect(peer.rx.existsSync() ? peer.rx.listSync() : const [], isEmpty);
    }, timeout: kSixtySeconds);

    test(
      'negative twin: secure peer transfer does not report insecurePeer error',
      () async {
        final h = await AppHarness.create();
        addTearDown(() => h.dispose());
        await h.boot();

        final peerSandbox = Directory.systemTemp.createTempSync(
          'ls_secure_peer_',
        );
        addTearDown(() => peerSandbox.deleteSync(recursive: true));
        final peerSecDir = Directory(pj(peerSandbox.path, 'security'))
          ..createSync(recursive: true);
        final peerWiring = await SecurityWiring.open(
          directory: peerSecDir,
          deviceId: 'secure-peer-1',
        );
        addTearDown(() => peerWiring.close());

        final peerEngine = LibreShareEngine(
          self: DeviceInfo(
            deviceId: peerWiring.identity.identity.deviceId,
            alias: 'SecureBob',
            platform: 'linux',
          ),
          downloadDir: Directory(pj(peerSandbox.path, 'rx')),
          bindAddress: InternetAddress('127.0.0.5'),
          preferredPort: 0,
          security: peerWiring,
          receiveConfig: const ReceiveConfig(initialMode: ReceiveAlways()),
        );
        await peerEngine.start();
        addTearDown(() => peerEngine.dispose(force: true));

        final discovered = DiscoveredDevice(
          info: peerEngine.deviceInfo,
          address: '127.0.0.5',
          lastSeen: DateTime.now(),
          source: DiscoverySource.manual,
        );

        final transfers = h.container.read(transfersProvider.notifier);
        final testFile = h.makeFile('sample2.txt', 128);
        final key = transfers.startSend(discovered, [h.pick(testFile)]);

        await Future<void>.delayed(const Duration(milliseconds: 300));
        final transfer = transfers.find(key);
        expect(transfer?.insecurePeer, isFalse);
      },
      timeout: kSixtySeconds,
    );
  });
}
