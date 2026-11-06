// FR-01: the engine binds 53318 and falls back to the next free port up to
// 53327 (spec section 4.1).
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/api_fake_handler.dart';

void main() {
  late FakeIncomingHandler fake;
  final blockers = <ServerSocket>[];
  final servers = <ApiServer>[];

  setUp(() => fake = FakeIncomingHandler());

  tearDown(() async {
    for (final s in servers) {
      await s.stop(force: true);
    }
    servers.clear();
    for (final b in blockers) {
      await b.close();
    }
    blockers.clear();
  });

  ApiServer newServer({
    int preferredPort = 0,
    int maxPortFallback = kPortFallbackMax,
    InternetAddress? bindAddress,
  }) {
    final s = ApiServer(
      handler: fake,
      bindAddress: bindAddress ?? InternetAddress.anyIPv4,
      preferredPort: preferredPort,
      maxPortFallback: maxPortFallback,
      enableRateLimit: false,
    );
    servers.add(s);
    return s;
  }

  Future<ServerSocket> occupy(int port) async {
    final s = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    blockers.add(s);
    return s;
  }

  /// A base port P such that P..P+[count]-1 can all be bound right now, found
  /// by probing, so the test never depends on fixed ports being free.
  Future<int> findFreeRun(int count) async {
    for (var attempt = 0; attempt < 50; attempt++) {
      final probe = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      final base = probe.port;
      await probe.close();
      if (base + count >= 65000) continue;
      final taken = <ServerSocket>[];
      try {
        for (var i = 0; i < count; i++) {
          taken.add(await ServerSocket.bind(InternetAddress.anyIPv4, base + i));
        }
        return base;
      } on SocketException {
        // some port in the run is busy: try another base
      } finally {
        for (final t in taken) {
          await t.close();
        }
      }
    }
    fail('could not find $count consecutive free ports');
  }

  Future<int> infoPort(int port) async {
    final c = HttpClient();
    try {
      final req = await c.getUrl(
        Uri.parse('http://127.0.0.1:$port$kApiPrefix/info'),
      );
      final resp = await req.close();
      await resp.drain<void>();
      return resp.statusCode;
    } finally {
      c.close(force: true);
    }
  }

  test('protocol constants: 53318 with fallback up to 53327', () {
    expect(kDefaultPort, 53318);
    expect(kPortFallbackMax, 53327);
  });

  test(
    'default port is taken, so the server falls back into 53319..53327',
    () async {
      // Hold 53318 ourselves (if someone else already has it, it is equally busy).
      try {
        await occupy(kDefaultPort);
      } on SocketException {
        // already in use by another process: same situation for this test
      }
      final server = ApiServer(
        handler: fake,
        bindAddress: InternetAddress.anyIPv4,
        enableRateLimit: false,
      );
      servers.add(server);
      final port = await server.start();
      expect(port, isNot(kDefaultPort));
      expect(port, inInclusiveRange(kDefaultPort + 1, kPortFallbackMax));
      expect(server.port, port);
      expect(await infoPort(port), 200);
    },
  );

  test('falls back by +1 per busy port', () async {
    final base = await findFreeRun(5);
    await occupy(base);
    await occupy(base + 1);
    await occupy(base + 2);
    final server = newServer(preferredPort: base, maxPortFallback: base + 4);
    expect(await server.start(), base + 3);
    expect(server.port, base + 3);
    expect(await infoPort(base + 3), 200);
  });

  test('uses the preferred port when it is free', () async {
    final base = await findFreeRun(3);
    final server = newServer(preferredPort: base, maxPortFallback: base + 2);
    expect(await server.start(), base);
  });

  test(
    'skips only busy ports: a free port below a busy one is not sticky',
    () async {
      final base = await findFreeRun(3);
      final first = await occupy(base);
      final a = newServer(preferredPort: base, maxPortFallback: base + 2);
      expect(await a.start(), base + 1);
      await first.close();
      blockers.remove(first);
      final b = newServer(preferredPort: base, maxPortFallback: base + 2);
      expect(
        await b.start(),
        base,
        reason: 'preferred is retried on every start',
      );
    },
  );

  test('two engines on one machine get consecutive ports', () async {
    final base = await findFreeRun(3);
    final a = newServer(preferredPort: base, maxPortFallback: base + 2);
    final b = newServer(preferredPort: base, maxPortFallback: base + 2);
    expect(await a.start(), base);
    expect(await b.start(), base + 1);
    expect(await infoPort(base), 200);
    expect(await infoPort(base + 1), 200);
  });

  test('throws SocketException when every port in the range is busy', () async {
    final base = await findFreeRun(3);
    await occupy(base);
    await occupy(base + 1);
    await occupy(base + 2);
    final server = newServer(preferredPort: base, maxPortFallback: base + 2);
    await expectLater(
      server.start(),
      throwsA(
        isA<SocketException>().having(
          (e) => e.message,
          'message',
          contains('$base..${base + 2}'),
        ),
      ),
    );
    expect(server.isRunning, isFalse);
    expect(() => server.port, throwsStateError);
  });

  test(
    'an explicit port above the fallback ceiling gets no fallback',
    () async {
      final base = await findFreeRun(2);
      await occupy(base);
      // maxPortFallback below preferredPort: only the preferred port is tried.
      final server = newServer(preferredPort: base, maxPortFallback: base - 1);
      await expectLater(server.start(), throwsA(isA<SocketException>()));
      // With the next port actually free, it was still not used.
      final free = newServer(preferredPort: base + 1, maxPortFallback: base);
      expect(await free.start(), base + 1);
    },
  );

  test('preferredPort 0 binds an ephemeral port', () async {
    final a = newServer();
    final b = newServer();
    final pa = await a.start();
    final pb = await b.start();
    expect(pa, greaterThan(1023));
    expect(pb, greaterThan(1023));
    expect(pa, isNot(pb));
    expect(await infoPort(pa), 200);
  });

  test(
    'errors other than "address in use" are not retried on other ports',
    () async {
      // 203.0.113.0/24 (TEST-NET-3) is not assigned to any local interface.
      final server = newServer(
        preferredPort: 0,
        bindAddress: InternetAddress('203.0.113.77'),
      );
      await expectLater(server.start(), throwsA(isA<SocketException>()));
      final base = await findFreeRun(3);
      final fixed = newServer(
        preferredPort: base,
        maxPortFallback: base + 2,
        bindAddress: InternetAddress('203.0.113.77'),
      );
      final sw = Stopwatch()..start();
      await expectLater(
        fixed.start(),
        throwsA(
          isA<SocketException>().having(
            (e) => e.message,
            'not the exhausted-range message',
            isNot(contains('No free port')),
          ),
        ),
      );
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    },
  );

  test(
    'lifecycle: port getter, isRunning, double start, stop and rebind',
    () async {
      final base = await findFreeRun(2);
      final server = newServer(preferredPort: base, maxPortFallback: base);
      expect(server.isRunning, isFalse);
      expect(() => server.port, throwsStateError);
      expect(await server.start(), base);
      expect(server.isRunning, isTrue);
      await expectLater(server.start(), throwsStateError);
      await server.stop();
      expect(server.isRunning, isFalse);
      expect(() => server.port, throwsStateError);
      await server.stop(); // idempotent

      // The port is really released.
      final again = newServer(preferredPort: base, maxPortFallback: base);
      expect(await again.start(), base);
      // And the old object can be started again too.
      await again.stop();
      expect(await server.start(), base);
    },
  );

  test('loopback-only binding is honoured', () async {
    final server = newServer(bindAddress: InternetAddress.loopbackIPv4);
    final port = await server.start();
    expect(await infoPort(port), 200);
  });
}
