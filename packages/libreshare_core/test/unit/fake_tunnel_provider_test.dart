import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libreshare_core/src/tunnel/fake_tunnel_provider.dart';
import 'package:libreshare_core/src/tunnel/tunnel_provider.dart';
import 'package:test/test.dart';

void main() {
  group('FakeTunnelProvider Unit Tests', () {
    late HttpServer mockOrigin;
    late int originPort;

    setUp(() async {
      mockOrigin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      originPort = mockOrigin.port;
      mockOrigin.listen((HttpRequest req) async {
        if (req.uri.path == '/hello') {
          req.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.text
            ..write('hello from origin');
          await req.response.close();
        } else if (req.uri.path == '/echo') {
          final body = await req.fold<List<int>>([], (p, e) => p..addAll(e));
          req.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.binary
            ..add(body);
          await req.response.close();
        } else {
          req.response
            ..statusCode = HttpStatus.notFound
            ..write('not found');
          await req.response.close();
        }
      });
    });

    tearDown(() async {
      await mockOrigin.close(force: true);
    });

    test('implements TunnelProvider interface and contracts', () async {
      final provider = FakeTunnelProvider();
      expect(provider.id, equals('fake'));
      expect(await provider.isAvailable(), isTrue);

      final handle = await provider.open(originPort);
      expect(handle.publicBase.scheme, isIn(['http', 'https']));
      expect(handle.publicBase.host, isIn(['127.0.0.1', 'localhost']));
      expect(handle.publicBase.port, isPositive);

      final events = <TunnelEvent>[];
      final sub = handle.events.listen(events.add);

      // Verify proxy forward
      final client = HttpClient();
      final req = await client.getUrl(handle.publicBase.resolve('/hello'));
      final resp = await req.close();
      expect(resp.statusCode, equals(HttpStatus.ok));
      final text = await resp.transform(utf8.decoder).join();
      expect(text, equals('hello from origin'));
      client.close();

      await handle.close();
      await sub.cancel();
      expect(events.any((e) => e is TunnelUpEvent), isTrue);
    });

    test(
      'enforces in-flight concurrency limit (429 above maxInFlight)',
      () async {
        final provider = FakeTunnelProvider(maxInFlight: 3);
        final handle = await provider.open(originPort);

        // We need a slow origin endpoint to keep requests in flight
        final completer = Completer<void>();
        final slowOrigin = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        slowOrigin.listen((req) async {
          await completer.future;
          req.response.statusCode = 200;
          await req.response.close();
        });

        final slowHandle = await provider.open(slowOrigin.port);
        final client = HttpClient();

        // Launch 3 requests in flight
        final f1 = client
            .getUrl(slowHandle.publicBase.resolve('/test'))
            .then((r) => r.close());
        final f2 = client
            .getUrl(slowHandle.publicBase.resolve('/test'))
            .then((r) => r.close());
        final f3 = client
            .getUrl(slowHandle.publicBase.resolve('/test'))
            .then((r) => r.close());

        // Give event loop time to register in-flight
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // 4th request must be rejected with 429
        final req4 = await client.getUrl(
          slowHandle.publicBase.resolve('/test'),
        );
        final resp4 = await req4.close();
        expect(resp4.statusCode, equals(HttpStatus.tooManyRequests));
        expect(resp4.headers.value('retry-after'), isNotNull);

        // Complete slow requests
        completer.complete();
        await Future.wait([f1, f2, f3]);

        client.close();
        await slowOrigin.close(force: true);
        await slowHandle.close();
        await handle.close();
      },
    );

    test('enforces request body size cap (413 Payload Too Large)', () async {
      final provider = FakeTunnelProvider(
        maxRequestBodyBytes: 1024,
      ); // 1 KiB for test
      final handle = await provider.open(originPort);

      final client = HttpClient();
      final req = await client.postUrl(handle.publicBase.resolve('/echo'));
      req.add(Uint8List(2048)); // 2 KiB exceeds 1 KiB
      final resp = await req.close();

      expect(resp.statusCode, equals(HttpStatus.requestEntityTooLarge));
      client.close();
      await handle.close();
    });

    test(
      'capture buffer records all frames and detects plaintext markers',
      () async {
        final provider = FakeTunnelProvider();
        final handle = await provider.open(originPort);

        final client = HttpClient();
        final req = await client.postUrl(handle.publicBase.resolve('/echo'));
        final payload = utf8.encode('SUPER_SECRET_PLAINTEXT_PAYLOAD');
        req.add(payload);
        final resp = await req.close();
        await resp.drain();

        expect(provider.captureBuffer, isNotEmpty);
        expect(provider.containsPlaintext(payload), isTrue);
        expect(
          provider.containsPlaintext(utf8.encode('NOT_IN_TRAFFIC')),
          isFalse,
        );

        client.close();
        await handle.close();
      },
    );
  });
}
