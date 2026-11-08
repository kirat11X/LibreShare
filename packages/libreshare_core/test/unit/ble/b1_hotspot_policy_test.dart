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
    if (!isAlive) throw const ConnectionException('Simulated network cut');
    return const DeviceInfo(
      deviceId: 'remote-dev',
      alias: 'Remote',
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
  group('host_policy.chooseHost (All 3x3 platform pairs & uplink rules)', () {
    test('Only one side canHost elections', () {
      const canHost = BeaconCap(canHost: true, platform: BlePlatform.linux);
      const cannotHost = BeaconCap(
        canHost: false,
        platform: BlePlatform.android,
      );

      expect(
        chooseHost(capA: canHost, capB: cannotHost, isReceiverA: false),
        HostWinner.sideA,
      );
      expect(
        chooseHost(capA: cannotHost, capB: canHost, isReceiverA: true),
        HostWinner.sideB,
      );
      expect(
        chooseHost(capA: cannotHost, capB: cannotHost, isReceiverA: true),
        HostWinner.neither,
      );
    });

    test('hostKeepsUplink priority overrides platform ranking', () {
      // B is Android (higher rank), but A is Linux with hostKeepsUplink (Ethernet/cellular)
      const capA = BeaconCap(
        canHost: true,
        hostKeepsUplink: true,
        platform: BlePlatform.linux,
      );
      const capB = BeaconCap(
        canHost: true,
        hostKeepsUplink: false,
        platform: BlePlatform.android,
      );

      expect(
        chooseHost(capA: capA, capB: capB, isReceiverA: false),
        HostWinner.sideA,
      );
      expect(
        chooseHost(capA: capB, capB: capA, isReceiverA: true),
        HostWinner.sideB,
      );
    });

    test('Exhaustive 3x3 platform matrix (Android > Linux > Windows)', () {
      const android = BeaconCap(canHost: true, platform: BlePlatform.android);
      const linux = BeaconCap(canHost: true, platform: BlePlatform.linux);
      const windows = BeaconCap(canHost: true, platform: BlePlatform.windows);

      // Android vs Linux -> Android wins
      expect(
        chooseHost(capA: android, capB: linux, isReceiverA: false),
        HostWinner.sideA,
      );
      expect(
        chooseHost(capA: linux, capB: android, isReceiverA: true),
        HostWinner.sideB,
      );

      // Android vs Windows -> Android wins
      expect(
        chooseHost(capA: android, capB: windows, isReceiverA: false),
        HostWinner.sideA,
      );
      expect(
        chooseHost(capA: windows, capB: android, isReceiverA: true),
        HostWinner.sideB,
      );

      // Linux vs Windows -> Linux wins
      expect(
        chooseHost(capA: linux, capB: windows, isReceiverA: false),
        HostWinner.sideA,
      );
      expect(
        chooseHost(capA: windows, capB: linux, isReceiverA: true),
        HostWinner.sideB,
      );
    });

    test('Platform tie-breaker selects the receiver', () {
      const linux1 = BeaconCap(canHost: true, platform: BlePlatform.linux);
      const linux2 = BeaconCap(canHost: true, platform: BlePlatform.linux);

      // Linux vs Linux: when A is receiver, A wins
      expect(
        chooseHost(capA: linux1, capB: linux2, isReceiverA: true),
        HostWinner.sideA,
      );
      // When B is receiver, B wins
      expect(
        chooseHost(capA: linux1, capB: linux2, isReceiverA: false),
        HostWinner.sideB,
      );

      const android1 = BeaconCap(canHost: true, platform: BlePlatform.android);
      const android2 = BeaconCap(canHost: true, platform: BlePlatform.android);

      expect(
        chooseHost(capA: android1, capB: android2, isReceiverA: true),
        HostWinner.sideA,
      );
      expect(
        chooseHost(capA: android1, capB: android2, isReceiverA: false),
        HostWinner.sideB,
      );
    });
  });

  group('FakeHotspotBackend & FakeAir lifecycle', () {
    late FakeAir air;
    late FakeHotspotBackend backendHost;
    late FakeHotspotBackend backendJoiner;

    setUp(() {
      air = FakeAir();
      backendHost = FakeHotspotBackend(air: air);
      backendJoiner = FakeHotspotBackend(air: air);
    });

    tearDown(() async {
      await backendHost.dispose();
      await backendJoiner.dispose();
    });

    test(
      'startHotspot registers network on FakeAir and allows client join',
      () async {
        final reservation = await backendHost.startHotspot(
          ssid: 'DIRECT-LS-TEST',
          psk: 'securePassphrase123',
          port: 53318,
        );

        expect(backendHost.activeReservationsCount, 1);
        expect(air.isAvailable('DIRECT-LS-TEST'), isTrue);

        final joinResult = await backendJoiner.joinHotspot(
          ssid: 'DIRECT-LS-TEST',
          psk: 'securePassphrase123',
        );

        expect(backendJoiner.activeJoinsCount, 1);
        expect(joinResult.gatewayIp, '192.168.49.1');
        expect(joinResult.clientIp, '192.168.49.2');

        await joinResult.disconnect();
        expect(backendJoiner.activeJoinsCount, 0);

        await reservation.stop();
        expect(backendHost.activeReservationsCount, 0);
        expect(air.isAvailable('DIRECT-LS-TEST'), isFalse);
      },
    );

    test('joinHotspot rejects incorrect PSK', () async {
      await backendHost.startHotspot(
        ssid: 'DIRECT-LS-TEST',
        psk: 'correctSecret',
      );

      expect(
        () => backendJoiner.joinHotspot(
          ssid: 'DIRECT-LS-TEST',
          psk: 'wrongSecret',
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('Physical network cut disconnects active clients', () async {
      await backendHost.startHotspot(ssid: 'DIRECT-LS-CUT', psk: 'pass123');

      await backendJoiner.joinHotspot(ssid: 'DIRECT-LS-CUT', psk: 'pass123');

      expect(backendJoiner.activeJoinsCount, 1);

      // Simulate RF kill / netem blackhole
      air.cut('DIRECT-LS-CUT');

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(backendJoiner.activeJoinsCount, 0);
    });
  });

  group('HotspotCandidate Lifecycle & Fallback to Next Tier', () {
    test(
      'HotspotCandidate executes setup and asserts teardown on close',
      () async {
        bool setupCalled = false;
        bool teardownCalled = false;

        final hotspotCandidate = HotspotCandidate(
          id: 'c_hotspot',
          host: '192.168.49.1',
          port: 53318,
          peerFingerprint: 'AA' * 32,
          role: HotspotRole.join,
          ssid: 'DIRECT-LS-TEST',
          psk: 'pass123',
          validUntil: DateTime.now().add(const Duration(minutes: 2)),
          offerId: 'offer_1',
          onSetup: () async => setupCalled = true,
          onTeardown: () async => teardownCalled = true,
        );

        final mockClient = _MockPeerClient();
        final conn = HttpConnection(
          candidate: hotspotCandidate,
          clientFactory: (cand, sec) => mockClient,
        );

        final client = await conn.open();
        expect(client, isNotNull);
        expect(setupCalled, isTrue);
        expect(teardownCalled, isFalse);

        await conn.close();
        expect(teardownCalled, isTrue);
      },
    );

    test(
      'Hotspot cut at 40% triggers fallbackToNext without orphan state',
      () async {
        int hotspotTeardownCalls = 0;
        bool hotspotSetupCalled = false;

        final hotspotCand = HotspotCandidate(
          id: 'tier1_hotspot',
          host: '192.168.49.1',
          port: 53318,
          peerFingerprint: 'AA' * 32,
          role: HotspotRole.join,
          ssid: 'DIRECT-LS-CUT',
          psk: 'pass123',
          validUntil: DateTime.now().add(const Duration(minutes: 2)),
          offerId: 'offer_ladder',
          onSetup: () async => hotspotSetupCalled = true,
          onTeardown: () async => hotspotTeardownCalls++,
        );

        final lanCand = Candidate(
          id: 'tier2_lan',
          kind: CandidateKind.wifi,
          host: '192.168.1.100',
          port: 53318,
          peerFingerprint: 'AA' * 32,
          costHint: 25, // Lower priority than hotspot (cost 15)
        );

        final mockHotspotClient = _MockPeerClient(isAlive: true);
        final mockLanClient = _MockPeerClient(isAlive: true);

        final ladder = ConnectionManager(
          candidates: [hotspotCand, lanCand],
          connectionFactory: (candidate, security) {
            if (candidate.kind == CandidateKind.hotspot) {
              return HttpConnection(
                candidate: candidate,
                clientFactory: (_, _) => mockHotspotClient,
              );
            } else {
              return HttpConnection(
                candidate: candidate,
                clientFactory: (_, _) => mockLanClient,
              );
            }
          },
        );

        final events = <ChannelEvent>[];
        final sub = ladder.events.listen(events.add);
        addTearDown(sub.cancel);

        // Connect starts on HotspotCandidate (lowest costHint 15)
        await ladder.connect();
        expect(ladder.activeCandidate?.kind, CandidateKind.hotspot);
        expect(hotspotSetupCalled, isTrue);
        expect(hotspotTeardownCalls, 0);

        // Simulated 40% chunk transfer succeeded, then hotspot link is severed
        mockHotspotClient.isAlive = false;

        // Trigger fallback to next candidate
        final fallbackClient = await ladder.fallbackToNext(
          reason: 'hotspot_link_cut',
        );

        expect(fallbackClient, same(mockLanClient));
        expect(ladder.activeCandidate?.id, 'tier2_lan');
        expect(ladder.activeCandidate?.kind, CandidateKind.wifi);

        // Teardown of the severed hotspot candidate MUST be asserted
        expect(hotspotTeardownCalls, 1);

        await Future<void>.delayed(Duration.zero);

        // ChannelTierSwitched event was dispatched
        expect(events.whereType<ChannelTierSwitched>(), hasLength(1));
        final switched = events.whereType<ChannelTierSwitched>().first;
        expect(switched.fromCandidate?.kind, CandidateKind.hotspot);
        expect(switched.toCandidate.kind, CandidateKind.wifi);
        expect(switched.reason, 'hotspot_link_cut');

        await ladder.close();
        expect(hotspotTeardownCalls, 1);
      },
    );
  });
}
