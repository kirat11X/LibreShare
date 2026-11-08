import 'package:test/test.dart';
import 'package:libreshare_core/src/nat/fake_igd_gateway.dart';
import 'package:libreshare_core/src/nat/ssdp.dart';

void main() {
  group('SSDP & Hostile IGD Gateway Security Tests (D4 SSRF)', () {
    late FakeIgdGateway gateway;

    setUp(() async {
      gateway = FakeIgdGateway();
      await gateway.start();
    });

    tearDown(() async {
      await gateway.close();
    });

    test('Rejects hostile public IP in LOCATION URL', () async {
      final client = SsdpClient(allowLoopback: false);
      // Public IP location
      final hostileUri = Uri.parse('http://8.8.8.8:8080/desc.xml');
      final result = await client.resolveDeviceDescription(hostileUri);
      expect(result, isNull);
    });

    test('Rejects non-HTTP scheme in LOCATION URL', () async {
      final client = SsdpClient(allowLoopback: true);
      final hostileUri = Uri.parse('file:///etc/passwd');
      final result = await client.resolveDeviceDescription(hostileUri);
      expect(result, isNull);
    });

    test('Rejects oversize XML (> 64 KiB)', () async {
      gateway.oversizeXml = true;
      final client = SsdpClient(allowLoopback: true);

      final result = await client.resolveDeviceDescription(gateway.locationUri);
      expect(result, isNull);
    });

    test('Rejects DTD and entity expansion in XML', () async {
      gateway.includeDtd = true;
      final client = SsdpClient(allowLoopback: true);

      final result = await client.resolveDeviceDescription(gateway.locationUri);
      expect(result, isNull);
    });

    test(
      'Accepts valid RFC 1918 / loopback (with flag) device description',
      () async {
        final client = SsdpClient(allowLoopback: true);

        final result = await client.resolveDeviceDescription(
          gateway.locationUri,
        );
        expect(result, isNotNull);
        expect(result!.controlUrl, isNotNull);
        expect(result.controlUrl!.path, '/control/WANIPConnection');
      },
    );
  });
}
