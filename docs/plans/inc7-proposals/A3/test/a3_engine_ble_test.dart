import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:libreshare_core/src/ble/ble_coordinator.dart';
import 'package:libreshare_core/src/ble/ble_messages.dart';
import 'package:libreshare_core/src/ble/testing/fake_ble_bus.dart';
import 'package:libreshare_core/src/ble/visibility_manager.dart';
import 'package:test/test.dart';

void main() {
  late FakeBleBus bus;
  late Directory tempDir;
  late KeyIdentity idAlice;
  late KeyIdentity idBob;
  late InMemoryTrustStore trustAlice;
  late InMemoryTrustStore trustBob;
  late Uint8List advKeyAlice;
  late Uint8List advKeyBob;

  setUp(() async {
    bus = FakeBleBus();
    tempDir = await Directory.systemTemp.createTemp('ls_ble_a3_');

    idAlice = KeyIdentity.fromGenerated(generateIdentityFor('alice-dev'));
    idBob = KeyIdentity.fromGenerated(generateIdentityFor('bob-dev'));

    trustAlice = InMemoryTrustStore();
    trustBob = InMemoryTrustStore();

    advKeyAlice = Uint8List.fromList(List.generate(32, (i) => i));
    advKeyBob = Uint8List.fromList(List.generate(32, (i) => 255 - i));
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('BleCoordinator & Engine Discovery', () {
    test('Discovered BLE advertisements enter PeerRegistry with DiscoverySource.ble', () async {
      final backendAlice = bus.createBackend(
        deviceId: 'dev_alice',
        address: 'AA:01',
      );
      final backendBob = bus.createBackend(
        deviceId: 'dev_bob',
        address: 'BB:02',
      );

      final regAlice = PeerRegistry(selfDeviceId: 'alice-dev');

      final coordAlice = BleCoordinator(
        self: const DeviceInfo(
          deviceId: 'alice-dev',
          alias: 'Alice',
          platform: 'linux',
        ),
        identity: idAlice,
        trustStore: trustAlice,
        peerRegistry: regAlice,
        bleBackend: backendAlice,
        advKey: advKeyAlice,
        localLanCandidates: () => [],
      );

      final visibilityBob = VisibilityManager(advKey: advKeyBob);
      final coordBob = BleCoordinator(
        self: const DeviceInfo(
          deviceId: 'bob-dev',
          alias: 'Bob',
          platform: 'android',
        ),
        identity: idBob,
        trustStore: trustBob,
        peerRegistry: PeerRegistry(selfDeviceId: 'bob-dev'),
        bleBackend: backendBob,
        advKey: advKeyBob,
        visibility: visibilityBob,
        localLanCandidates: () => [],
      );

      await coordAlice.start();
      await coordBob.start();

      // Bob makes himself visible to everyone
      visibilityBob.setEveryone();

      // Await discovery event in Alice's registry
      final discoveredEvent = await regAlice.events
          .where((e) => e is DeviceFound)
          .cast<DeviceFound>()
          .first
          .timeout(const Duration(seconds: 5));

      expect(discoveredEvent.device.source, DiscoverySource.ble);
      expect(discoveredEvent.device.info.platform, 'ble');

      await coordAlice.stop();
      await coordBob.stop();
    });

    test(
      'Trusted contact EID resolves directly to pinned contact alias',
      () async {
        final backendAlice = bus.createBackend(
          deviceId: 'dev_alice',
          address: 'AA:01',
        );
        final backendBob = bus.createBackend(
          deviceId: 'dev_bob',
          address: 'BB:02',
        );

        // Alice pins Bob as trusted contact
        await trustAlice.pin(
          deviceId: 'bob-dev',
          fingerprint: idBob.identity.fingerprint,
          alias: 'Bob (Trusted Phone)',
          trust: PeerTrust.trusted,
        );

        final regAlice = PeerRegistry(selfDeviceId: 'alice-dev');

        final coordAlice = BleCoordinator(
          self: const DeviceInfo(
            deviceId: 'alice-dev',
            alias: 'Alice',
            platform: 'linux',
          ),
          identity: idAlice,
          trustStore: trustAlice,
          peerRegistry: regAlice,
          bleBackend: backendAlice,
          advKey: advKeyAlice,
          localLanCandidates: () => [],
          getPeerAdvKey: (deviceId) => deviceId == 'bob-dev' ? advKeyBob : null,
        );

        final visibilityBob = VisibilityManager(advKey: advKeyBob);
        final coordBob = BleCoordinator(
          self: const DeviceInfo(
            deviceId: 'bob-dev',
            alias: 'Bob',
            platform: 'android',
          ),
          identity: idBob,
          trustStore: trustBob,
          peerRegistry: PeerRegistry(selfDeviceId: 'bob-dev'),
          bleBackend: backendBob,
          advKey: advKeyBob,
          visibility: visibilityBob,
          localLanCandidates: () => [],
        );

        await coordAlice.start();
        await coordBob.start();

        // Bob enables Contacts visibility
        visibilityBob.setContacts();

        final discoveredEvent = await regAlice.events
            .where((e) => e is DeviceFound)
            .cast<DeviceFound>()
            .first
            .timeout(const Duration(seconds: 5));

        expect(discoveredEvent.device.source, DiscoverySource.ble);
        expect(discoveredEvent.device.info.deviceId, 'bob-dev');
        expect(discoveredEvent.device.info.alias, 'Bob (Trusted Phone)');

        await coordAlice.stop();
        await coordBob.stop();
      },
    );
  });

  group('BleCoordinator Transfer Handshake, Consent & Fast LAN Handoff', () {
    test('Paired transfer automatically verifies identity and bypasses to direct LAN', () async {
      final backendAlice = bus.createBackend(
        deviceId: 'dev_alice',
        address: 'AA:01',
      );
      final backendBob = bus.createBackend(
        deviceId: 'dev_bob',
        address: 'BB:02',
      );

      // Mutual trust
      await trustAlice.pin(
        deviceId: 'bob-dev',
        fingerprint: idBob.identity.fingerprint,
        alias: 'Bob',
        trust: PeerTrust.trusted,
      );
      await trustBob.pin(
        deviceId: 'alice-dev',
        fingerprint: idAlice.identity.fingerprint,
        alias: 'Alice',
        trust: PeerTrust.trusted,
      );

      final coordAlice = BleCoordinator(
        self: const DeviceInfo(
          deviceId: 'alice-dev',
          alias: 'Alice',
          platform: 'linux',
        ),
        identity: idAlice,
        trustStore: trustAlice,
        peerRegistry: PeerRegistry(selfDeviceId: 'alice-dev'),
        bleBackend: backendAlice,
        advKey: advKeyAlice,
        localLanCandidates: () => [
          const LanCandidate(ip: '192.168.1.50', port: 53318),
        ],
        probeLanCandidate: (candidate) async =>
            true, // Simulated successful LAN ping
      );

      bool bobPromptShown = false;
      final coordBob = BleCoordinator(
        self: const DeviceInfo(
          deviceId: 'bob-dev',
          alias: 'Bob',
          platform: 'android',
        ),
        identity: idBob,
        trustStore: trustBob,
        peerRegistry: PeerRegistry(selfDeviceId: 'bob-dev'),
        bleBackend: backendBob,
        advKey: advKeyBob,
        localLanCandidates: () => [
          const LanCandidate(ip: '192.168.1.60', port: 53319),
        ],
        onTransferPrompt: (prompt) async {
          bobPromptShown = true;
          expect(prompt.isPaired, isTrue);
          expect(prompt.peerAlias, 'Alice');
          return true; // Auto-accept paired transfer
        },
      );

      await coordAlice.start();
      await coordBob.start();

      const offer = BleOffer(
        offerId: 'offer_paired_1',
        fileCount: 1,
        totalSize: 1048576,
        firstName: 'project.tar.gz',
      );

      final result = await coordAlice.sendOffer(
        peerDeviceId: 'dev_bob',
        offer: offer,
      );

      expect(result.accepted, isTrue);
      expect(result.routeKind, BleRouteKind.lan);
      expect(result.lanCandidate?.ip, '192.168.1.60');
      expect(result.lanCandidate?.port, 53319);
      expect(bobPromptShown, isTrue);

      await coordAlice.stop();
      await coordBob.stop();
    });

    test('Unpaired transfer requires SAS code and explicit consent', () async {
      final backendAlice = bus.createBackend(
        deviceId: 'dev_alice',
        address: 'AA:01',
      );
      final backendBob = bus.createBackend(
        deviceId: 'dev_bob',
        address: 'BB:02',
      );

      // Neither side is pinned in trustStore (unpaired)
      final coordAlice = BleCoordinator(
        self: const DeviceInfo(
          deviceId: 'alice-dev',
          alias: 'Alice',
          platform: 'linux',
        ),
        identity: idAlice,
        trustStore: trustAlice,
        peerRegistry: PeerRegistry(selfDeviceId: 'alice-dev'),
        bleBackend: backendAlice,
        advKey: advKeyAlice,
        localLanCandidates: () => [],
        probeLanCandidate: (candidate) async => true,
      );

      String? bobSeenSas;
      final coordBob = BleCoordinator(
        self: const DeviceInfo(
          deviceId: 'bob-dev',
          alias: 'Bob',
          platform: 'android',
        ),
        identity: idBob,
        trustStore: trustBob,
        peerRegistry: PeerRegistry(selfDeviceId: 'bob-dev'),
        bleBackend: backendBob,
        advKey: advKeyBob,
        localLanCandidates: () => [
          const LanCandidate(ip: '192.168.1.60', port: 53319),
        ],
        onTransferPrompt: (prompt) async {
          expect(prompt.isPaired, isFalse);
          bobSeenSas = prompt.sasCode;
          return true; // User accepts after verifying SAS
        },
      );

      await coordAlice.start();
      await coordBob.start();

      String? aliceSeenSas;
      const offer = BleOffer(
        offerId: 'offer_unpaired_1',
        fileCount: 2,
        totalSize: 200,
        firstName: 'photo.jpg',
      );

      final result = await coordAlice.sendOffer(
        peerDeviceId: 'dev_bob',
        offer: offer,
        onConfirmSas: (sas) async {
          aliceSeenSas = sas;
          return true;
        },
      );

      expect(result.accepted, isTrue);
      expect(aliceSeenSas, isNotNull);
      expect(bobSeenSas, isNotNull);
      expect(aliceSeenSas, equals(bobSeenSas)); // Identical SAS code confirmed!

      await coordAlice.stop();
      await coordBob.stop();
    });

    test(
      'Unpaired transfer rejection terminates session with zero side effects',
      () async {
        final backendAlice = bus.createBackend(
          deviceId: 'dev_alice',
          address: 'AA:01',
        );
        final backendBob = bus.createBackend(
          deviceId: 'dev_bob',
          address: 'BB:02',
        );

        final coordAlice = BleCoordinator(
          self: const DeviceInfo(
            deviceId: 'alice-dev',
            alias: 'Alice',
            platform: 'linux',
          ),
          identity: idAlice,
          trustStore: trustAlice,
          peerRegistry: PeerRegistry(selfDeviceId: 'alice-dev'),
          bleBackend: backendAlice,
          advKey: advKeyAlice,
          localLanCandidates: () => [],
        );

        final coordBob = BleCoordinator(
          self: const DeviceInfo(
            deviceId: 'bob-dev',
            alias: 'Bob',
            platform: 'android',
          ),
          identity: idBob,
          trustStore: trustBob,
          peerRegistry: PeerRegistry(selfDeviceId: 'bob-dev'),
          bleBackend: backendBob,
          advKey: advKeyBob,
          localLanCandidates: () => [
            const LanCandidate(ip: '192.168.1.60', port: 53319),
          ],
          onTransferPrompt: (prompt) async {
            // User explicitly declines/rejects the transfer
            return false;
          },
        );

        await coordAlice.start();
        await coordBob.start();

        const offer = BleOffer(
          offerId: 'offer_rejected_1',
          fileCount: 1,
          totalSize: 100,
          firstName: 'unwanted.exe',
        );

        final result = await coordAlice.sendOffer(
          peerDeviceId: 'dev_bob',
          offer: offer,
        );

        expect(result.accepted, isFalse);
        expect(result.rejectionReason, contains('Declined'));

        await coordAlice.stop();
        await coordBob.stop();
      },
    );

    test(
      'SAS confirmation cancellation on Central aborts transfer immediately',
      () async {
        final backendAlice = bus.createBackend(
          deviceId: 'dev_alice',
          address: 'AA:01',
        );
        final backendBob = bus.createBackend(
          deviceId: 'dev_bob',
          address: 'BB:02',
        );

        final coordAlice = BleCoordinator(
          self: const DeviceInfo(
            deviceId: 'alice-dev',
            alias: 'Alice',
            platform: 'linux',
          ),
          identity: idAlice,
          trustStore: trustAlice,
          peerRegistry: PeerRegistry(selfDeviceId: 'alice-dev'),
          bleBackend: backendAlice,
          advKey: advKeyAlice,
          localLanCandidates: () => [],
        );

        final coordBob = BleCoordinator(
          self: const DeviceInfo(
            deviceId: 'bob-dev',
            alias: 'Bob',
            platform: 'android',
          ),
          identity: idBob,
          trustStore: trustBob,
          peerRegistry: PeerRegistry(selfDeviceId: 'bob-dev'),
          bleBackend: backendBob,
          advKey: advKeyBob,
          localLanCandidates: () => [],
          onTransferPrompt: (prompt) async => true,
        );

        await coordAlice.start();
        await coordBob.start();

        const offer = BleOffer(
          offerId: 'offer_sas_cancel',
          fileCount: 1,
          totalSize: 100,
          firstName: 'test.dat',
        );

        final result = await coordAlice.sendOffer(
          peerDeviceId: 'dev_bob',
          offer: offer,
          onConfirmSas: (sas) async =>
              false, // Central user cancels/rejects SAS
        );

        expect(result.accepted, isFalse);
        expect(
          result.rejectionReason,
          contains('SAS code verification rejected'),
        );

        await coordAlice.stop();
        await coordBob.stop();
      },
    );

    test(
      'When LAN candidates are unreachable, route resolves to hotspot',
      () async {
        final backendAlice = bus.createBackend(
          deviceId: 'dev_alice',
          address: 'AA:01',
        );
        final backendBob = bus.createBackend(
          deviceId: 'dev_bob',
          address: 'BB:02',
        );

        final coordAlice = BleCoordinator(
          self: const DeviceInfo(
            deviceId: 'alice-dev',
            alias: 'Alice',
            platform: 'linux',
          ),
          identity: idAlice,
          trustStore: trustAlice,
          peerRegistry: PeerRegistry(selfDeviceId: 'alice-dev'),
          bleBackend: backendAlice,
          advKey: advKeyAlice,
          localLanCandidates: () => [],
          probeLanCandidate: (candidate) async =>
              false, // LAN unreachable (e.g. AP isolation)
        );

        final coordBob = BleCoordinator(
          self: const DeviceInfo(
            deviceId: 'bob-dev',
            alias: 'Bob',
            platform: 'android',
          ),
          identity: idBob,
          trustStore: trustBob,
          peerRegistry: PeerRegistry(selfDeviceId: 'bob-dev'),
          bleBackend: backendBob,
          advKey: advKeyBob,
          localLanCandidates: () => [
            const LanCandidate(ip: '10.99.99.1', port: 53318),
          ],
          onTransferPrompt: (prompt) async => true,
        );

        await coordAlice.start();
        await coordBob.start();

        const offer = BleOffer(
          offerId: 'offer_ap_isolated_1',
          fileCount: 1,
          totalSize: 100,
          firstName: 'f.txt',
        );

        final result = await coordAlice.sendOffer(
          peerDeviceId: 'dev_bob',
          offer: offer,
        );

        expect(result.accepted, isTrue);
        expect(
          result.routeKind,
          BleRouteKind.hotspot,
        ); // Hotspot handoff required!

        await coordAlice.stop();
        await coordBob.stop();
      },
    );

    test('Two LibreShareEngine instances in one process communicate over FakeBleBus', () async {
      final backendAlice = bus.createBackend(
        deviceId: 'eng_alice',
        address: 'AA:11',
      );
      final backendBob = bus.createBackend(
        deviceId: 'eng_bob',
        address: 'BB:22',
      );

      final dirAlice = Directory('${tempDir.path}/alice')..createSync();
      final dirBob = Directory('${tempDir.path}/bob')..createSync();

      Completer<bool>? promptCompleter;

      final engineAlice = LibreShareEngine(
        self: const DeviceInfo(
          deviceId: 'alice-eng',
          alias: 'Alice Laptop',
          platform: 'linux',
        ),
        downloadDir: dirAlice,
        preferredPort: 0,
        discovery: DiscoveryConfig(
          enabled: true,
          bleBackend: backendAlice,
          advKey: advKeyAlice,
        ),
      );

      final engineBob = LibreShareEngine(
        self: const DeviceInfo(
          deviceId: 'bob-eng',
          alias: 'Bob Phone',
          platform: 'android',
        ),
        downloadDir: dirBob,
        preferredPort: 0,
        discovery: DiscoveryConfig(
          enabled: true,
          bleBackend: backendBob,
          advKey: advKeyBob,
          onBleTransferPrompt: (prompt) async {
            final completer = promptCompleter;
            if (completer != null) {
              return completer.future;
            }
            return true;
          },
        ),
      );

      await engineAlice.start();
      await engineBob.start();

      expect(engineAlice.bleCoordinator, isNotNull);
      expect(engineBob.bleCoordinator, isNotNull);

      // Bob's visibility is set to Everyone (advertising OPEN beacon)
      engineBob.bleCoordinator!.visibility.setEveryone();

      // Alice discovers Bob via BLE in her devices list
      final discoveredList = await engineAlice.devices
          .where((list) => list.any((d) => d.source == DiscoverySource.ble))
          .first
          .timeout(const Duration(seconds: 5));

      final bleDevice = discoveredList.firstWhere(
        (d) => d.source == DiscoverySource.ble,
      );
      expect(bleDevice.source, DiscoverySource.ble);

      // Now Alice sends an offer to Bob
      promptCompleter = Completer<bool>();

      final sendFuture = engineAlice.bleCoordinator!.sendOffer(
        peerDeviceId: 'eng_bob',
        offer: const BleOffer(
          offerId: 'eng_offer_1',
          fileCount: 1,
          totalSize: 50,
          firstName: 'doc.txt',
        ),
      );

      // Bob accepts the prompt
      await Future<void>.delayed(const Duration(milliseconds: 50));
      promptCompleter.complete(true);

      final result = await sendFuture;
      expect(result.accepted, isTrue);

      await engineAlice.stop();
      await engineBob.stop();
    });
  });
}
