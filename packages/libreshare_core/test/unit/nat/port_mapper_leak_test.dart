import 'package:test/test.dart';
import 'package:libreshare_core/src/nat/fake_igd_gateway.dart';
import 'package:libreshare_core/src/nat/gateway_info.dart';
import 'package:libreshare_core/src/nat/port_mapping.dart';
import 'package:libreshare_core/src/nat/unified_port_mapper.dart';

void main() {
  group('UnifiedPortMapper Leak & Stale Sweep Tests', () {
    late FakeIgdGateway gateway;
    late UnifiedPortMapper mapper;

    setUp(() async {
      gateway = FakeIgdGateway(externalIp: '198.51.100.1');
      await gateway.start();

      mapper = UnifiedPortMapper(
        injectedGateway: GatewayInfo(
          gatewayIp: '127.0.0.1',
          protocol: GatewayProtocol.upnpIgd,
          externalIp: '198.51.100.1',
          controlUrl: Uri.parse(
            'http://127.0.0.1:${gateway.port}/control/WANIPConnection',
          ),
        ),
      );
    });

    tearDown(() async {
      await mapper.close();
      await gateway.close();
    });

    test(
      'Leak Prevention: close() releases all active mappings from gateway',
      () async {
        final m1 = await mapper.requestMapping(
          internalPort: 53330,
          externalPort: 53330,
          protocol: PortMappingProtocol.tcp,
        );
        final m2 = await mapper.requestMapping(
          internalPort: 53331,
          externalPort: 53331,
          protocol: PortMappingProtocol.tcp,
        );

        expect(m1, isNotNull);
        expect(m2, isNotNull);
        expect(mapper.activeMappings.length, 2);
        expect(gateway.activeMappings.length, 2);

        // Now close mapper
        await mapper.close();

        // Invariant: NO mappings left on mapper or on the gateway router
        expect(mapper.activeMappings.isEmpty, isTrue);
        expect(gateway.activeMappings.isEmpty, isTrue);
      },
    );

    test('sweepStale() sweeps expired mappings', () async {
      final m1 = await mapper.requestMapping(
        internalPort: 53330,
        externalPort: 53330,
        // Short expired lease
        lease: const Duration(milliseconds: 1),
        protocol: PortMappingProtocol.tcp,
      );
      expect(m1, isNotNull);

      await Future<void>.delayed(const Duration(milliseconds: 10));

      final swept = await mapper.sweepStale();
      expect(swept, 1);
      expect(mapper.activeMappings.isEmpty, isTrue);
      expect(gateway.activeMappings.isEmpty, isTrue);
    });
  });
}
