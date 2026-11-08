import 'dart:convert';
import 'dart:io';

import 'package:json_schema/json_schema.dart';
import 'package:libreshare_core/src/ble/ble_messages.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String _findRepoRoot() {
  var dir = Directory.current.absolute;
  while (true) {
    if (File(p.join(dir.path, 'pubspec.yaml')).existsSync() &&
        Directory(p.join(dir.path, 'docs')).existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('Repository root not found from ${Directory.current}');
    }
    dir = parent;
  }
}

void main() {
  group('LS-BLE/1 Schema Conformance (Wave 0)', () {
    late String root;
    late JsonSchema m1Schema;
    late JsonSchema m2Schema;
    late JsonSchema authSchema;
    late JsonSchema offerSchema;
    late JsonSchema decisionSchema;
    late JsonSchema netPlanSchema;
    late JsonSchema hotspotSchema;
    late JsonSchema joinedSchema;

    JsonSchema loadSchema(String filename) {
      final f = File(
        p.join(root, 'docs', 'protocol', 'ble', 'schemas', filename),
      );
      expect(f.existsSync(), isTrue, reason: '$filename must exist');
      return JsonSchema.create(jsonDecode(f.readAsStringSync()) as Object);
    }

    setUpAll(() {
      root = _findRepoRoot();
      m1Schema = loadSchema('ble-m1.schema.json');
      m2Schema = loadSchema('ble-m2.schema.json');
      authSchema = loadSchema('ble-auth.schema.json');
      offerSchema = loadSchema('ble-offer.schema.json');
      decisionSchema = loadSchema('ble-decision.schema.json');
      netPlanSchema = loadSchema('ble-netplan.schema.json');
      hotspotSchema = loadSchema('ble-hotspot.schema.json');
      joinedSchema = loadSchema('ble-joined.schema.json');
    });

    test('BleM1 validates against ble-m1.schema.json', () {
      const m1 = BleM1(epk: 'epk_b64', n: 'nonce_b64', eidHint: 'ab');
      final res = m1Schema.validate(m1.toJson());
      expect(
        res.isValid,
        isTrue,
        reason: res.errors.map((e) => e.message).join('; '),
      );

      // Negative control: missing epk
      expect(
        m1Schema.validate({'type': 'm1', 'v': 1, 'n': 'nonce'}).isValid,
        isFalse,
      );
    });

    test('BleM2 validates against ble-m2.schema.json', () {
      const m2 = BleM2(epk: 'epk_b64', n: 'nonce_b64', capEcho: 7);
      final res = m2Schema.validate(m2.toJson());
      expect(
        res.isValid,
        isTrue,
        reason: res.errors.map((e) => e.message).join('; '),
      );

      // Negative control: bad type
      expect(
        m2Schema.validate({
          'type': 'bad',
          'v': 1,
          'epk': 'e',
          'n': 'n',
          'capEcho': 1,
        }).isValid,
        isFalse,
      );
    });

    test('BleAuth validates against ble-auth.schema.json', () {
      const auth = BleAuth(
        certDerB64: 'der_b64',
        sigB64: 'sig_b64',
        alias: 'Pixel 8',
        platform: 'android',
        lanCands: [LanCandidate(ip: '192.168.1.50', port: 53318)],
      );
      final res = authSchema.validate(auth.toJson());
      expect(
        res.isValid,
        isTrue,
        reason: res.errors.map((e) => e.message).join('; '),
      );

      // Negative control: invalid port in lanCands
      final bad = auth.toJson();
      bad['lanCands'] = [
        {'ip': '1.2.3.4', 'port': 999999},
      ];
      expect(authSchema.validate(bad).isValid, isFalse);
    });

    test('BleOffer and BleDecision validate against schemas', () {
      const offer = BleOffer(
        offerId: 'off_1234567890abcdef',
        fileCount: 2,
        totalSize: 4096,
        firstName: 'test.txt',
        lanCands: [],
        hostPref: 1,
      );
      expect(offerSchema.validate(offer.toJson()).isValid, isTrue);

      const decision = BleDecision(
        offerId: 'off_1234567890abcdef',
        accept: false,
        reason: 'User declined',
      );
      expect(decisionSchema.validate(decision.toJson()).isValid, isTrue);

      // Negative control: fileCount < 1
      final badOffer = offer.toJson();
      badOffer['fileCount'] = 0;
      expect(offerSchema.validate(badOffer).isValid, isFalse);
    });

    test('BleNetPlan, BleHotspot, BleJoined validate against schemas', () {
      const plan = BleNetPlan(
        offerId: 'off_123',
        hostRole: 'host',
        pathKind: 'hotspot',
      );
      expect(netPlanSchema.validate(plan.toJson()).isValid, isTrue);

      final hotspot = BleHotspot(
        offerId: 'off_123',
        ssid: 'LS-HOTSPOT',
        psk: 'pass12345',
        hostIp: '192.168.49.1',
        port: 53318,
        certFp: 'FP123',
        validUntil: DateTime.utc(2026, 11, 7, 20).toIso8601String(),
      );
      expect(hotspotSchema.validate(hotspot.toJson()).isValid, isTrue);

      const joined = BleJoined(offerId: 'off_123', clientIp: '192.168.49.2');
      expect(joinedSchema.validate(joined.toJson()).isValid, isTrue);

      // Negative control: invalid hostRole
      expect(
        netPlanSchema.validate({
          'type': 'net_plan',
          'offerId': 'o',
          'hostRole': 'other',
          'pathKind': 'lan',
        }).isValid,
        isFalse,
      );
    });
  });
}
