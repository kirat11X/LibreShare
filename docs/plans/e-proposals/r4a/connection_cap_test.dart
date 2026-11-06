// E5 / R4a: connection cap and per-IP cap of the ApiServer (slow-loris style load; inc3.md
// section 12 "Known limits carried forward").
//
// Expected API (the tester chose the names; the coder may rename them only together with this
// file). `ApiServer` gets two named constructor parameters and two public final fields:
//
//   final int maxConnections;       // all open TCP connections of the listener, default 64
//   final int maxConnectionsPerIp;  // open TCP connections of ONE remote address, default 16
//
// Semantics:
//  * A "connection" is a TCP connection accepted by the listener, counted from accept (before any
//    request byte, before the TLS handshake) until it is closed; idle sockets, half-sent request
//    heads and in-flight requests all count. dart:io's HttpServer only reports a connection once
//    the request head is parsed, so the count has to sit on the socket level (for example a
//    ServerSocket wrapper handed to HttpServer.listenOn).
//  * Over the global or the per-IP limit the new connection is closed at once (an optional
//    503 first is fine) or refused. Nothing already open is touched.
//  * The slot is freed when the connection closes (by either side).
//  * Both limits apply to the plain and to the TLS profile.
//
// Without the two parameters this file does not compile (that is the first red state); the
// behavioural red state was checked separately on a copy that has the parameters but ignores
// them (see docs/plans/e-proposals/r4a/tests-plan.md).
//
// Every test names the guard it targets in its description ("GUARD: ...") so a verifier can
// remove that guard and expect exactly that test to go red.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/api_fake_handler.dart';
import '../helpers/p3_secure_handler.dart';
import '../helpers/p3_secure_rig.dart';

/// One raw TCP client connection. `closed` completes when the peer closed it or it was refused.
class _Conn {
  _Conn._(this.socket, this.address) {
    final s = socket;
    if (s == null) {
      refused = true;
      closed.complete();
      return;
    }
    s.listen(
      (_) {},
      onDone: () {
        if (!closed.isCompleted) closed.complete();
      },
      onError: (Object _) {
        if (!closed.isCompleted) closed.complete();
      },
      cancelOnError: true,
    );
  }

  final Socket? socket;
  final String address;
  final Completer<void> closed = Completer<void>();
  bool refused = false;

  static Future<_Conn> open(
    int port, {
    String from = '127.0.0.1',
    String? partialHead,
  }) async {
    Socket? s;
    try {
      s = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        sourceAddress: InternetAddress(from),
        timeout: const Duration(seconds: 3),
      );
    } on SocketException {
      s = null;
    }
    final c = _Conn._(s, from);
    if (s != null && partialHead != null) {
      s.write(partialHead);
      await s.flush();
    }
    return c;
  }

  /// True when the server closed (or refused) this connection within [t].
  Future<bool> closesWithin(Duration t) async {
    try {
      await closed.future.timeout(t);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  /// True when the connection is still open after [t].
  Future<bool> staysOpenFor(Duration t) async => !(await closesWithin(t));

  void destroy() => socket?.destroy();
}

const _settle = Duration(milliseconds: 500);
const _verdict = Duration(seconds: 2);

/// The head of a request that never finishes (slow-loris).
const _partialHead = 'GET /api/v1/info HTTP/1.1\r\nHost: x\r\nX-Slow: a\r\n';

void main() {
  ApiServer? server;
  late FakeIncomingHandler handler;
  late int port;
  final conns = <_Conn>[];

  Future<void> startPlain({required int total, required int perIp}) async {
    handler = FakeIncomingHandler();
    server = ApiServer(
      handler: handler,
      preferredPort: 0,
      bindAddress: InternetAddress.loopbackIPv4,
      enableRateLimit: false,
      maxConnections: total,
      maxConnectionsPerIp: perIp,
    );
    port = await server!.start();
  }

  Future<_Conn> open({String from = '127.0.0.1', String? head}) async {
    final c = await _Conn.open(port, from: from, partialHead: head);
    conns.add(c);
    return c;
  }

  /// Opens [n] connections from [from] and expects every one to stay open.
  Future<List<_Conn>> hold(
    int n, {
    String from = '127.0.0.1',
    String? head,
  }) async {
    final held = <_Conn>[];
    for (var i = 0; i < n; i++) {
      held.add(await open(from: from, head: head));
    }
    for (final c in held) {
      expect(
        await c.staysOpenFor(_settle),
        isTrue,
        reason: 'a connection inside the limits must not be closed',
      );
    }
    return held;
  }

  /// One complete `GET /info` on its own connection (Connection: close). Null = no HTTP answer.
  Future<int?> getInfo({String from = '127.0.0.1'}) async {
    final buf = StringBuffer();
    final done = Completer<void>();
    final Socket fresh;
    try {
      fresh = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        sourceAddress: InternetAddress(from),
        timeout: const Duration(seconds: 3),
      );
    } on SocketException {
      return null;
    }
    fresh.listen(
      (d) => buf.write(latin1.decode(d)),
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      onError: (Object _) {
        if (!done.isCompleted) done.complete();
      },
    );
    fresh.write(
      'GET /api/v1/info HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
    );
    await fresh.flush();
    try {
      await done.future.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      // fall through with what arrived
    }
    fresh.destroy();
    final m = RegExp(r'^HTTP/1\.[01] (\d{3})').firstMatch(buf.toString());
    return m == null ? null : int.parse(m.group(1)!);
  }

  tearDown(() async {
    for (final c in conns) {
      c.destroy();
    }
    conns.clear();
    await server?.stop(force: true);
    server = null;
  });

  test('GUARD default-numbers: the documented defaults are 64 connections and 16 per IP', () {
    final s = ApiServer(handler: FakeIncomingHandler());
    expect(s.maxConnections, 64);
    expect(s.maxConnectionsPerIp, 16);
    // A cap below one multi-file Android send (about 5 parallel sockets) would break real use.
    expect(s.maxConnectionsPerIp, greaterThanOrEqualTo(8));
    expect(s.maxConnections, greaterThanOrEqualTo(s.maxConnectionsPerIp));
  });

  test('GUARD global-cap: N idle sockets stay open, the (N+1)th is refused or closed', () async {
    await startPlain(total: 6, perIp: 100);
    final held = await hold(6);
    final extra = await open();
    expect(
      await extra.closesWithin(_verdict),
      isTrue,
      reason: 'the 7th connection must be refused or closed',
    );
    // the first six are untouched
    for (final c in held) {
      expect(c.closed.isCompleted, isFalse);
    }
  });

  test('GUARD global-cap-counts-half-sent-requests: slow-loris heads count, the (N+1)th is closed', () async {
    await startPlain(total: 5, perIp: 100);
    await hold(5, head: _partialHead);
    final extra = await open(head: _partialHead);
    expect(await extra.closesWithin(_verdict), isTrue);
  });

  test('GUARD global-cap-leaves-room: with N-1 idle sockets held a complete transfer still succeeds', () async {
    await startPlain(total: 6, perIp: 100);
    await hold(5);
    // The client below uses ONE keep-alive connection: 5 idle + 1 = exactly N.
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    Future<(int, String)> call(
      String method,
      String path, {
      Object? json,
      List<int>? bytes,
      Map<String, String> headers = const {},
    }) async {
      final req = await client
          .openUrl(method, Uri.parse('http://127.0.0.1:$port$path'))
          .timeout(const Duration(seconds: 5));
      headers.forEach(req.headers.set);
      if (json != null) {
        final b = utf8.encode(jsonEncode(json));
        req.headers.contentType = ContentType.json;
        req.contentLength = b.length;
        req.add(b);
      }
      if (bytes != null) {
        req.contentLength = bytes.length;
        req.add(bytes);
      }
      final res = await req.close().timeout(const Duration(seconds: 5));
      final text = await res.transform(utf8.decoder).join();
      return (res.statusCode, text);
    }

    expect((await call('GET', '/api/v1/info')).$1, 200);
    final session = await call(
      'POST',
      '/api/v1/sessions',
      json: sampleRequest().toJson(),
    );
    expect(session.$1, anyOf(200, 202), reason: session.$2);
    final put = await call(
      'PUT',
      '/api/v1/sessions/sess-1/files/f1/chunks/0',
      bytes: [1, 2, 3, 4],
      headers: {'Authorization': 'Bearer tok'},
    );
    expect(put.$1, 200, reason: put.$2);
    expect(handler.calls, containsAllInOrder(['createSession', 'putChunk']));
  });

  test('GUARD slot-release: closing one held socket frees a slot, a new client is served', () async {
    await startPlain(total: 4, perIp: 100);
    final held = await hold(4);
    final blocked = await open();
    expect(await blocked.closesWithin(_verdict), isTrue);
    held.first.destroy();
    // the server notices the close; poll up to 2 s for the freed slot
    int? status;
    final end = DateTime.now().add(_verdict);
    while (DateTime.now().isBefore(end)) {
      status = await getInfo();
      if (status == 200) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(status, 200, reason: 'a freed slot must be reusable');
  });

  test('GUARD slot-release-after-refusal: refused attempts do not leak slots (cap holds exactly N after churn)', () async {
    await startPlain(total: 3, perIp: 100);
    final held = await hold(3);
    for (var i = 0; i < 20; i++) {
      final x = await open();
      expect(await x.closesWithin(_verdict), isTrue);
    }
    for (final c in held) {
      c.destroy();
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    // all three slots must be free again after 20 refusals + 3 closes
    final again = await hold(3);
    final extra = await open();
    expect(await extra.closesWithin(_verdict), isTrue);
    expect(again.length, 3);
  });

  test('GUARD per-ip-cap: one source cannot hold more than its share, others are unaffected', () async {
    await startPlain(total: 30, perIp: 3);
    await hold(3, from: '127.0.0.2');
    final fourth = await open(from: '127.0.0.2');
    expect(
      await fourth.closesWithin(_verdict),
      isTrue,
      reason: 'the 4th connection of 127.0.0.2 exceeds the per-IP limit',
    );
    // another source still gets its own full share
    await hold(3, from: '127.0.0.3');
    expect(await getInfo(from: '127.0.0.1'), 200);
  });

  test('GUARD per-ip-cap-protects-others: an attacker at its per-IP limit leaves room for a legitimate client under the global cap', () async {
    // 8 total, 3 per IP: the attacker can take 3 of the 8, never all of them.
    await startPlain(total: 8, perIp: 3);
    for (var i = 0; i < 12; i++) {
      await open(from: '127.0.0.2', head: _partialHead);
    }
    await Future<void>.delayed(_settle);
    final stillOpen = conns.where((c) => !c.closed.isCompleted).length;
    expect(
      stillOpen,
      3,
      reason: 'the attacker keeps exactly its per-IP share of sockets',
    );
    expect(await getInfo(from: '127.0.0.1'), 200);
  });

  test('GUARD per-ip-slot-release: after the attacker disconnects it gets its share again', () async {
    await startPlain(total: 30, perIp: 2);
    final first = await hold(2, from: '127.0.0.2');
    final blocked = await open(from: '127.0.0.2');
    expect(await blocked.closesWithin(_verdict), isTrue);
    for (final c in first) {
      c.destroy();
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await hold(2, from: '127.0.0.2');
  });

  test('GUARD global-cap-applies-across-sources: N held by several IPs refuse the (N+1)th from a new IP', () async {
    await startPlain(total: 6, perIp: 3);
    await hold(3, from: '127.0.0.2');
    await hold(3, from: '127.0.0.3');
    final extra = await open(from: '127.0.0.4');
    expect(await extra.closesWithin(_verdict), isTrue);
  });

  group('TLS profile', () {
    late ApiServer tls;
    late int tlsPort;

    setUp(() async {
      tls = ApiServer(
        handler: P3SecureHandler(),
        security: SecurityConfig.tls(
          identity: p3ServerKey,
          trust: InMemoryTrustStore(),
        ),
        bindAddress: InternetAddress.loopbackIPv4,
        preferredPort: 0,
        enableRateLimit: false,
        maxConnections: 4,
        maxConnectionsPerIp: 3,
      );
      tlsPort = await tls.start();
      // the plain-profile server of the outer scope is not used here
      handler = FakeIncomingHandler();
      server = tls;
    });

    test('GUARD tls-per-ip-cap: handshake-less sockets count; the 4th of one IP is closed, a TLS client from another IP works', () async {
      port = tlsPort;
      await hold(3, from: '127.0.0.2');
      final fourth = await open(from: '127.0.0.2');
      expect(await fourth.closesWithin(_verdict), isTrue);
      final legit = await P3Raw.tls(tlsPort);
      addTearDown(legit.destroy);
      legit.write(
        'GET /api/v1/info HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
      );
      await legit.socket.flush();
      await legit.waitForHead();
      expect(legit.statusCode, 200);
    });

    test('GUARD tls-global-cap: 4 handshake-less sockets from different IPs, the 5th is closed', () async {
      port = tlsPort;
      await hold(2, from: '127.0.0.2');
      await hold(2, from: '127.0.0.3');
      final extra = await open(from: '127.0.0.4');
      expect(await extra.closesWithin(_verdict), isTrue);
    });
  });
}
