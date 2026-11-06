// Regression: ApiServer.stop() is graceful (waits for in-flight responses) and
// a second stop(force: true) escalates a drain that is stuck (found in Inc 2:
// the second call used to be a silent no-op).
import 'dart:async';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/api_fake_handler.dart';

void main() {
  late ApiServer server;
  late int port;

  setUp(() async {
    server = ApiServer(
      handler: FakeIncomingHandler(),
      preferredPort: 0,
      bindAddress: InternetAddress.loopbackIPv4,
      enableRateLimit: false,
    );
    port = await server.start();
  });

  tearDown(() => server.stop(force: true));

  /// Opens a request that stays in flight: a POST promising a body we never send.
  Future<Socket> hangingRequest() async {
    final s = await Socket.connect(InternetAddress.loopbackIPv4, port);
    s.write(
      'POST /api/v1/sessions HTTP/1.1\r\nHost: x\r\n'
      'Content-Type: application/json\r\nContent-Length: 100\r\n\r\n{',
    );
    await s.flush();
    // let the server parse the headers and enter the handler
    await Future<void>.delayed(const Duration(milliseconds: 150));
    return s;
  }

  test('stop() with nothing in flight completes immediately', () async {
    await server.stop().timeout(const Duration(seconds: 2));
    expect(server.isRunning, isFalse);
  });

  test('graceful stop stays pending while a request is in flight', () async {
    final s = await hangingRequest();
    addTearDown(s.destroy);
    var done = false;
    final stopping = server.stop().then((_) => done = true);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(done, isFalse, reason: 'must wait for the in-flight request');
    expect(server.isRunning, isFalse, reason: 'listener is already closed');
    await server.stop(force: true); // escalate
    await stopping.timeout(const Duration(seconds: 3));
    expect(done, isTrue);
  });

  test(
    'stop(force: true) after a graceful stop drops the connection',
    () async {
      final s = await hangingRequest();
      final closed = Completer<void>();
      s.listen(
        (_) {},
        onDone: closed.complete,
        onError: (_) => closed.complete(),
      );
      unawaited(server.stop());
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(closed.isCompleted, isFalse);
      await server.stop(force: true);
      await closed.future.timeout(const Duration(seconds: 3));
    },
  );

  test('no new connections are accepted once stop() has begun', () async {
    final s = await hangingRequest();
    addTearDown(s.destroy);
    unawaited(server.stop());
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await expectLater(
      Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
      ).timeout(const Duration(seconds: 2)),
      throwsA(isA<SocketException>()),
    );
  });
}
