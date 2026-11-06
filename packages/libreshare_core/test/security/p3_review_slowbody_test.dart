// P3 verifying review: slow-body starvation of the 2 oversize slots (LSP-1 4.3.4 secure order
// step 3; SPEC-GAP 10 of docs/plans/inc3-p3-tests.md).
//
// Finding: a stranger can open 2 `POST /sessions` requests that declare a body above 256 KiB and
// stall; each holds one of the 2 slots until the fixed 30 s total body timeout fires, and then
// re-opens. The attacker needs no proof and stays far below the 10/min rate limit, so every
// legitimate large session request gets 429 for as long as the attack lasts.
//
// Expected API (the coder may rename it only together with this file): `ApiServer` gets
//   final Duration bodyIdleTimeout;   // ctor named parameter, default 5 s
// meaning: a secure-profile request body read (readLimited) is aborted when no body byte arrives
// for that long. The slot is released, the request is answered 400 BAD_REQUEST ('timed out') or
// the connection is closed. A body that keeps making progress is NOT punished (the 30 s total
// limit stays as it is).
//
// The whole file fails to compile until the parameter exists (that is the red state).
import 'dart:async';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/p3_secure_handler.dart';
import '../helpers/p3_secure_rig.dart';

const _idle = Duration(seconds: 1);

void main() {
  late ApiServer server;
  late P3SecureHandler handler;
  late int port;
  final fp = p3ServerKey.identity.fingerprint;

  setUp(() async {
    handler = P3SecureHandler();
    server = ApiServer(
      handler: handler,
      security: SecurityConfig.tls(
        identity: p3ServerKey,
        trust: InMemoryTrustStore(),
      ),
      bindAddress: InternetAddress.loopbackIPv4,
      preferredPort: 0,
      enableRateLimit: false,
      bodyIdleTimeout: _idle,
    );
    port = await server.start();
  });
  tearDown(() => server.stop(force: true));

  /// A signed `POST /sessions` whose body is [length] bytes, sent in [pieces] writes [gap] apart.
  Future<int> legit({
    int length = 300 * 1024,
    int pieces = 1,
    Duration gap = Duration.zero,
  }) async {
    final body = p3SessionBody(p3Alice, length: length);
    final auth = buildAuthHeader(
      identity: p3Alice.key,
      method: 'POST',
      pathAndQuery: '$kApiPrefix/sessions',
      body: body,
      serverFingerprint: fp,
    );
    final client = HttpClient(context: buildClientContext())
      ..badCertificateCallback = (_, _, _) => true;
    try {
      final req = await client.postUrl(
        Uri.parse('https://127.0.0.1:$port$kApiPrefix/sessions'),
      );
      req.headers
        ..set('content-type', 'application/json')
        ..set(kAuthHeader, auth);
      req.contentLength = body.length;
      final step = (body.length / pieces).ceil();
      for (var i = 0; i < body.length; i += step) {
        req.add(
          body.sublist(i, i + step > body.length ? body.length : i + step),
        );
        if (pieces > 1) {
          await req.flush();
          await Future<void>.delayed(gap);
        }
      }
      final resp = await req.close().timeout(const Duration(seconds: 15));
      await resp.drain<void>();
      return resp.statusCode;
    } finally {
      client.close(force: true);
    }
  }

  /// A stranger's oversize request that sends a little and then stalls.
  Future<P3Raw> stalledOversize() async {
    final raw = await P3Raw.tls(port);
    raw.write(
      'POST $kApiPrefix/sessions HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n'
      'Content-Length: ${1024 * 1024}\r\n\r\n',
    );
    raw.writeBytes(List.filled(1024, 0x20));
    await raw.socket.flush();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return raw;
  }

  test('the default idle timeout is between 1 s and 10 s', () {
    final s = ApiServer(
      handler: P3SecureHandler(),
      security: SecurityConfig.tls(
        identity: p3ServerKey,
        trust: InMemoryTrustStore(),
      ),
    );
    expect(s.bodyIdleTimeout, greaterThanOrEqualTo(const Duration(seconds: 1)));
    expect(s.bodyIdleTimeout, lessThanOrEqualTo(const Duration(seconds: 10)));
  });

  test('[RED] two stalled oversize bodies do not keep the slots: a legitimate large request is served within idle + 3 s', () async {
    final a = await stalledOversize();
    final b = await stalledOversize();
    addTearDown(a.destroy);
    addTearDown(b.destroy);
    // While both are stalled and inside the idle window the cap is in force (twin of the
    // oversize_test cap test, so this test cannot pass by having no cap at all).
    expect(await legit(), 429);

    final end = DateTime.now().add(_idle + const Duration(seconds: 3));
    var status = 429;
    while (status == 429 && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      status = await legit();
    }
    expect(
      status,
      202,
      reason: 'slots of stalled bodies must be freed after the idle timeout',
    );
  });

  test('[RED] a stalled small body (POST /register) is cut off after the idle timeout', () async {
    final raw = await P3Raw.tls(port);
    addTearDown(raw.destroy);
    raw.write(
      'POST $kApiPrefix/register HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n'
      'Content-Length: 500\r\n\r\n{"deviceId"',
    );
    await raw.socket.flush();
    final head = await raw.waitForHead(const Duration(seconds: 4));
    expect(
      raw.isClosed || head.startsWith('HTTP/1.1 4'),
      isTrue,
      reason: 'no answer and no close within 4 s of a stalled body: $head',
    );
  });

  test('a slow but steady legitimate upload is not punished (each gap is shorter than the idle timeout)', () async {
    // 8 pieces, 400 ms apart: about 3 s in total, three times the idle timeout.
    final status = await legit(
      length: 300 * 1024,
      pieces: 8,
      gap: const Duration(milliseconds: 400),
    );
    expect(status, 202);
    expect(handler.count('createAuthenticatedSession'), 1);
  });

  test('a body that ends cleanly leaves no slot behind: three sequential large requests all succeed', () async {
    for (var i = 0; i < 3; i++) {
      expect(await legit(), 202, reason: 'request $i');
    }
  });
}
