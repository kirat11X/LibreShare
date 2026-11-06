// ApiClient <-> ApiServer round trips through a scriptable handler, plus the
// client's error / transport behaviour against hostile or absent servers.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/api_fake_handler.dart';

Matcher lsError(LsErrorCode code, [String? message]) => isA<LsException>()
    .having((e) => e.code, 'code', code)
    .having(
      (e) => e.message,
      'message',
      message == null ? isA<String>() : equals(message),
    );

void main() {
  late FakeIncomingHandler fake;
  late ApiServer server;
  late ApiClient client;
  late int port;

  Future<void> startServer({
    bool enableRateLimit = false,
    RateLimiter? rateLimiter,
  }) async {
    server = ApiServer(
      handler: fake,
      bindAddress: InternetAddress.loopbackIPv4,
      preferredPort: 0,
      enableRateLimit: enableRateLimit,
      rateLimiter: rateLimiter,
    );
    port = await server.start();
    client = ApiClient(host: '127.0.0.1', port: port);
  }

  setUp(() async {
    fake = FakeIncomingHandler();
    await startServer();
  });

  tearDown(() async {
    client.close();
    await server.stop(force: true);
  });

  group('round trip through the handler', () {
    test('info', () async {
      fake.info = DeviceInfo(
        deviceId: 'd-1',
        alias: 'Küche-Laptop ✓',
        platform: 'android',
        deviceType: 'phone',
        port: 53320,
        addrs: const [DeviceAddress('192.168.1.7', iface: 'wifi')],
        caps: const ['resume', 'sas'],
        fingerprint: 'AB' * 32,
      );
      final i = await client.info();
      expect(i.deviceId, 'd-1');
      expect(i.alias, 'Küche-Laptop ✓');
      expect(i.platform, 'android');
      expect(i.deviceType, 'phone');
      expect(i.port, 53320);
      expect(i.addrs.single.ip, '192.168.1.7');
      expect(i.addrs.single.iface, 'wifi');
      expect(i.caps, ['resume', 'sas']);
      expect(i.fingerprint, 'AB' * 32);
    });

    test('register sends our DeviceInfo and returns the peer one', () async {
      const me = DeviceInfo(
        deviceId: 'me',
        alias: 'Me',
        platform: 'linux',
        port: 53399,
      );
      final other = await client.register(me);
      expect(other.deviceId, 'dev-receiver');
      expect(fake.lastRegistered!.deviceId, 'me');
      expect(fake.lastRegistered!.port, 53399);
    });

    test('createSession: 202 -> PENDING', () async {
      final req = sampleRequest(pin: '654321');
      final s = await client.createSession(req);
      expect(s.sessionId, 'sess-1');
      expect(s.status, TransferStatus.pending);
      expect(fake.lastRemoteAddress, '127.0.0.1');
      expect(fake.lastRequest!.pin, '654321');
      expect(fake.lastRequest!.files.map((f) => f.fileId), ['f1', 'f2']);
      expect(fake.lastRequest!.totalSize, req.totalSize);
    });

    test(
      'createSession: 200 with tokens (auto-accept) and full manifest',
      () async {
        fake.onCreateSession = (r, _) async => SessionStatus(
          sessionId: 'sess-2',
          status: TransferStatus.inProgress,
          acceptedFiles: {
            for (final f in r.files)
              f.fileId: AcceptedFile(
                token: 'tok-${f.fileId}',
                receivedRanges: const [
                  [0, 2],
                ],
              ),
          },
        );
        final offer = TunnelOffer(
          provider: 'fake',
          url: 'https://x.example/t/abc',
          keyB64: 'AAAA',
          expiresAt: DateTime.utc(2026, 11, 4, 12),
        );
        final sent = SessionRequest(
          sender: sampleRequest().sender,
          files: [
            FileItem(
              fileId: 'big',
              fileName: 'große Datei.bin',
              relativePath: 'a/b/c.bin',
              size: 5 * 1024 * 1024 * 1024,
              chunkCount: 1280,
              mime: 'application/zip',
              sha256: 'ab' * 32,
              modified: DateTime.utc(2026, 10, 30, 10),
            ),
          ],
          totalSize: 5 * 1024 * 1024 * 1024,
          tunnelOffer: offer,
          chunkSize: 1024 * 1024,
        );
        final s = await client.createSession(sent);
        expect(s.status, TransferStatus.inProgress);
        expect(s.acceptedFiles['big']!.token, 'tok-big');
        expect(s.acceptedFiles['big']!.receivedRanges, [
          [0, 2],
        ]);
        final got = fake.lastRequest!;
        expect(got.files.single.fileName, 'große Datei.bin');
        expect(got.files.single.relativePath, 'a/b/c.bin');
        expect(got.files.single.size, 5 * 1024 * 1024 * 1024);
        expect(got.files.single.sha256, 'ab' * 32);
        expect(got.files.single.modified, DateTime.utc(2026, 10, 30, 10));
        expect(got.chunkSize, 1024 * 1024);
        expect(got.tunnelOffer!.url, 'https://x.example/t/abc');
        expect(got.tunnelOffer!.expiresAt, offer.expiresAt);
      },
    );

    test('waitSession passes the wait (server clamps to 25 s)', () async {
      final s = await client.waitSession('s-1', waitSeconds: 7);
      expect(s.sessionId, 's-1');
      expect(fake.lastWait, const Duration(seconds: 7));
      await client.waitSession('s-1', waitSeconds: 0);
      expect(fake.lastWait, Duration.zero);
      await client.waitSession('s-1', waitSeconds: 100);
      expect(fake.lastWait, const Duration(seconds: 25));
      await client.waitSession('s-1');
      expect(fake.lastWait, const Duration(seconds: 25), reason: 'default');
    });

    test('waitSession sees a status change from a held long-poll', () async {
      fake.onGetSession = (sid, wait) async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return SessionStatus(
          sessionId: sid,
          status: TransferStatus.inProgress,
          acceptedFiles: const {'f1': AcceptedFile(token: 'T')},
        );
      };
      final s = await client.waitSession('abc', waitSeconds: 25);
      expect(s.status, TransferStatus.inProgress);
      expect(s.acceptedFiles['f1']!.token, 'T');
    });

    test('FAILED(REJECTED) arrives as a normal status', () async {
      fake.onGetSession = (sid, _) async => SessionStatus(
        sessionId: sid,
        status: TransferStatus.failed,
        failureReason: FailureReason.rejected,
      );
      final s = await client.waitSession('s', waitSeconds: 0);
      expect(s.status, TransferStatus.failed);
      expect(s.failureReason, FailureReason.rejected);
    });

    test(
      'cancelled sessions surface as LsException(CANCELLED) (410)',
      () async {
        fake.onGetSession = (sid, _) async => SessionStatus(
          sessionId: sid,
          status: TransferStatus.failed,
          failureReason: FailureReason.cancelled,
        );
        await expectLater(
          client.waitSession('s', waitSeconds: 0),
          throwsA(lsError(LsErrorCode.cancelled)),
        );
      },
    );

    test('fileState sends the bearer token and ids', () async {
      final st = await client.fileState('s-9', 'f-3', token: 'tok-xyz');
      expect(st.receivedRanges, [
        [0, 1],
        [4, 4],
      ]);
      expect(st.chunkCount, 6);
      expect(
        (fake.lastSessionId, fake.lastFileId, fake.lastToken),
        ('s-9', 'f-3', 'tok-xyz'),
      );
    });

    test('ids with spaces / unicode are encoded and decoded', () async {
      await client.fileState('s é 1', 'f 2', token: 't');
      expect(fake.lastSessionId, 's é 1');
      expect(fake.lastFileId, 'f 2');
    });

    test('putChunk streams a 6 MiB body with token and hash header', () async {
      final data = patternBytes(6 * 1024 * 1024);
      Stream<List<int>> pieces() async* {
        for (var o = 0; o < data.length; o += 64 * 1024) {
          yield Uint8List.sublistView(data, o, o + 64 * 1024);
        }
      }

      await client.putChunk(
        'sA',
        'fB',
        3,
        pieces(),
        length: data.length,
        chunkSha256: sha256Hex(data),
        token: 'tok-c',
      );
      final c = fake.lastChunk!;
      expect(
        (c.sessionId, c.fileId, c.index, c.token),
        ('sA', 'fB', 3, 'tok-c'),
      );
      expect(c.chunkSha256, sha256Hex(data));
      expect(c.byteCount, data.length);
      expect(c.sha256Hex, sha256Hex(data));
    });

    test('putChunk is not buffered: the server sees bytes before the source finishes', () async {
      final firstSeen = Completer<void>();
      var total = 0;
      fake.onPutChunk = (sid, fid, idx, body, token, sha) async {
        await for (final c in body) {
          total += c.length;
          if (!firstSeen.isCompleted) firstSeen.complete();
        }
      };
      final data = patternBytes(4 * 1024 * 1024);
      var waitedForServer = false;
      Stream<List<int>> source() async* {
        yield Uint8List.sublistView(data, 0, 256 * 1024);
        // The rest is only produced after the handler already got data.
        await firstSeen.future.timeout(const Duration(seconds: 10));
        waitedForServer = true;
        yield Uint8List.sublistView(data, 256 * 1024);
      }

      await client.putChunk(
        's',
        'f',
        0,
        source(),
        length: data.length,
        chunkSha256: sha256Hex(data),
        token: 't',
      );
      expect(waitedForServer, isTrue);
      expect(total, data.length);
    });

    test('putChunk of an empty body works (length 0)', () async {
      await client.putChunk(
        's',
        'f',
        0,
        const Stream<List<int>>.empty(),
        length: 0,
        chunkSha256: sha256Hex(const []),
        token: 't',
      );
      expect(fake.lastChunk!.byteCount, 0);
    });

    test('putChunk rejected early by the handler maps cleanly and keeps the client usable', () async {
      fake.onPutChunk = (_, _, _, _, _, _) async =>
          throw LsException(LsErrorCode.tokenInvalid, 'nope');
      final data = patternBytes(4 * 1024 * 1024);
      await expectLater(
        client.putChunk(
          's',
          'f',
          0,
          Stream.value(data),
          length: data.length,
          chunkSha256: sha256Hex(data),
          token: 'bad',
        ),
        throwsA(lsError(LsErrorCode.tokenInvalid, 'nope')),
      );
      expect((await client.info()).deviceId, 'dev-receiver');
    });

    test(
      'putChunk whose stream does not match length fails as a transport error',
      () async {
        await expectLater(
          client.putChunk(
            's',
            'f',
            0,
            Stream.value(Uint8List(10)),
            length: 20,
            chunkSha256: sha256Hex(Uint8List(10)),
            token: 't',
          ),
          throwsA(isA<SocketException>()),
        );
        expect(fake.calls, isNot(contains('putChunk')));
      },
    );

    test('completeFile with and without a whole-file sha256', () async {
      final a = await client.completeFile('s', 'f', token: 'tok');
      expect(a.verified, isTrue);
      expect(fake.lastSha256, isNull);
      expect(fake.lastToken, 'tok');
      final h = 'cd' * 32;
      final b = await client.completeFile('s', 'f', token: 'tok', sha256: h);
      expect(fake.lastSha256, h);
      expect(b.sha256, h);
    });

    test('finish returns COMPLETED', () async {
      final s = await client.finish('s-7');
      expect(s.status, TransferStatus.completed);
      expect(s.sessionId, 's-7');
    });

    test('cancel reaches the handler', () async {
      await client.cancel('s-8');
      expect(fake.calls.last, 'cancel');
      expect(fake.lastSessionId, 's-8');
    });

    test('a full sequence reuses one connection', () async {
      final ports = <int>{};
      final raw = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => raw.close(force: true));
      raw.listen((r) {
        ports.add(r.connectionInfo!.remotePort);
        r.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(sampleRequest().sender.toJson()))
          ..close();
      });
      final c = ApiClient(host: '127.0.0.1', port: raw.port);
      addTearDown(c.close);
      for (var i = 0; i < 6; i++) {
        await c.info();
      }
      expect(ports, hasLength(1));
    });
  });

  group('LsException mapping', () {
    final calls = <String, (void Function(Object), Future<Object?> Function())>{
      'info': ((e) => fake.onDeviceInfo = () => throw e, () => client.info()),
      'register': (
        (e) => fake.onRegister = (_) => throw e,
        () => client.register(sampleRequest().sender),
      ),
      'createSession': (
        (e) => fake.onCreateSession = (_, _) => throw e,
        () => client.createSession(sampleRequest()),
      ),
      'waitSession': (
        (e) => fake.onGetSession = (_, _) => throw e,
        () => client.waitSession('s', waitSeconds: 0),
      ),
      'fileState': (
        (e) => fake.onFileState = (_, _, _) => throw e,
        () => client.fileState('s', 'f', token: 't'),
      ),
      'putChunk': (
        (e) => fake.onPutChunk = (_, _, _, _, _, _) => throw e,
        () => client.putChunk(
          's',
          'f',
          0,
          Stream.value(Uint8List(3)),
          length: 3,
          chunkSha256: 'a' * 64,
          token: 't',
        ),
      ),
      'completeFile': (
        (e) => fake.onComplete = (_, _, _, _) => throw e,
        () => client.completeFile('s', 'f', token: 't'),
      ),
      'finish': (
        (e) => fake.onFinish = (_) => throw e,
        () => client.finish('s'),
      ),
      'cancel': (
        (e) => fake.onCancel = (_) => throw e,
        () => client.cancel('s'),
      ),
    };

    for (final entry in calls.entries) {
      test('${entry.key}: every LsErrorCode round-trips', () async {
        for (final code in LsErrorCode.values) {
          entry.value.$1(LsException(code, 'msg ${code.wire}'));
          await expectLater(
            entry.value.$2(),
            throwsA(lsError(code, 'msg ${code.wire}')),
            reason: '${entry.key} / ${code.wire}',
          );
        }
      });
    }

    test('retryable flag and http status follow the code', () async {
      fake.onGetSession = (_, _) async =>
          throw LsException(LsErrorCode.chunkHashMismatch, 'x');
      try {
        await client.waitSession('s', waitSeconds: 0);
        fail('expected LsException');
      } on LsException catch (e) {
        expect(e.retryable, isTrue);
        expect(e.httpStatus, 422);
      }
    });

    test('426 UPGRADE_REQUIRED from a v2 sender', () async {
      await expectLater(
        client.createSession(sampleRequest(version: '2.0')),
        throwsA(lsError(LsErrorCode.upgradeRequired)),
      );
      expect(fake.calls, isNot(contains('createSession')));
    });

    test('429 RATE_LIMITED from the server limiter', () async {
      client.close();
      await server.stop(force: true);
      final now = DateTime.utc(2026, 11, 3);
      await startServer(
        enableRateLimit: true,
        rateLimiter: RateLimiter(clock: () => now),
      );
      for (var i = 0; i < 10; i++) {
        await client.createSession(sampleRequest());
      }
      await expectLater(
        client.createSession(sampleRequest()),
        throwsA(lsError(LsErrorCode.rateLimited)),
      );
    });

    test(
      'unexpected handler failure becomes INTERNAL without leaking',
      () async {
        fake.onGetSession = (_, _) async =>
            throw StateError('secret /etc/shadow');
        await expectLater(
          client.waitSession('s', waitSeconds: 0),
          throwsA(
            isA<LsException>()
                .having((e) => e.code, 'code', LsErrorCode.internal)
                .having((e) => e.message, 'message', isNot(contains('secret'))),
          ),
        );
      },
    );
  });

  group('hostile or odd servers', () {
    late HttpServer raw;
    late ApiClient c;

    Future<void> serve(
      void Function(HttpRequest) onRequest, {
      Duration requestTimeout = const Duration(seconds: 5),
    }) async {
      raw = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      raw.listen(onRequest);
      c = ApiClient(
        host: '127.0.0.1',
        port: raw.port,
        requestTimeout: requestTimeout,
      );
    }

    tearDown(() async {
      c.close();
      await raw.close(force: true);
    });

    void reply(HttpRequest r, int status, String body, {String? type}) {
      r.response
        ..statusCode = status
        ..headers.set(HttpHeaders.contentTypeHeader, type ?? 'application/json')
        ..write(body)
        ..close();
    }

    test('non-JSON error body -> INTERNAL "HTTP <status>"', () async {
      await serve(
        (r) => reply(r, 502, '<html>Bad Gateway</html>', type: 'text/html'),
      );
      await expectLater(
        c.info(),
        throwsA(lsError(LsErrorCode.internal, 'HTTP 502')),
      );
    });

    test('empty error body -> INTERNAL', () async {
      await serve((r) => reply(r, 503, ''));
      await expectLater(
        c.cancel('s'),
        throwsA(lsError(LsErrorCode.internal, 'HTTP 503')),
      );
    });

    test('JSON that is not an envelope -> INTERNAL', () async {
      for (final body in [
        '[]',
        '{"foo":1}',
        '{"error":"flat"}',
        '"str"',
        'null',
      ]) {
        await serve((r) => reply(r, 400, body));
        await expectLater(
          c.finish('s'),
          throwsA(lsError(LsErrorCode.internal)),
          reason: body,
        );
        c.close();
        await raw.close(force: true);
      }
      // tearDown closes the last (already closed) pair again: must be harmless.
      await serve((r) => reply(r, 200, '{}'));
    });

    test(
      'envelope with an unknown code -> INTERNAL but keeps the message',
      () async {
        await serve(
          (r) => reply(
            r,
            418,
            '{"error":{"code":"TEAPOT","message":"short and stout","retryable":false}}',
          ),
        );
        await expectLater(
          c.info(),
          throwsA(lsError(LsErrorCode.internal, 'short and stout')),
        );
      },
    );

    test('envelope with extra fields (426 "supported") still maps', () async {
      await serve(
        (r) => reply(
          r,
          426,
          '{"error":{"code":"UPGRADE_REQUIRED","message":"old","retryable":false},"supported":["1"]}',
        ),
      );
      await expectLater(
        c.info(),
        throwsA(lsError(LsErrorCode.upgradeRequired, 'old')),
      );
    });

    test('2xx with malformed JSON -> INTERNAL', () async {
      await serve((r) => reply(r, 200, '{not json'));
      await expectLater(c.info(), throwsA(lsError(LsErrorCode.internal)));
    });

    test('2xx with the wrong shape -> INTERNAL', () async {
      for (final body in ['[]', '{"deviceId":5}', '{}', '']) {
        await serve((r) => reply(r, 200, body));
        await expectLater(
          c.info(),
          throwsA(lsError(LsErrorCode.internal)),
          reason: body,
        );
        c.close();
        await raw.close(force: true);
      }
      await serve((r) => reply(r, 200, '{}'));
    });

    test('2xx with an empty body is fine for void calls', () async {
      await serve((r) => reply(r, 200, ''));
      await c.cancel('s');
      await c.putChunk(
        's',
        'f',
        0,
        Stream.value([1]),
        length: 1,
        chunkSha256: 'a' * 64,
        token: 't',
      );
    });

    test('redirects are not followed', () async {
      await serve((r) {
        r.response
          ..statusCode = 302
          ..headers.set(HttpHeaders.locationHeader, '/elsewhere')
          ..close();
      });
      await expectLater(
        c.info(),
        throwsA(lsError(LsErrorCode.internal, 'HTTP 302')),
      );
    });

    test('request timeout -> TimeoutException, client stays usable', () async {
      var slow = true;
      await serve((r) {
        if (slow) {
          slow = false; // never answer the first request
          return;
        }
        reply(r, 200, jsonEncode(sampleRequest().sender.toJson()));
      }, requestTimeout: const Duration(milliseconds: 300));
      await expectLater(c.info(), throwsA(isA<TimeoutException>()));
      expect((await c.info()).deviceId, 'dev-sender');
    });

    test(
      'waitSession ignores requestTimeout and allows waitSeconds + 10 s',
      () async {
        expect(ApiClient.longPollTimeout(25), const Duration(seconds: 35));
        expect(ApiClient.longPollTimeout(0), const Duration(seconds: 10));
        expect(ApiClient.longPollTimeout(-5), const Duration(seconds: 10));
        await serve((r) async {
          await Future<void>.delayed(const Duration(milliseconds: 700));
          reply(r, 200, '{"sessionId":"s","status":"PENDING"}');
        }, requestTimeout: const Duration(milliseconds: 200));
        // info() with the 200 ms request timeout would time out ...
        await expectLater(c.info(), throwsA(isA<TimeoutException>()));
        // ... the long poll does not.
        final st = await c.waitSession('s', waitSeconds: 1);
        expect(st.status, TransferStatus.pending);
      },
    );

    test(
      'server drops the connection mid-response -> SocketException',
      () async {
        await serve((r) async {
          final s = await r.response.detachSocket(writeHeaders: false);
          s.write('HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n{"half');
          await s.flush();
          s.destroy();
        });
        await expectLater(c.info(), throwsA(isA<SocketException>()));
      },
    );

    test('server closes before sending headers -> SocketException (not HttpException)', () async {
      await serve((r) async {
        final s = await r.response.detachSocket(writeHeaders: false);
        s.destroy();
      });
      await expectLater(c.info(), throwsA(isA<SocketException>()));
    });

    test('requests carry the documented headers', () async {
      final seen = <String, HttpHeaders>{};
      final methods = <String, String>{};
      await serve((r) async {
        seen[r.uri.path] = r.headers;
        methods[r.uri.path] = r.method;
        await r.drain<void>();
        reply(r, 200, '{"verified":true,"sha256":"${'a' * 64}"}');
      });
      await c.completeFile('s1', 'f1', token: 'TKN', sha256: 'b' * 64);
      final h = seen['$kApiPrefix/sessions/s1/files/f1/complete']!;
      expect(h.value('authorization'), 'Bearer TKN');
      expect(h.contentType?.mimeType, 'application/json');
      expect(h.contentLength, greaterThan(0));
      expect(h.value('transfer-encoding'), isNull);
      expect(h.value('user-agent'), startsWith('LibreShare/'));
      expect(methods['$kApiPrefix/sessions/s1/files/f1/complete'], 'POST');

      await c.putChunk(
        's1',
        'f1',
        4,
        Stream.value(Uint8List(5)),
        length: 5,
        chunkSha256: 'c' * 64,
        token: 'TKN2',
      );
      final p = seen['$kApiPrefix/sessions/s1/files/f1/chunks/4']!;
      expect(methods['$kApiPrefix/sessions/s1/files/f1/chunks/4'], 'PUT');
      expect(p.value('authorization'), 'Bearer TKN2');
      expect(p.value('x-ls-chunk-sha256'), 'c' * 64);
      expect(p.contentLength, 5);
      expect(
        p.value('transfer-encoding'),
        isNull,
        reason: 'explicit content-length, no chunking',
      );

      // (the canned reply is not a SessionStatus; only the request matters)
      await expectLater(
        c.createSession(sampleRequest()),
        throwsA(isA<LsException>()),
      );
      final s = seen['$kApiPrefix/sessions']!;
      expect(
        s.value('authorization'),
        isNull,
        reason: 'no token on unauthenticated routes',
      );
    });
  });

  group('transport failures are not wrapped', () {
    test('server down -> SocketException on every call', () async {
      await server.stop(force: true);
      final calls = <Future<Object?> Function()>[
        () => client.info(),
        () => client.register(sampleRequest().sender),
        () => client.createSession(sampleRequest()),
        () => client.waitSession('s', waitSeconds: 0),
        () => client.fileState('s', 'f', token: 't'),
        () => client.putChunk(
          's',
          'f',
          0,
          Stream.value([1]),
          length: 1,
          chunkSha256: 'a' * 64,
          token: 't',
        ),
        () => client.completeFile('s', 'f', token: 't'),
        () => client.finish('s'),
        () => client.cancel('s'),
      ];
      for (final call in calls) {
        await expectLater(call(), throwsA(isA<SocketException>()));
      }
    });

    test(
      'unroutable address with a short connect timeout -> SocketException',
      () async {
        final c = ApiClient(
          host: '10.255.255.1',
          port: 9,
          connectTimeout: const Duration(milliseconds: 300),
        );
        addTearDown(c.close);
        await expectLater(c.info(), throwsA(isA<SocketException>()));
      },
    );

    test(
      'server stopped between calls: next call fails, restart recovers',
      () async {
        expect((await client.info()).deviceId, 'dev-receiver');
        final oldPort = port;
        await server.stop(force: true);
        await expectLater(client.info(), throwsA(isA<SocketException>()));
        server = ApiServer(
          handler: fake,
          bindAddress: InternetAddress.loopbackIPv4,
          preferredPort: oldPort,
          maxPortFallback: oldPort,
          enableRateLimit: false,
        );
        await server.start();
        expect((await client.info()).deviceId, 'dev-receiver');
      },
    );

    test('close() is idempotent and later calls fail loudly', () async {
      client.close();
      client.close();
      await expectLater(client.info(), throwsA(isA<StateError>()));
    });

    test('closing aborts a pending long-poll', () async {
      final gate = Completer<void>();
      fake.onGetSession = (sid, _) async {
        await gate.future;
        return SessionStatus(sessionId: sid, status: TransferStatus.pending);
      };
      final pending = client.waitSession('s', waitSeconds: 25);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      client.close();
      await expectLater(pending, throwsA(isA<Exception>()));
      gate.complete();
    });
  });
}
