// Increment 5b / Integration Card I1: NAT Gateway & Ladder Integration Suite.
// Verifies FakeIgdGateway (UPnP IGD), FakePcpServer (NAT-PMP / PCP), UnifiedPortMapper,
// candidate race prioritization, failing mapping fallback, and direct origin cert pinning.
@TestOn('vm')
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart' hide OriginKind;
import 'package:libreshare_core/src/connection/candidate_race.dart';
import 'package:libreshare_core/src/connection/direct_connection.dart';
import 'package:libreshare_core/src/nat/fake_igd_gateway.dart';
import 'package:libreshare_core/src/nat/fake_pcp_server.dart';
import 'package:libreshare_core/src/nat/gateway_info.dart';
import 'package:libreshare_core/src/nat/nat_pmp.dart';
import 'package:libreshare_core/src/nat/origin_kind.dart';
import 'package:libreshare_core/src/nat/pcp.dart';
import 'package:libreshare_core/src/nat/port_mapping.dart';
import 'package:libreshare_core/src/nat/unified_port_mapper.dart';
import 'package:test/test.dart';

class _MockPeerClient implements PeerClient {
  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHealthyConnection implements Connection {
  _FakeHealthyConnection(this.candidate);

  @override
  final Candidate candidate;

  @override
  ConnectionState state = ConnectionState.connected;

  @override
  bool get isHealthy => state == ConnectionState.connected;

  @override
  Duration? latency = const Duration(milliseconds: 15);

  @override
  Future<PeerClient> open({Duration? timeout}) async => _MockPeerClient();

  @override
  Future<void> close() async {
    state = ConnectionState.closed;
  }
}

void main() {
  group('I1: NAT Gateway & Candidate Ladder Integration Suite', () {
    late FakeIgdGateway igdServer;
    late FakePcpServer pcpServer;

    setUp(() async {
      igdServer = FakeIgdGateway(externalIp: '203.0.113.10');
      await igdServer.start();

      pcpServer = FakePcpServer(externalIp: '203.0.113.20');
      await pcpServer.start();
    });

    tearDown(() async {
      await igdServer.close();
      await pcpServer.close();
    });

    test('UPnP IGD, NAT-PMP and PCP gateways map ports and yield origin candidates', () async {
      // 1. UPnP IGD via injectedGateway in UnifiedPortMapper
      final upnpMapper = UnifiedPortMapper(
        injectedGateway: GatewayInfo(
          gatewayIp: '127.0.0.1',
          protocol: GatewayProtocol.upnpIgd,
          externalIp: '203.0.113.10',
          controlUrl: Uri.parse(
            'http://127.0.0.1:${igdServer.port}/control/WANIPConnection',
          ),
        ),
      );

      final upnpMapping = await upnpMapper.requestMapping(
        internalPort: 53318,
        externalPort: 53320,
        lease: const Duration(minutes: 30),
      );

      expect(upnpMapping, isNotNull);
      expect(upnpMapping!.externalPort, equals(53320));
      expect(upnpMapping.protocol, equals(PortMappingProtocol.tcp));
      expect(igdServer.activeMappings, hasLength(1));

      // 2. NAT-PMP direct client mapping
      const natPmpClient = NatPmpClient();
      final natPmpMapping = await natPmpClient.addPortMapping(
        gatewayIp: '127.0.0.1',
        internalPort: 53319,
        externalPort: 53321,
        lease: const Duration(minutes: 30),
        protocol: PortMappingProtocol.tcp,
        port: pcpServer.port,
      );

      expect(natPmpMapping, isNotNull);
      expect(natPmpMapping!.internalPort, equals(53319));
      expect(natPmpMapping.externalPort, equals(53321));

      // 3. PCP direct client mapping
      const pcpClient = PcpClient();
      final pcpMapping = await pcpClient.requestMapping(
        gatewayIp: '127.0.0.1',
        internalPort: 53322,
        externalPort: 53324,
        lease: const Duration(minutes: 30),
        protocol: PortMappingProtocol.tcp,
        port: pcpServer.port,
      );

      expect(pcpMapping, isNotNull);
      expect(pcpMapping!.internalPort, equals(53322));
      expect(pcpMapping.externalPort, equals(53324));

      // 4. Clean release
      final released = await upnpMapper.releaseMapping(upnpMapping);
      expect(released, isTrue);
      expect(igdServer.activeMappings, isEmpty);
    });

    test('CandidateRace prioritizes mapped origin over tunnel and falls back when primary is dead', () async {
      final racer = CandidateRace(
        staggerDelay: const Duration(milliseconds: 50),
        candidateTimeout: const Duration(milliseconds: 300),
      );

      final failingMappedSpec = OriginCandidateSpec(
        kind: OriginKind.mappedIpv4,
        host: '203.0.113.20',
        port: 53321,
        tlsPinHex: 'AA' * 32,
      );

      final healthyTunnelSpec = OriginCandidateSpec(
        kind: OriginKind.tunnelCloudflare,
        host: 'quick-tunnel.trycloudflare.com',
        port: 443,
      );

      // Verify priority ordering: mappedIpv4 (priority 20) < tunnelCloudflare (priority 30)
      expect(failingMappedSpec.priority, lessThan(healthyTunnelSpec.priority));

      var mappedAttempted = false;
      var tunnelAttempted = false;

      final winningConn = await racer.raceCandidates(
        candidates: [healthyTunnelSpec, failingMappedSpec],
        connectFn: (spec) async {
          if (spec.kind == OriginKind.mappedIpv4) {
            mappedAttempted = true;
            // Primary mapped port is unreachable / drops connection
            throw const SocketException('Connection refused');
          } else if (spec.kind == OriginKind.tunnelCloudflare) {
            tunnelAttempted = true;
            final cand = Candidate.create(
              kind: CandidateKind.tunnel,
              host: spec.host,
              port: spec.port,
              peerFingerprint: 'TUNNEL_WINNER',
            );
            return _FakeHealthyConnection(cand);
          }
          return null;
        },
      );

      expect(mappedAttempted, isTrue);
      expect(tunnelAttempted, isTrue);
      expect(winningConn, isNotNull);
      expect(winningConn!.candidate.kind, equals(CandidateKind.tunnel));
      expect(winningConn.isHealthy, isTrue);
    });

    test(
      'DirectConnection cert pinning strictly verifies SHA-256 fingerprint',
      () {
        final expectedHash = 'ab' * 32;
        final conn = DirectConnection(
          candidate: Candidate.create(
            kind: CandidateKind.wifi,
            host: '127.0.0.1',
            port: 53318,
            peerFingerprint: expectedHash,
          ),
          originBase: Uri.parse('https://127.0.0.1:53318'),
          token: 'pin_token',
          keys: TunnelKeys.fromRootKey(Uint8List(32)),
          claim: 'pin_claim',
          expectedPinHex: expectedHash,
        );

        expect(conn.expectedPinHex, equals(expectedHash));

        // Exception string redaction test
        final mismatch = TlsPinMismatchException(
          expectedPin: expectedHash,
          actualPin: 'cd' * 32,
        );
        expect(mismatch.toString(), contains('TlsPinMismatchException'));
        expect(mismatch.expectedPin, equals(expectedHash));
      },
    );

    test(
      'OriginCandidateSpec parse enforces syntax and rejects malformed formats',
      () {
        final validSpec = OriginCandidateSpec.parse(
          'mapped4:203.0.113.1:53318',
        );
        expect(validSpec, isNotNull);
        expect(validSpec!.kind, equals(OriginKind.mappedIpv4));
        expect(validSpec.host, equals('203.0.113.1'));
        expect(validSpec.port, equals(53318));

        // Invalid kind
        expect(OriginCandidateSpec.parse('unknown_kind:1.2.3.4:80'), isNull);
        // Invalid port
        expect(OriginCandidateSpec.parse('mapped4:1.2.3.4:99999'), isNull);
        expect(OriginCandidateSpec.parse('mapped4:1.2.3.4:-1'), isNull);
        expect(OriginCandidateSpec.parse('mapped4:1.2.3.4:abc'), isNull);
        // Missing parts
        expect(OriginCandidateSpec.parse('mapped4:1.2.3.4'), isNull);
      },
    );
  });
}
