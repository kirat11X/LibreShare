// Proof for mutant M111: with NO consent handler an unpaired BLE peer must be declined.
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:libreshare_core/src/ble/ble_coordinator.dart';
import 'package:libreshare_core/src/ble/ble_messages.dart';
import 'package:libreshare_core/src/ble/testing/fake_ble_bus.dart';
import 'package:test/test.dart';

void main() {
  test('unpaired offer without a prompt handler is declined', () async {
    final bus = FakeBleBus();
    final idAlice = KeyIdentity.fromGenerated(generateIdentityFor('alice-dev'));
    final idBob = KeyIdentity.fromGenerated(generateIdentityFor('bob-dev'));
    final advA = Uint8List.fromList(List.generate(32, (i) => i));
    final advB = Uint8List.fromList(List.generate(32, (i) => 255 - i));
    final alice = BleCoordinator(
      self: const DeviceInfo(
        deviceId: 'alice-dev',
        alias: 'Alice',
        platform: 'linux',
      ),
      identity: idAlice,
      trustStore: InMemoryTrustStore(),
      peerRegistry: PeerRegistry(selfDeviceId: 'alice-dev'),
      bleBackend: bus.createBackend(deviceId: 'dev_alice', address: 'AA:01'),
      advKey: advA,
      localLanCandidates: () => [],
      probeLanCandidate: (c) async => true,
    );
    final bob = BleCoordinator(
      self: const DeviceInfo(
        deviceId: 'bob-dev',
        alias: 'Bob',
        platform: 'android',
      ),
      identity: idBob,
      trustStore: InMemoryTrustStore(),
      peerRegistry: PeerRegistry(selfDeviceId: 'bob-dev'),
      bleBackend: bus.createBackend(deviceId: 'dev_bob', address: 'BB:02'),
      advKey: advB,
      localLanCandidates: () => [
        const LanCandidate(ip: '192.168.1.60', port: 53319),
      ],
      // no onTransferPrompt: default rule must decline an unpaired sender
    );
    await alice.start();
    await bob.start();
    final result = await alice.sendOffer(
      peerDeviceId: 'dev_bob',
      offer: const BleOffer(
        offerId: 'o1',
        fileCount: 1,
        totalSize: 10,
        firstName: 'a.txt',
      ),
      onConfirmSas: (sas) async => true,
    );
    expect(result.accepted, isFalse);
    await alice.stop();
    await bob.stop();
  });
}
