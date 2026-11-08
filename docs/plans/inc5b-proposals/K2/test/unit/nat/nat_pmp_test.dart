import 'package:test/test.dart';
import 'package:libreshare_core/src/nat/fake_pcp_server.dart';
import 'package:libreshare_core/src/nat/nat_pmp.dart';
import 'package:libreshare_core/src/nat/port_mapping.dart';

void main() {
  group('NAT-PMP & FakePcpServer Tests', () {
    late FakePcpServer server;
    const client = NatPmpClient();

    setUp(() async {
      server = FakePcpServer(externalIp: '198.51.100.99');
      await server.start();
    });

    tearDown(() async {
      await server.close();
    });

    test('getExternalIpAddress retrieves expected IPv4', () async {
      final ip = await client.getExternalIpAddress(
        gatewayIp: '127.0.0.1',
        port: server.port,
        timeout: const Duration(seconds: 2),
      );
      expect(ip, '198.51.100.99');
    });

    test('addPortMapping creates TCP mapping on gateway', () async {
      final mapping = await client.addPortMapping(
        gatewayIp: '127.0.0.1',
        internalPort: 53330,
        externalPort: 53330,
        lease: const Duration(minutes: 60),
        protocol: PortMappingProtocol.tcp,
        port: server.port,
        timeout: const Duration(seconds: 2),
      );

      expect(mapping, isNotNull);
      expect(mapping!.internalPort, 53330);
      expect(mapping.externalPort, 53330);
      expect(mapping.protocol, PortMappingProtocol.tcp);
      expect(server.activeMappings.length, 1);
      expect(server.activeMappings.first['externalPort'], 53330);
    });

    test('deletePortMapping removes mapping with lifetime 0', () async {
      final mapping = await client.addPortMapping(
        gatewayIp: '127.0.0.1',
        internalPort: 53330,
        externalPort: 53330,
        lease: const Duration(minutes: 60),
        protocol: PortMappingProtocol.tcp,
        port: server.port,
        timeout: const Duration(seconds: 2),
      );
      expect(mapping, isNotNull);
      expect(server.activeMappings.length, 1);

      final deleted = await client.deletePortMapping(
        gatewayIp: '127.0.0.1',
        internalPort: 53330,
        protocol: PortMappingProtocol.tcp,
        port: server.port,
        timeout: const Duration(seconds: 2),
      );
      expect(deleted, isTrue);
      expect(server.activeMappings.isEmpty, isTrue);
    });
  });
}
