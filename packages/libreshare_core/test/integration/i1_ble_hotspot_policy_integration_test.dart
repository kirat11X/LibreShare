// Increment 7 / Integration Card I1: BLE & Hotspot Policy Integration Suite.
// Verifies chooseHost 3x3 platform matrix, uplink preservation, receiver tie-breaker,
// HotspotCandidate setup/teardown lifecycle, and ConnectionManager tier fallback.
@TestOn('vm')
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:libreshare_core/src/ble/beacon_types.dart';
import 'package:libreshare_core/src/ble/host_policy.dart';
import 'package:libreshare_core/src/ble/testing/fake_hotspot.dart';
import 'package:test/test.dart';

class _MockPeerClient implements PeerClient {
  _MockPeerClient({this.isAlive = true});
  bool isAlive;
  bool closed = false;

  @override
  Future<DeviceInfo> info() async {
    if (!isAlive) throw const ConnectionException('Simulated link disconnect');
    return const DeviceInfo(
      deviceId: 'remote-device',
      alias: 'RemotePeer',
      platform: 'linux',
      port: 53318,
    );
  }

  @override
  void close() {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('I1: BLE & Hotspot Policy Integration Suite', () {
    late FakeAir air;
    late FakeHotspotBackend backendHost;
    late FakeHotspotBackend backendJoiner;

    setUp(() {
      air = FakeAir();
      backendHost = FakeHotspotBackend(air: air);
      backendJoiner = FakeHotspotBackend(air: air);
    });

    test('1. Platform matrix & uplink priority drive deterministic hotspot host election', () {
      // Rule 1: Only one side capable -> capable side always wins
      const capCanHost = BeaconCap(canHost: true, platform: BlePlatform.linux);
      const capCannotHost = BeaconCap(
        canHost: false,
        platform: BlePlatform.android,
      );

      expect(
        chooseHost(capA: capCanHost, capB: capCannotHost, isReceiverA: false),
        HostWinner.sideA,
      );
      expect(
        chooseHost(capA: capCannotHost, capB: capCanHost, isReceiverA: true),
        HostWinner.sideB,
      );
      expect(
        chooseHost(capA: capCannotHost, capB: capCannotHost, isReceiverA: true),
        HostWinner.neither,
      );

      // Rule 2: hostKeepsUplink priority overrides platform ranking
      const capUplinkA = BeaconCap(
        canHost: true,
        platform: BlePlatform.linux,
        hostKeepsUplink: true,
      );
      const capStandardB = BeaconCap(
        canHost: true,
        platform: BlePlatform.android,
        hostKeepsUplink: false,
      );
      expect(
        chooseHost(capA: capUplinkA, capB: capStandardB, isReceiverA: false),
        HostWinner.sideA,
      );

      // Rule 3: Tie breaker -> receiver hosts so sender connects
      const capLinuxA = BeaconCap(canHost: true, platform: BlePlatform.linux);
      const capLinuxB = BeaconCap(canHost: true, platform: BlePlatform.linux);
      expect(
        chooseHost(capA: capLinuxA, capB: capLinuxB, isReceiverA: true),
        HostWinner.sideA,
      );
      expect(
        chooseHost(capA: capLinuxA, capB: capLinuxB, isReceiverA: false),
        HostWinner.sideB,
      );
    });

    test('2. FakeHotspot simulation: SSID broadcast, join, PSK validation and disconnect', () async {
      final reservation = await backendHost.startHotspot(
        ssid: 'DIRECT-LS-HOTSPOT',
        psk: 'secret123',
      );
      expect(backendHost.activeReservationsCount, equals(1));

      // Wrong PSK throws StateError
      expect(
        () => backendJoiner.joinHotspot(
          ssid: 'DIRECT-LS-HOTSPOT',
          psk: 'badPassword',
        ),
        throwsA(isA<StateError>()),
      );

      // Correct PSK joins successfully
      await backendJoiner.joinHotspot(
        ssid: 'DIRECT-LS-HOTSPOT',
        psk: 'secret123',
      );
      expect(backendJoiner.activeJoinsCount, equals(1));

      // Network severed via RF air cut
      air.cut('DIRECT-LS-HOTSPOT');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(backendJoiner.activeJoinsCount, equals(0));

      await reservation.stop();
      expect(backendHost.activeReservationsCount, equals(0));
    });

    test('3. HotspotCandidate asserts setup on open and guaranteed teardown on close', () async {
      var setupCalls = 0;
      var teardownCalls = 0;

      final hotspotCandidate = HotspotCandidate(
        id: 'c_hotspot_i1',
        host: '192.168.49.1',
        port: 53318,
        peerFingerprint: 'AA' * 32,
        role: HotspotRole.join,
        ssid: 'DIRECT-LS-TEST',
        psk: 'pass123',
        validUntil: DateTime.now().add(const Duration(minutes: 5)),
        offerId: 'offer_i1_test',
        onSetup: () async => setupCalls++,
        onTeardown: () async => teardownCalls++,
      );

      final mockClient = _MockPeerClient();
      final conn = HttpConnection(
        candidate: hotspotCandidate,
        clientFactory: (cand, sec) => mockClient,
      );

      final client = await conn.open();
      expect(client, isNotNull);
      expect(setupCalls, equals(1));
      expect(teardownCalls, equals(0));

      await conn.close();
      expect(teardownCalls, equals(1));
    });

    test('4. ConnectionManager switches tiers from severed Hotspot to Wi-Fi candidate', () async {
      var hotspotTeardowns = 0;

      final hotspotCand = HotspotCandidate(
        id: 'tier1_hotspot',
        host: '192.168.49.1',
        port: 53318,
        peerFingerprint: 'AA' * 32,
        role: HotspotRole.join,
        ssid: 'DIRECT-LS-CUT',
        psk: 'pass123',
        validUntil: DateTime.now().add(const Duration(minutes: 5)),
        offerId: 'offer_cut',
        onSetup: () async {},
        onTeardown: () async => hotspotTeardowns++,
      );

      final wifiCand = Candidate(
        id: 'tier2_wifi',
        kind: CandidateKind.wifi,
        host: '192.168.1.150',
        port: 53318,
        peerFingerprint: 'AA' * 32,
        costHint: 25, // Lower priority than hotspot (cost 15)
      );

      final mockHotspotClient = _MockPeerClient(isAlive: true);
      final mockWifiClient = _MockPeerClient(isAlive: true);

      final manager = ConnectionManager(
        candidates: [hotspotCand, wifiCand],
        connectionFactory: (candidate, security) {
          if (candidate.kind == CandidateKind.hotspot) {
            return HttpConnection(
              candidate: candidate,
              clientFactory: (_, _) => mockHotspotClient,
            );
          } else {
            return HttpConnection(
              candidate: candidate,
              clientFactory: (_, _) => mockWifiClient,
            );
          }
        },
      );

      final events = <ChannelEvent>[];
      final sub = manager.events.listen(events.add);
      addTearDown(sub.cancel);

      // Connects first to Hotspot (cost 15)
      await manager.connect();
      expect(manager.activeCandidate?.kind, equals(CandidateKind.hotspot));

      // Hotspot drops
      mockHotspotClient.isAlive = false;

      // Fallback to secondary tier (Wi-Fi)
      final fallbackClient = await manager.fallbackToNext(
        reason: 'hotspot_signal_lost',
      );
      expect(fallbackClient, same(mockWifiClient));
      expect(manager.activeCandidate?.kind, equals(CandidateKind.wifi));
      expect(hotspotTeardowns, equals(1));

      // Emitted ChannelTierSwitched event
      await Future<void>.delayed(Duration.zero);
      final tierSwitches = events.whereType<ChannelTierSwitched>().toList();
      expect(tierSwitches, hasLength(1));
      expect(
        tierSwitches.first.fromCandidate?.kind,
        equals(CandidateKind.hotspot),
      );
      expect(tierSwitches.first.toCandidate.kind, equals(CandidateKind.wifi));
      expect(tierSwitches.first.reason, equals('hotspot_signal_lost'));

      await manager.close();
      expect(hotspotTeardowns, equals(1));
    });
  });
}
