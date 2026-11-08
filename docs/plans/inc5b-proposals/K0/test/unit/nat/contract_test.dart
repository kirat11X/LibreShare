import 'package:test/test.dart';
import 'package:libreshare_core/src/nat/origin_kind.dart';
import 'package:libreshare_core/src/nat/port_mapping.dart';
import 'package:libreshare_core/src/nat/gateway_info.dart';
import 'package:libreshare_core/src/nat/port_mapper.dart';
import 'package:libreshare_core/src/nat/reachability_probe.dart';

class _TestPortMapper implements PortMapper {
  @override
  Future<GatewayInfo?> discoverGateway({
    Duration timeout = const Duration(seconds: 3),
  }) async => const GatewayInfo(
    gatewayIp: '192.168.1.1',
    protocol: GatewayProtocol.upnpIgd,
    externalIp: '203.0.113.1',
  );

  @override
  Future<PortMapping?> requestMapping({
    required int internalPort,
    int? externalPort,
    Duration lease = const Duration(hours: 1),
    PortMappingProtocol protocol = PortMappingProtocol.tcp,
  }) async => PortMapping(
    internalPort: internalPort,
    externalPort: externalPort ?? internalPort,
    externalIp: '203.0.113.1',
    protocol: protocol,
    leaseDuration: lease,
    createdAt: DateTime.now(),
  );

  @override
  Future<bool> releaseMapping(PortMapping mapping) async => true;

  @override
  Future<int> sweepStale() async => 0;

  @override
  Future<void> close() async {}
}

class _TestReachabilityProbe implements ReachabilityProbe {
  @override
  Future<bool> probe({
    required String host,
    required int port,
    Duration timeout = const Duration(seconds: 3),
  }) async => true;
}

void main() {
  group('Wave 0 Contracts & Models', () {
    test('OriginKind priority and wire parsing', () {
      expect(OriginKind.fromWireName('ipv6'), OriginKind.directIpv6);
      expect(OriginKind.fromWireName('mapped4'), OriginKind.mappedIpv4);
      expect(OriginKind.fromWireName('cf'), OriginKind.tunnelCloudflare);
      expect(OriginKind.fromWireName('zrok'), OriginKind.tunnelZrok);
      expect(OriginKind.fromWireName('manual'), OriginKind.manual);
      expect(OriginKind.fromWireName('unknown'), isNull);

      // Verify strict priority ordering per design 04
      expect(
        OriginKind.directIpv6.priority < OriginKind.mappedIpv4.priority,
        isTrue,
      );
      expect(
        OriginKind.mappedIpv4.priority < OriginKind.tunnelCloudflare.priority,
        isTrue,
      );
      expect(
        OriginKind.tunnelCloudflare.priority < OriginKind.tunnelZrok.priority,
        isTrue,
      );
      expect(
        OriginKind.tunnelZrok.priority < OriginKind.manual.priority,
        isTrue,
      );
    });

    test('PortMapping lease and expiry calculation', () {
      final now = DateTime.utc(2026, 11, 7, 12, 0, 0);
      final mapping = PortMapping(
        internalPort: 53318,
        externalPort: 53318,
        externalIp: '198.51.100.25',
        protocol: PortMappingProtocol.tcp,
        leaseDuration: const Duration(minutes: 30),
        createdAt: now,
      );

      expect(mapping.expiresAt, DateTime.utc(2026, 11, 7, 12, 30, 0));
      expect(mapping.isExpired(DateTime.utc(2026, 11, 7, 12, 29, 0)), isFalse);
      expect(mapping.isExpired(DateTime.utc(2026, 11, 7, 12, 31, 0)), isTrue);
      expect(mapping.toString(), contains('53318->198.51.100.25:53318'));
    });

    test('GatewayInfo equality and properties', () {
      const g1 = GatewayInfo(
        gatewayIp: '192.168.1.1',
        protocol: GatewayProtocol.upnpIgd,
        externalIp: '198.51.100.25',
      );
      const g2 = GatewayInfo(
        gatewayIp: '192.168.1.1',
        protocol: GatewayProtocol.upnpIgd,
        externalIp: '198.51.100.25',
      );
      const g3 = GatewayInfo(
        gatewayIp: '192.168.1.1',
        protocol: GatewayProtocol.natPmp,
        externalIp: '198.51.100.25',
      );

      expect(g1, equals(g2));
      expect(g1.hashCode, equals(g2.hashCode));
      expect(g1, isNot(equals(g3)));
      expect(g1.toString(), contains('UPnP-IGD'));
    });

    test(
      'PortMapper and ReachabilityProbe implementation satisfies contract',
      () async {
        final mapper = _TestPortMapper();
        final gateway = await mapper.discoverGateway();
        expect(gateway, isNotNull);
        expect(gateway!.externalIp, '203.0.113.1');

        final mapping = await mapper.requestMapping(internalPort: 53330);
        expect(mapping, isNotNull);
        expect(mapping!.internalPort, 53330);
        expect(mapping.externalPort, 53330);

        final released = await mapper.releaseMapping(mapping);
        expect(released, isTrue);

        final swept = await mapper.sweepStale();
        expect(swept, 0);

        await mapper.close();

        final probe = _TestReachabilityProbe();
        final reachable = await probe.probe(host: '203.0.113.1', port: 53330);
        expect(reachable, isTrue);
      },
    );
  });
}
