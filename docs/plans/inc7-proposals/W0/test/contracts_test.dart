import 'dart:typed_data';

import 'package:libreshare_core/src/ble/beacon_types.dart';
import 'package:libreshare_core/src/ble/ble_messages.dart';
import 'package:libreshare_core/src/connection/candidate.dart';
import 'package:test/test.dart';

void main() {
  group('BleBeacon contracts and binary codec', () {
    test('encodes and decodes beacon bitfields and fields identically', () {
      final eid = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      final beacon = BleBeacon(
        companyId: kBleCompanyIdSigTest,
        version: 1,
        flags: const BeaconFlags(
          recv: true,
          send: false,
          open: true,
          gatt: true,
        ),
        cap: const BeaconCap(
          canHost: true,
          canJoin: true,
          hostKeepsUplink: false,
          platform: BlePlatform.android,
        ),
        eid: eid,
        seq: 0x1234,
      );

      final bytes = beacon.toBytes();
      expect(bytes.length, kBleBeaconLength);
      // Byte 0-1: Company ID (0xFFFF little-endian)
      expect(bytes[0], 0xFF);
      expect(bytes[1], 0xFF);
      // Byte 2-3: Magic 'L' 'S'
      expect(bytes[2], 0x4C);
      expect(bytes[3], 0x53);

      final decoded = BleBeacon.fromBytes(bytes);
      expect(decoded, isNotNull);
      expect(decoded!.companyId, kBleCompanyIdSigTest);
      expect(decoded.version, 1);
      expect(decoded.flags.recv, isTrue);
      expect(decoded.flags.send, isFalse);
      expect(decoded.flags.open, isTrue);
      expect(decoded.flags.gatt, isTrue);
      expect(decoded.cap.canHost, isTrue);
      expect(decoded.cap.canJoin, isTrue);
      expect(decoded.cap.hostKeepsUplink, isFalse);
      expect(decoded.cap.platform, BlePlatform.android);
      expect(decoded.eid, equals(eid));
      expect(decoded.seq, 0x1234);
    });

    test('rejects truncated bytes or bad magic', () {
      expect(BleBeacon.fromBytes([1, 2, 3]), isNull);
      final badMagic = Uint8List(16);
      badMagic[0] = 0xFF;
      badMagic[1] = 0xFF;
      badMagic[2] = 0x58; // 'X'
      badMagic[3] = 0x59; // 'Y'
      expect(BleBeacon.fromBytes(badMagic), isNull);
    });

    test('validates EID length and seq bounds', () {
      expect(
        () => BleBeacon(
          flags: const BeaconFlags(),
          cap: const BeaconCap(),
          eid: [1, 2, 3], // too short
          seq: 1,
        ),
        throwsArgumentError,
      );
      expect(
        () => BleBeacon(
          flags: const BeaconFlags(),
          cap: const BeaconCap(),
          eid: [1, 2, 3, 4, 5, 6, 7, 8],
          seq: 0x10000, // exceeds uint16
        ),
        throwsArgumentError,
      );
    });
  });

  group('BleMessage contracts and JSON serialization', () {
    test('BleM1 roundtrip', () {
      const msg = BleM1(
        epk: 'epk-bytes-b64',
        n: 'nonce-16-bytes',
        eidHint: 'ab',
      );
      final json = msg.toJson();
      expect(json['type'], 'm1');
      expect(json['epk'], 'epk-bytes-b64');
      final decoded = BleMessage.fromJson(json) as BleM1;
      expect(decoded.epk, msg.epk);
      expect(decoded.n, msg.n);
      expect(decoded.eidHint, 'ab');
    });

    test('BleM2 roundtrip', () {
      const msg = BleM2(epk: 'epk-m2-bytes', n: 'nonce-m2', capEcho: 0x1F);
      final json = msg.toJson();
      expect(json['type'], 'm2');
      final decoded = BleMessage.fromJson(json) as BleM2;
      expect(decoded.epk, msg.epk);
      expect(decoded.capEcho, 0x1F);
    });

    test('BleAuth roundtrip with LAN candidates', () {
      const msg = BleAuth(
        certDerB64: 'cert-der-data',
        sigB64: 'transcript-signature',
        alias: 'Alice Phone',
        platform: 'android',
        lanCands: [
          LanCandidate(ip: '192.168.1.10', port: 53318, iface: 'wlan0'),
          LanCandidate(ip: '10.0.0.5', port: 53320),
        ],
      );
      final json = msg.toJson();
      expect(json['type'], 'auth');
      final decoded = BleMessage.fromJson(json) as BleAuth;
      expect(decoded.alias, 'Alice Phone');
      expect(decoded.platform, 'android');
      expect(decoded.lanCands.length, 2);
      expect(decoded.lanCands.first.ip, '192.168.1.10');
      expect(decoded.lanCands.first.iface, 'wlan0');
    });

    test('BleOffer and BleDecision roundtrip', () {
      const offer = BleOffer(
        offerId: 'offer-1234-abcd',
        fileCount: 3,
        totalSize: 1048576,
        firstName: 'vacation.jpg',
        hostPref: 1,
      );
      final decodedOffer = BleMessage.fromJson(offer.toJson()) as BleOffer;
      expect(decodedOffer.offerId, 'offer-1234-abcd');
      expect(decodedOffer.totalSize, 1048576);

      const decision = BleDecision(offerId: 'offer-1234-abcd', accept: true);
      final decodedDecision =
          BleMessage.fromJson(decision.toJson()) as BleDecision;
      expect(decodedDecision.offerId, 'offer-1234-abcd');
      expect(decodedDecision.accept, isTrue);
    });

    test('BleNetPlan, BleHotspot, and BleJoined roundtrip', () {
      const netPlan = BleNetPlan(
        offerId: 'offer-123',
        hostRole: 'host',
        pathKind: 'hotspot',
      );
      final decodedNetPlan =
          BleMessage.fromJson(netPlan.toJson()) as BleNetPlan;
      expect(decodedNetPlan.hostRole, 'host');
      expect(decodedNetPlan.pathKind, 'hotspot');

      final hotspot = BleHotspot(
        offerId: 'offer-123',
        ssid: 'LS-DIRECT-9A',
        psk: 'secure-passphrase-123',
        band: 5,
        hostIp: '192.168.49.1',
        port: 53318,
        certFp: 'AA:BB:CC:DD',
        validUntil: DateTime.utc(2026, 11, 7, 18, 0).toIso8601String(),
      );
      final decodedHotspot =
          BleMessage.fromJson(hotspot.toJson()) as BleHotspot;
      expect(decodedHotspot.ssid, 'LS-DIRECT-9A');
      expect(decodedHotspot.hostIp, '192.168.49.1');

      const joined = BleJoined(offerId: 'offer-123', clientIp: '192.168.49.2');
      final decodedJoined = BleMessage.fromJson(joined.toJson()) as BleJoined;
      expect(decodedJoined.clientIp, '192.168.49.2');
    });
  });

  group('HotspotCandidate and Candidate lifecycle hooks', () {
    test('Candidate default budgets and hooks', () async {
      const c = Candidate(
        id: 'c1',
        kind: CandidateKind.wifi,
        host: '192.168.1.1',
        port: 53318,
        peerFingerprint: 'FP1',
        costHint: 10,
      );
      expect(c.setupBudget, Duration.zero);
      expect(c.connectBudget, const Duration(seconds: 3));
      // Default setup/teardown complete without error
      await c.setup();
      await c.teardown();
    });

    test(
      'HotspotCandidate budgets, roles, and setup/teardown execution',
      () async {
        var setupCount = 0;
        var teardownCount = 0;

        final joinCandidate = HotspotCandidate(
          id: 'hotspot:join',
          host: '192.168.49.1',
          port: 53318,
          peerFingerprint: 'FP_HOST',
          role: HotspotRole.join,
          ssid: 'LS-TEST',
          psk: 'psk-secret',
          validUntil: DateTime.utc(2026, 11, 7, 20),
          offerId: 'offer-test',
          onSetup: () async => setupCount++,
          onTeardown: () async => teardownCount++,
        );

        expect(joinCandidate.kind, CandidateKind.hotspot);
        expect(joinCandidate.setupBudget, const Duration(seconds: 90));
        expect(joinCandidate.connectBudget, const Duration(seconds: 5));
        expect(setupCount, 0);
        await joinCandidate.setup();
        expect(setupCount, 1);
        await joinCandidate.teardown();
        expect(teardownCount, 1);

        final hostCandidate = HotspotCandidate(
          id: 'hotspot:host',
          host: '192.168.49.1',
          port: 53318,
          peerFingerprint: 'FP_PEER',
          role: HotspotRole.host,
          ssid: 'LS-TEST',
          psk: 'psk-secret',
          validUntil: DateTime.utc(2026, 11, 7, 20),
          offerId: 'offer-test',
        );
        expect(hostCandidate.setupBudget, const Duration(seconds: 10));
      },
    );

    test('HotspotCandidate JSON roundtrip', () {
      final now = DateTime.utc(2026, 11, 7, 18, 30);
      final hc = HotspotCandidate(
        id: 'hotspot:192.168.49.1:53318',
        host: '192.168.49.1',
        port: 53318,
        peerFingerprint: 'FP123',
        role: HotspotRole.join,
        ssid: 'LS-AP-42',
        psk: 'secret-psk-string',
        validUntil: now,
        offerId: 'off-99',
      );

      final json = hc.toJson();
      expect(json['kind'], 'hotspot');
      expect(json['role'], 'join');
      expect(json['ssid'], 'LS-AP-42');
      // Secret PSK is omitted from general wire JSON
      expect(json.containsKey('psk'), isFalse);

      final restored = HotspotCandidate.fromJson(
        json,
        psk: 'secret-psk-string',
      );
      expect(restored.role, HotspotRole.join);
      expect(restored.ssid, 'LS-AP-42');
      expect(restored.psk, 'secret-psk-string');
      expect(restored.validUntil, now);
      expect(restored.offerId, 'off-99');
    });
  });
}
