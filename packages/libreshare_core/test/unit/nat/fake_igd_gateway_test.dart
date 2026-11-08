import 'package:test/test.dart';
import 'package:libreshare_core/src/nat/fake_igd_gateway.dart';
import 'package:libreshare_core/src/nat/port_mapping.dart';
import 'package:libreshare_core/src/nat/upnp_igd.dart';

void main() {
  group('FakeIgdGateway & UpnpIgdClient Tests', () {
    late FakeIgdGateway gateway;
    late UpnpIgdClient client;

    setUp(() async {
      gateway = FakeIgdGateway(externalIp: '198.51.100.55');
      await gateway.start();
      client = UpnpIgdClient(
        controlUrl: Uri.parse(
          'http://127.0.0.1:${gateway.port}/control/WANIPConnection',
        ),
      );
    });

    tearDown(() async {
      await gateway.close();
    });

    test('GetExternalIPAddress returns expected public IP', () async {
      final ip = await client.getExternalIpAddress();
      expect(ip, '198.51.100.55');
    });

    test('AddPortMapping successful flow', () async {
      final mapping = await client.addPortMapping(
        internalPort: 53318,
        externalPort: 53318,
        lease: const Duration(hours: 1),
        protocol: PortMappingProtocol.tcp,
      );

      expect(mapping, isNotNull);
      expect(mapping!.internalPort, 53318);
      expect(mapping.externalPort, 53318);
      expect(mapping.protocol, PortMappingProtocol.tcp);
      expect(gateway.activeMappings.length, 1);
      expect(gateway.activeMappings.first['externalPort'], 53318);
    });

    test('718 ConflictInMappingEntry automatically increments port', () async {
      gateway.conflictPort = 53318; // Make 53318 conflict

      final mapping = await client.addPortMapping(
        internalPort: 53318,
        externalPort: 53318,
        lease: const Duration(hours: 1),
        protocol: PortMappingProtocol.tcp,
      );

      expect(mapping, isNotNull);
      expect(mapping!.internalPort, 53318);
      expect(mapping.externalPort, 53319); // Incremented to next port
      expect(gateway.activeMappings.first['externalPort'], 53319);
    });

    test(
      '725 OnlyPermanentLeasesSupported retries with 0 lease duration',
      () async {
        gateway.permanentOnly = true;

        final mapping = await client.addPortMapping(
          internalPort: 53318,
          externalPort: 53318,
          lease: const Duration(minutes: 30),
          protocol: PortMappingProtocol.tcp,
        );

        expect(mapping, isNotNull);
        expect(mapping!.leaseDuration, Duration.zero);
        expect(gateway.activeMappings.first['leaseDuration'], 0);
      },
    );

    test('DeletePortMapping cleans up active mapping', () async {
      final mapping = await client.addPortMapping(
        internalPort: 53318,
        externalPort: 53318,
        lease: const Duration(hours: 1),
        protocol: PortMappingProtocol.tcp,
      );
      expect(mapping, isNotNull);
      expect(gateway.activeMappings.length, 1);

      final ok = await client.deletePortMapping(
        externalPort: 53318,
        protocol: PortMappingProtocol.tcp,
      );
      expect(ok, isTrue);
      expect(gateway.activeMappings.isEmpty, isTrue);
    });

    test('501 ActionFailed returns null cleanly without crashing', () async {
      gateway.failAll = true;

      final mapping = await client.addPortMapping(
        internalPort: 53318,
        externalPort: 53318,
      );
      expect(mapping, isNull);

      final ip = await client.getExternalIpAddress();
      expect(ip, isNull);
    });
  });
}
