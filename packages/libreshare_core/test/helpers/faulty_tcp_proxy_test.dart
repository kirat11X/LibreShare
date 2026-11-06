import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libreshare_core/src/security/cert_factory.dart';
import 'package:libreshare_core/src/security/key_identity.dart';
import 'package:libreshare_core/src/security/tls_context.dart';
import 'package:test/test.dart';

import 'faulty_tcp_proxy.dart';

void main() {
  group('FaultyTcpProxy - Transparent pass-through', () {
    late ServerSocket echoServer;
    late FaultyTcpProxy proxy;

    setUp(() async {
      echoServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      echoServer.listen((Socket client) {
        client.listen(client.add, onError: (Object _) {}, cancelOnError: true);
      });

      proxy = await FaultyTcpProxy.start(
        targetAddress: echoServer.address,
        targetPort: echoServer.port,
      );
    });

    tearDown(() async {
      await proxy.close();
      await echoServer.close();
    });

    test('forwards data byte-identical in both directions', () async {
      final client = await Socket.connect(proxy.address, proxy.port);
      final sentData = Uint8List.fromList(List<int>.generate(256, (i) => i));
      final receivedData = <int>[];
      final done = Completer<void>();

      client.listen(
        (data) {
          receivedData.addAll(data);
          if (receivedData.length >= sentData.length && !done.isCompleted) {
            done.complete();
          }
        },
        onError: (Object e) {
          if (!done.isCompleted) done.completeError(e);
        },
        cancelOnError: true,
      );

      client.add(sentData);
      await client.flush();

      await done.future.timeout(const Duration(seconds: 5));
      await client.close();

      expect(Uint8List.fromList(receivedData), equals(sentData));
      expect(proxy.totalBytesForwarded, equals(sentData.length * 2));
      expect(proxy.stats.clientToServerBytes, equals(sentData.length));
      expect(proxy.stats.serverToClientBytes, equals(sentData.length));
      expect(proxy.faultsTriggered, equals(0));
      expect(proxy.packetsDelayed, equals(0));
      expect(proxy.stats.connectionsAccepted, equals(1));
    });

    test('operates transparently over TLS (HTTPS)', () async {
      // Set up real HTTPS server using Libreshare's generated server TLS context.
      final serverId = KeyIdentity.fromGenerated(
        generateIdentity(deviceId: 'tls-proxy-test'),
      );
      final ctx = buildServerContext(serverId);
      final httpsServer = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        ctx,
      );
      httpsServer.listen((HttpRequest request) {
        request.response.headers.contentType = ContentType.text;
        request.response.write('hello-secure-proxy');
        request.response.close();
      });

      final tlsProxy = await FaultyTcpProxy.start(
        targetAddress: httpsServer.address,
        targetPort: httpsServer.port,
      );

      try {
        final httpClient = HttpClient()
          ..findProxy = ((Uri _) => 'DIRECT')
          ..badCertificateCallback = (
            X509Certificate cert,
            String host,
            int port,
          ) => true;

        final request = await httpClient.getUrl(
          Uri.parse(
            'https://${tlsProxy.address.address}:${tlsProxy.port}/test',
          ),
        );
        final response = await request.close();
        final body = await utf8.decodeStream(response);

        expect(response.statusCode, equals(HttpStatus.ok));
        expect(body, equals('hello-secure-proxy'));
        expect(tlsProxy.totalBytesForwarded, greaterThan(0));
        expect(tlsProxy.faultsTriggered, equals(0));
        httpClient.close(force: true);
      } finally {
        await tlsProxy.close();
        await httpsServer.close(force: true);
      }
    });
  });

  group('FaultyTcpProxy - cutAfter', () {
    late ServerSocket sinkServer;
    late FaultyTcpProxy proxy;
    late List<int> receivedByServer;
    late Completer<void> serverDone;

    setUp(() async {
      receivedByServer = <int>[];
      serverDone = Completer<void>();

      sinkServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      sinkServer.listen((Socket client) {
        client.listen(
          receivedByServer.addAll,
          onError: (Object _) {
            if (!serverDone.isCompleted) serverDone.complete();
          },
          onDone: () {
            if (!serverDone.isCompleted) serverDone.complete();
          },
          cancelOnError: true,
        );
      });

      proxy = await FaultyTcpProxy.start(
        targetAddress: sinkServer.address,
        targetPort: sinkServer.port,
      );
    });

    tearDown(() async {
      await proxy.close();
      await sinkServer.close();
    });

    test(
      'closes connection abruptly after transferring exactly N bytes',
      () async {
        const cutLimit = 64;
        proxy.cutAfter(cutLimit, direction: ProxyDirection.clientToServer);

        final client = await Socket.connect(proxy.address, proxy.port);
        unawaited(client.done.catchError((Object _) {}));
        final clientDone = Completer<void>();
        client.listen(
          (_) {},
          onError: (Object _) {
            if (!clientDone.isCompleted) clientDone.complete();
          },
          onDone: () {
            if (!clientDone.isCompleted) clientDone.complete();
          },
          cancelOnError: true,
        );

        final payload = Uint8List.fromList(
          List<int>.generate(200, (i) => i % 256),
        );
        client.add(payload);
        try {
          await client.flush();
        } catch (_) {}

        await Future.any<void>([
          serverDone.future,
          clientDone.future,
          Future<void>.delayed(const Duration(milliseconds: 500)),
        ]);

        expect(receivedByServer.length, equals(cutLimit));
        expect(
          Uint8List.fromList(receivedByServer),
          equals(payload.sublist(0, cutLimit)),
        );
        expect(proxy.faultsTriggered, greaterThanOrEqualTo(1));
        client.destroy();
      },
    );
  });

  group('FaultyTcpProxy - delay', () {
    late ServerSocket echoServer;
    late FaultyTcpProxy proxy;

    setUp(() async {
      echoServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      echoServer.listen((Socket client) {
        client.listen(client.add, onError: (Object _) {}, cancelOnError: true);
      });

      proxy = await FaultyTcpProxy.start(
        targetAddress: echoServer.address,
        targetPort: echoServer.port,
      );
    });

    tearDown(() async {
      await proxy.close();
      await echoServer.close();
    });

    test('adds artificial latency while preserving data integrity', () async {
      const latency = Duration(milliseconds: 60);
      proxy.delay(latency);

      final client = await Socket.connect(proxy.address, proxy.port);
      final payload = Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 8]);
      final received = <int>[];
      final done = Completer<void>();

      client.listen((data) {
        received.addAll(data);
        if (received.length >= payload.length && !done.isCompleted) {
          done.complete();
        }
      }, cancelOnError: true);

      final sw = Stopwatch()..start();
      client.add(payload);
      await client.flush();

      await done.future.timeout(const Duration(seconds: 5));
      sw.stop();
      await client.close();

      // Client->Server delayed by 60ms, Server->Client delayed by 60ms => total >= 100ms
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(100));
      expect(Uint8List.fromList(received), equals(payload));
      expect(proxy.packetsDelayed, greaterThanOrEqualTo(2));
    });

    test('respects packetCount limit on delay', () async {
      const latency = Duration(milliseconds: 50);
      proxy.delay(latency, packetCount: 1);

      final client = await Socket.connect(proxy.address, proxy.port);
      final received = <int>[];
      final done = Completer<void>();

      client.listen((data) {
        received.addAll(data);
        if (received.length >= 20 && !done.isCompleted) {
          done.complete();
        }
      }, cancelOnError: true);

      // Packet 1 (delayed)
      client.add(Uint8List.fromList(List<int>.generate(10, (i) => i)));
      await client.flush();

      // Wait a bit
      await Future<void>.delayed(const Duration(milliseconds: 80));

      // Packet 2 (should not be delayed)
      client.add(Uint8List.fromList(List<int>.generate(10, (i) => i + 10)));
      await client.flush();

      await done.future.timeout(const Duration(seconds: 5));
      await client.close();

      expect(proxy.packetsDelayed, equals(1));
      expect(received.length, equals(20));
    });
  });

  group('FaultyTcpProxy - truncate', () {
    late ServerSocket sinkServer;
    late FaultyTcpProxy proxy;
    late List<int> receivedByServer;
    late Completer<void> serverDone;

    setUp(() async {
      receivedByServer = <int>[];
      serverDone = Completer<void>();

      sinkServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      sinkServer.listen((Socket client) {
        client.listen(
          receivedByServer.addAll,
          onError: (Object _) {
            if (!serverDone.isCompleted) serverDone.complete();
          },
          onDone: () {
            if (!serverDone.isCompleted) serverDone.complete();
          },
          cancelOnError: true,
        );
      });

      proxy = await FaultyTcpProxy.start(
        targetAddress: sinkServer.address,
        targetPort: sinkServer.port,
      );
    });

    tearDown(() async {
      await proxy.close();
      await sinkServer.close();
    });

    test('truncates stream at maxBytes and sends TCP FIN', () async {
      const maxBytes = 42;
      proxy.truncate(maxBytes, direction: ProxyDirection.clientToServer);

      final client = await Socket.connect(proxy.address, proxy.port);
      unawaited(client.done.catchError((Object _) {}));
      final payload = Uint8List.fromList(List<int>.generate(150, (i) => i));

      client.add(payload);
      try {
        await client.flush();
      } catch (_) {}

      await serverDone.future.timeout(const Duration(seconds: 3));

      expect(receivedByServer.length, equals(maxBytes));
      expect(
        Uint8List.fromList(receivedByServer),
        equals(payload.sublist(0, maxBytes)),
      );
      expect(proxy.faultsTriggered, greaterThanOrEqualTo(1));
      client.destroy();
    });
  });

  group('FaultyTcpProxy - resetConnection', () {
    late ServerSocket echoServer;
    late FaultyTcpProxy proxy;

    setUp(() async {
      echoServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      echoServer.listen((Socket client) {
        client.done.catchError((Object _) {});
        client.listen(client.add, onError: (Object _) {});
      });

      proxy = await FaultyTcpProxy.start(
        targetAddress: echoServer.address,
        targetPort: echoServer.port,
      );
    });

    tearDown(() async {
      await proxy.close();
      await echoServer.close();
    });

    test('immediately destroys active connections and counts fault', () async {
      final client = await Socket.connect(proxy.address, proxy.port);
      unawaited(client.done.catchError((Object _) {}));
      final clientClosed = Completer<void>();

      client.listen(
        (_) {},
        onError: (Object _) {
          if (!clientClosed.isCompleted) clientClosed.complete();
        },
        onDone: () {
          if (!clientClosed.isCompleted) clientClosed.complete();
        },
      );

      client.add(Uint8List.fromList(<int>[1, 2, 3]));
      await client.flush();

      // Ensure connection is actively tracked before resetting
      while (proxy.activeConnectionCount == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      // Forcefully reset active connection
      proxy.resetConnection();

      await clientClosed.future.timeout(const Duration(seconds: 3));
      expect(proxy.faultsTriggered, greaterThanOrEqualTo(1));
      expect(proxy.activeConnectionCount, equals(0));
      client.destroy();
    });

    test(
      'futureConnections flag resets incoming connections immediately',
      () async {
        proxy.resetConnection(futureConnections: true);

        final client = await Socket.connect(proxy.address, proxy.port);
        final closed = Completer<void>();
        client.listen(
          (_) {},
          onError: (Object _) {
            if (!closed.isCompleted) closed.complete();
          },
          onDone: () {
            if (!closed.isCompleted) closed.complete();
          },
        );

        await closed.future.timeout(const Duration(seconds: 3));
        expect(proxy.faultsTriggered, greaterThanOrEqualTo(1));
        client.destroy();
      },
    );
  });

  group('FaultyTcpProxy - bitFlip and seeded reproducibility', () {
    late ServerSocket echoServer;
    late FaultyTcpProxy proxy;

    setUp(() async {
      echoServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      echoServer.listen((Socket client) {
        client.done.catchError((Object _) {});
        client.listen(client.add, onError: (Object _) {});
      });

      proxy = await FaultyTcpProxy.start(
        targetAddress: echoServer.address,
        targetPort: echoServer.port,
      );
    });

    tearDown(() async {
      await proxy.close();
      await echoServer.close();
    });

    Future<Uint8List> sendAndCollect(Uint8List payload) async {
      final client = await Socket.connect(proxy.address, proxy.port);
      final received = <int>[];
      final done = Completer<void>();

      client.listen(
        (data) {
          received.addAll(data);
          if (received.length >= payload.length && !done.isCompleted) {
            done.complete();
          }
        },
        onError: (Object e) {
          if (!done.isCompleted) done.completeError(e);
        },
      );

      client.add(payload);
      await client.flush();
      await done.future.timeout(const Duration(seconds: 5));
      await client.close();
      return Uint8List.fromList(received);
    }

    test('probability 1.0 flips bits in payload and triggers faults', () async {
      proxy.bitFlip(1.0, seed: 100, direction: ProxyDirection.clientToServer);
      final original = Uint8List.fromList(List<int>.generate(64, (i) => i));
      final result = await sendAndCollect(original);

      expect(result.length, equals(original.length));
      expect(result, isNot(equals(original)));
      expect(proxy.faultsTriggered, greaterThan(0));
    });

    test('same seed produces bit-exact identical corrupted output', () async {
      final payload = Uint8List.fromList(
        List<int>.generate(200, (i) => (i * 7) % 256),
      );

      // Run 1 with seed 12345
      proxy.seededFaultSchedule(12345, <FaultAction>[
        const FaultAction.bitFlip(
          0.2,
          direction: ProxyDirection.clientToServer,
        ),
      ]);
      final run1Result = await sendAndCollect(payload);
      final run1Faults = proxy.faultsTriggered;

      // Run 2 with identical seed 12345
      proxy.seededFaultSchedule(12345, <FaultAction>[
        const FaultAction.bitFlip(
          0.2,
          direction: ProxyDirection.clientToServer,
        ),
      ]);
      proxy.resetStats();
      final run2Result = await sendAndCollect(payload);
      final run2Faults = proxy.faultsTriggered;

      // Bit-exact reproducibility
      expect(run1Result, equals(run2Result));
      expect(run1Faults, equals(run2Faults));

      // Run 3 with different seed 54321
      proxy.seededFaultSchedule(54321, <FaultAction>[
        const FaultAction.bitFlip(
          0.2,
          direction: ProxyDirection.clientToServer,
        ),
      ]);
      proxy.resetStats();
      final run3Result = await sendAndCollect(payload);

      // Must produce different outcome than seed 12345
      expect(run3Result, isNot(equals(run1Result)));
    });

    test(
      'generateRandomSchedule generates deterministic schedule for seed',
      () {
        final scheduleA = FaultAction.generateRandomSchedule(777);
        final scheduleB = FaultAction.generateRandomSchedule(777);
        final scheduleC = FaultAction.generateRandomSchedule(888);

        expect(scheduleA.length, equals(scheduleB.length));
        for (var i = 0; i < scheduleA.length; i++) {
          expect(scheduleA[i].runtimeType, equals(scheduleB[i].runtimeType));
        }

        // Different seed produces different schedule
        final typesA = scheduleA.map((a) => a.runtimeType).toList();
        final typesC = scheduleC.map((a) => a.runtimeType).toList();
        final sameSchedule =
            typesA.length == typesC.length &&
            List<bool>.generate(
              typesA.length,
              (i) => typesA[i] == typesC[i],
            ).every((b) => b);
        // It is exceedingly unlikely to generate the exact same schedule
        if (sameSchedule &&
            scheduleA.first is CutAfterAction &&
            scheduleC.first is CutAfterAction) {
          expect(
            (scheduleA.first as CutAfterAction).bytes,
            isNot(equals((scheduleC.first as CutAfterAction).bytes)),
          );
        }
      },
    );

    test(
      'passThrough action gates faults until byte threshold passes',
      () async {
        proxy.seededFaultSchedule(42, <FaultAction>[
          const FaultAction.passThrough(bytes: 50),
          const FaultAction.cutAfter(
            10,
            direction: ProxyDirection.clientToServer,
          ),
        ]);

        final client = await Socket.connect(proxy.address, proxy.port);
        unawaited(client.done.catchError((Object _) {}));
        final clientClosed = Completer<void>();
        client.listen(
          (_) {},
          onError: (Object _) {
            if (!clientClosed.isCompleted) clientClosed.complete();
          },
          onDone: () {
            if (!clientClosed.isCompleted) clientClosed.complete();
          },
        );

        // Send 100 bytes
        client.add(Uint8List.fromList(List<int>.generate(100, (i) => i)));
        try {
          await client.flush();
        } catch (_) {}

        await clientClosed.future.timeout(const Duration(seconds: 3));

        // 50 pass-through bytes + 10 cut bytes = 60 bytes forwarded before cut
        expect(proxy.stats.clientToServerBytes, equals(60));
        expect(proxy.faultsTriggered, greaterThanOrEqualTo(1));
        client.destroy();
      },
    );
  });
}
