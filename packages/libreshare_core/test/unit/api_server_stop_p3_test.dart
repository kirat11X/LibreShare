// Characterisation of the CURRENT ApiServer.stop()/start() behaviour (plaintext profile), added
// before P3 edits api_server.dart so those edits cannot regress it. These tests PASS today.
// They complement the existing unit/api_server_stop_test.dart (which is not edited): no in-flight
// request completion, no stop-before-start, no concurrent graceful stops, no restart there.
// The secure-profile equivalents are in conformance/api_conformance_secure_test.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/api_fake_handler.dart';

void main() {
  late ApiServer server;
  late int port;

  ApiServer make() => ApiServer(
    handler: FakeIncomingHandler(),
    preferredPort: 0,
    bindAddress: InternetAddress.loopbackIPv4,
    enableRateLimit: false,
  );

  setUp(() async {
    server = make();
    port = await server.start();
  });

  tearDown(() => server.stop(force: true));

  final body = utf8.encode(jsonEncode(sampleRequest().toJson()));

  /// A POST whose body is only partly sent: in flight until [finish] is called.
  Future<(Socket, StringBuffer, Future<void> Function())> halfSent([
    Completer<void>? closedByPeer,
  ]) async {
    final s = await Socket.connect(InternetAddress.loopbackIPv4, port);
    final received = StringBuffer();
    s.listen(
      (d) => received.write(utf8.decode(d, allowMalformed: true)),
      onError: (Object _) {
        if (closedByPeer?.isCompleted == false) closedByPeer!.complete();
      },
      onDone: () {
        if (closedByPeer?.isCompleted == false) closedByPeer!.complete();
      },
    );
    s.write(
      'POST /api/v1/sessions HTTP/1.1\r\nHost: x\r\n'
      'Content-Type: application/json\r\nContent-Length: ${body.length}\r\n\r\n',
    );
    s.add(body.sublist(0, 10));
    await s.flush();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    return (
      s,
      received,
      () async {
        s.add(body.sublist(10));
        await s.flush();
      },
    );
  }

  test(
    'stop() on a server that was never started completes and is harmless',
    () async {
      final idle = make();
      await idle.stop().timeout(const Duration(seconds: 2));
      await idle.stop(force: true).timeout(const Duration(seconds: 2));
      expect(idle.isRunning, isFalse);
    },
  );

  test(
    'port throws StateError once stop() has begun; isRunning is false at once',
    () async {
      unawaited(server.stop());
      expect(server.isRunning, isFalse);
      expect(() => server.port, throwsStateError);
    },
  );

  test('stop() twice in a row, then stop(force: true): each completes without error', () async {
    await server.stop().timeout(const Duration(seconds: 2));
    await server.stop().timeout(const Duration(seconds: 2));
    await server.stop(force: true).timeout(const Duration(seconds: 2));
  });

  test('graceful stop completes after the in-flight request ends, and its response is delivered', () async {
    final (s, received, finish) = await halfSent();
    addTearDown(s.destroy);
    var done = false;
    final stopping = server.stop().then((_) => done = true);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(done, isFalse);
    await finish();
    await stopping.timeout(const Duration(seconds: 5));
    expect(done, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(received.toString(), startsWith('HTTP/1.1 202'));
  });

  test(
    'two concurrent graceful stops both finish once the request ends',
    () async {
      final (s, _, finish) = await halfSent();
      addTearDown(s.destroy);
      final a = server.stop();
      final b = server.stop();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await finish();
      await Future.wait([a, b]).timeout(const Duration(seconds: 5));
    },
  );

  test('stop(force: true) with a request in flight returns promptly and closes the connection', () async {
    final closed = Completer<void>();
    final (s, _, _) = await halfSent(closed);
    final sw = Stopwatch()..start();
    await server.stop(force: true).timeout(const Duration(seconds: 3));
    expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
    await closed.future.timeout(const Duration(seconds: 3));
    s.destroy();
  });

  test('a stopped server can be started again and serves requests', () async {
    await server.stop();
    final again = await server.start();
    expect(server.isRunning, isTrue);
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final req = await client.getUrl(
      Uri.parse('http://127.0.0.1:$again/api/v1/info'),
    );
    final res = await req.close();
    expect(res.statusCode, 200);
    await res.drain<void>();
  });

  test('start() twice without stop() is a StateError (the first server keeps running)', () async {
    await expectLater(server.start(), throwsStateError);
    expect(server.isRunning, isTrue);
  });
}
