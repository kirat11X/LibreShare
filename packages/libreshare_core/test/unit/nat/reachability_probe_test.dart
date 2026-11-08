import 'dart:io';

import 'package:test/test.dart';
import 'package:libreshare_core/src/nat/reachability_probe_impl.dart';

void main() {
  group('ReachabilityProbeImpl Unit Tests', () {
    test('Probes reachable open port', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      const probe = ReachabilityProbeImpl();

      final result = await probe.probe(
        host: '127.0.0.1',
        port: server.port,
        timeout: const Duration(seconds: 1),
      );

      await server.close();
      expect(result, isTrue);
    });

    test('Probes unreachable closed port', () async {
      final dummy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final closedPort = dummy.port;
      await dummy.close(); // Close port immediately

      const probe = ReachabilityProbeImpl();
      final result = await probe.probe(
        host: '127.0.0.1',
        port: closedPort,
        timeout: const Duration(milliseconds: 200),
      );

      expect(result, isFalse);
    });
  });
}
