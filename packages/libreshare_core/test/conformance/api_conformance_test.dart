// LSP/1 REST conformance for ApiServer (spec section 4.3 / 4.6 / 5).
//
// Talks to the server with a raw dart:io HttpClient (not ApiClient) so the
// wire contract is asserted independently of our own client.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/api_fake_handler.dart';

class Res {
  Res(this.status, this.headers, this.text);
  final int status;
  final HttpHeaders headers;
  final String text;
  Object? get json => jsonDecode(text);
  Map<String, Object?> get map => (json! as Map).cast<String, Object?>();
  Map<String, Object?> get error =>
      (map['error']! as Map).cast<String, Object?>();
}

void main() {
  late FakeIncomingHandler fake;
  late ApiServer server;
  late HttpClient http;
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
  }

  setUp(() async {
    fake = FakeIncomingHandler();
    http = HttpClient();
    await startServer();
  });

  tearDown(() async {
    http.close(force: true);
    await server.stop(force: true);
  });

  Future<Res> call(
    String method,
    String path, {
    Object? json,
    List<int>? bytes,
    Map<String, String> headers = const {},
    bool chunked = false,
  }) async {
    final req = await http.openUrl(
      method,
      Uri.parse('http://127.0.0.1:$port$kApiPrefix$path'),
    );
    headers.forEach(req.headers.set);
    var body = bytes;
    if (json != null) {
      body = utf8.encode(jsonEncode(json));
      req.headers.contentType = ContentType.json;
    }
    if (body != null) {
      if (chunked) {
        req.headers.chunkedTransferEncoding = true;
      } else {
        req.contentLength = body.length;
      }
      req.add(body);
    }
    final resp = await req.close();
    return Res(resp.statusCode, resp.headers, await utf8.decodeStream(resp));
  }

  void expectError(Res r, LsErrorCode code) {
    expect(r.status, code.httpStatus, reason: r.text);
    expect(r.headers.contentType?.mimeType, 'application/json');
    expect(r.error['code'], code.wire);
    expect(r.error['retryable'], code.retryable);
    expect(r.error['message'], isA<String>());
  }

  /// Sends only request headers on a raw socket and returns whatever the
  /// server answers before closing (empty if it just closed the connection).
  /// dart:io may drop the response when a huge declared body is left unread,
  /// so refusing without reading is verified as "413 or closed, never served".
  Future<String> rawHeadOnly(String head) async {
    final s = await Socket.connect('127.0.0.1', port);
    final buf = StringBuffer();
    final done = Completer<void>();
    s.listen(
      (d) => buf.write(utf8.decode(d, allowMalformed: true)),
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      onError: (Object _) {
        if (!done.isCompleted) done.complete();
      },
    );
    s.write(head);
    await done.future.timeout(const Duration(seconds: 10));
    s.destroy();
    return buf.toString();
  }

  const auth = {'authorization': 'Bearer tok-123'};
  const chunkPath = '/sessions/s1/files/f1/chunks/0';

  group('error envelope: handler LsException passthrough on every route', () {
    // route label -> (arm the fake to throw, fire the request)
    final routes = <String, (void Function(Object), Future<Res> Function())>{
      'POST /register': (
        (e) => fake.onRegister = (_) => throw e,
        () => call('POST', '/register', json: sampleRequest().sender.toJson()),
      ),
      'POST /sessions': (
        (e) => fake.onCreateSession = (_, _) => throw e,
        () => call('POST', '/sessions', json: sampleRequest().toJson()),
      ),
      'GET /sessions/{sid}': (
        (e) => fake.onGetSession = (_, _) => throw e,
        () => call('GET', '/sessions/s1?wait=0'),
      ),
      'GET .../state': (
        (e) => fake.onFileState = (_, _, _) => throw e,
        () => call('GET', '/sessions/s1/files/f1/state', headers: auth),
      ),
      'PUT .../chunks/{idx}': (
        (e) => fake.onPutChunk = (_, _, _, _, _, _) => throw e,
        () => call('PUT', chunkPath, bytes: [1, 2, 3], headers: auth),
      ),
      'POST .../complete': (
        (e) => fake.onComplete = (_, _, _, _) => throw e,
        () => call('POST', '/sessions/s1/files/f1/complete', headers: auth),
      ),
      'POST .../finish': (
        (e) => fake.onFinish = (_) => throw e,
        () => call('POST', '/sessions/s1/finish'),
      ),
      'POST .../cancel': (
        (e) => fake.onCancel = (_) => throw e,
        () => call('POST', '/sessions/s1/cancel'),
      ),
    };

    for (final entry in routes.entries) {
      test(entry.key, () async {
        for (final code in LsErrorCode.values) {
          entry.value.$1(LsException(code, 'boom ${code.wire}'));
          final r = await entry.value.$2();
          expect(
            r.status,
            code.httpStatus,
            reason: '${entry.key} / ${code.wire}',
          );
          expect(r.headers.contentType?.mimeType, 'application/json');
          expect(r.error['code'], code.wire);
          expect(r.error['message'], 'boom ${code.wire}');
          expect(r.error['retryable'], code.retryable);
        }
      });
    }
  });

  group('GET /info', () {
    test('200 with DeviceInfo', () async {
      final r = await call('GET', '/info');
      expect(r.status, 200);
      expect(r.headers.contentType?.mimeType, 'application/json');
      expect(r.map['proto'], 'libreshare');
      expect(r.map['v'], '1.0');
      expect(r.map['deviceId'], 'dev-receiver');
      expect(r.map['alias'], 'Receiver');
      expect(r.map['platform'], 'linux');
      expect(r.map['port'], 53318);
      expect((r.map['addrs']! as List).single, {
        'ip': '10.0.0.5',
        'if': 'wifi',
      });
    });

    test('needs no Authorization header', () async {
      expect((await call('GET', '/info')).status, 200);
    });
  });

  group('POST /register', () {
    test(
      '200 returns our DeviceInfo and passes the peer to the handler',
      () async {
        final peer = sampleRequest().sender;
        final r = await call('POST', '/register', json: peer.toJson());
        expect(r.status, 200);
        expect(r.map['deviceId'], 'dev-receiver');
        expect(fake.lastRegistered!.deviceId, 'dev-sender');
        expect(fake.lastRegistered!.alias, 'Sender');
      },
    );

    test('unknown fields are ignored', () async {
      final body = sampleRequest().sender.toJson()
        ..['futureField'] = {
          'nested': [1, 2, 3],
        }
        ..['addrs'] = [
          {'ip': '10.0.0.9', 'if': 'wifi', 'metric': 5},
        ];
      final r = await call('POST', '/register', json: body);
      expect(r.status, 200, reason: r.text);
      expect(fake.lastRegistered!.addrs.single.ip, '10.0.0.9');
    });

    test(
      '400 BAD_REQUEST: malformed JSON, non-object, empty, missing deviceId',
      () async {
        expectError(
          await call('POST', '/register', bytes: utf8.encode('{nope')),
          LsErrorCode.badRequest,
        );
        expectError(
          await call('POST', '/register', json: [1, 2]),
          LsErrorCode.badRequest,
        );
        expectError(
          await call('POST', '/register', bytes: const []),
          LsErrorCode.badRequest,
        );
        expectError(
          await call('POST', '/register', json: {'alias': 'x'}),
          LsErrorCode.badRequest,
        );
        expect(fake.calls, isNot(contains('register')));
      },
    );

    test(
      '426 UPGRADE_REQUIRED for unknown major, with supported majors',
      () async {
        final body = sampleRequest().sender.toJson()..['v'] = '2.0';
        final r = await call('POST', '/register', json: body);
        expectError(r, LsErrorCode.upgradeRequired);
        expect(r.map['supported'], ['1']);
        expect(fake.calls, isNot(contains('register')));
      },
    );
  });

  group('POST /sessions', () {
    test('202 {sessionId,status:PENDING} and handler sees the parsed request + remote', () async {
      final r = await call(
        'POST',
        '/sessions',
        json: sampleRequest(pin: '123456').toJson(),
      );
      expect(r.status, 202);
      expect(r.headers.contentType?.mimeType, 'application/json');
      expect(r.map['sessionId'], 'sess-1');
      expect(r.map['status'], 'PENDING');
      expect(fake.lastRemoteAddress, '127.0.0.1');
      final req = fake.lastRequest!;
      expect(req.sender.deviceId, 'dev-sender');
      expect(req.pin, '123456');
      expect(req.files.map((f) => f.fileId), ['f1', 'f2']);
      expect(req.totalSize, 10);
      expect(req.chunkSize, kChunkSize);
    });

    test('200 with acceptedFiles when the handler auto-accepts', () async {
      fake.onCreateSession = (_, _) async => const SessionStatus(
        sessionId: 'sess-9',
        status: TransferStatus.inProgress,
        acceptedFiles: {
          'f1': AcceptedFile(
            token: 'tok-f1',
            receivedRanges: [
              [0, 3],
            ],
          ),
        },
      );
      final r = await call('POST', '/sessions', json: sampleRequest().toJson());
      expect(r.status, 200);
      expect(r.map['status'], 'IN_PROGRESS');
      final f1 = ((r.map['acceptedFiles']! as Map)['f1']! as Map)
          .cast<String, Object?>();
      expect(f1['token'], 'tok-f1');
      expect(f1['receivedRanges'], [
        [0, 3],
      ]);
    });

    test('documented handler errors pass through with their status', () async {
      const expected = {
        LsErrorCode.pinRequired: 401,
        LsErrorCode.pinInvalid: 401,
        LsErrorCode.blocked: 403,
        LsErrorCode.busy: 409,
        LsErrorCode.tooLarge: 413,
        LsErrorCode.rateLimited: 429,
        LsErrorCode.insufficientStorage: 507,
      };
      for (final e in expected.entries) {
        fake.onCreateSession = (_, _) async => throw LsException(e.key, 'x');
        final r = await call(
          'POST',
          '/sessions',
          json: sampleRequest().toJson(),
        );
        expectError(r, e.key);
        expect(r.status, e.value);
      }
    });

    test('unknown fields are ignored at every level', () async {
      final json = sampleRequest().toJson()
        ..['futureTop'] = 'x'
        ..['tunnelOffer'] = {
          'provider': 'fake',
          'url': 'https://x.example/t/abc',
          'keyB64': 'AAAA',
          'expiresAt': '2026-11-02T12:30:00Z',
          'extra': 1,
        };
      (json['sender']! as Map<String, Object?>)['hw'] = 'ThinkPad';
      ((json['files']! as List).first as Map<String, Object?>)['xattr'] = [1];
      final r = await call('POST', '/sessions', json: json);
      expect(r.status, 202, reason: r.text);
      expect(fake.lastRequest!.tunnelOffer!.provider, 'fake');
    });

    test('minor version differences are accepted (1.7)', () async {
      final r = await call(
        'POST',
        '/sessions',
        json: sampleRequest(version: '1.7').toJson(),
      );
      expect(r.status, 202, reason: r.text);
    });

    test(
      '426 UPGRADE_REQUIRED for sender major 2 with supported:["1"]',
      () async {
        for (final v in ['2.0', '2', '10.1', '0.9', '']) {
          final r = await call(
            'POST',
            '/sessions',
            json: sampleRequest(version: v).toJson(),
          );
          expectError(r, LsErrorCode.upgradeRequired);
          expect(r.map['supported'], ['1'], reason: 'v=$v');
        }
        expect(fake.calls, isNot(contains('createSession')));
      },
    );

    test('426 is decided before the rest of the (possibly v2-shaped) body is parsed', () async {
      final r = await call(
        'POST',
        '/sessions',
        json: {
          'sender': {'v': '2.0', 'whatever': true},
          'newShape': 1,
        },
      );
      expectError(r, LsErrorCode.upgradeRequired);
    });

    test(
      '400 BAD_REQUEST for malformed or structurally invalid bodies',
      () async {
        Future<void> bad(Res r) async => expectError(r, LsErrorCode.badRequest);
        await bad(
          await call('POST', '/sessions', bytes: utf8.encode('{"sender":')),
        );
        await bad(
          await call(
            'POST',
            '/sessions',
            bytes: utf8.encode('not json at all'),
          ),
        );
        await bad(await call('POST', '/sessions', bytes: [0xff, 0xfe, 0xfd]));
        await bad(await call('POST', '/sessions', bytes: const []));
        await bad(await call('POST', '/sessions', json: <Object?>[]));
        await bad(await call('POST', '/sessions', json: 'a string'));
        await bad(await call('POST', '/sessions', json: <String, Object?>{}));

        Map<String, Object?> base() => sampleRequest().toJson();
        await bad(
          await call('POST', '/sessions', json: base()..remove('files')),
        );
        await bad(
          await call('POST', '/sessions', json: base()..['files'] = 'nope'),
        );
        await bad(
          await call('POST', '/sessions', json: base()..remove('totalSize')),
        );
        await bad(
          await call('POST', '/sessions', json: base()..['totalSize'] = '10'),
        );
        await bad(
          await call('POST', '/sessions', json: base()..['sender'] = 5),
        );
        await bad(
          await call('POST', '/sessions', json: base()..['totalSize'] = 999),
        );
        await bad(
          await call('POST', '/sessions', json: base()..['chunkSize'] = 0),
        );
        await bad(
          await call('POST', '/sessions', json: base()..['chunkSize'] = -4),
        );
        final negative = base();
        ((negative['files']! as List).first as Map<String, Object?>)['size'] =
            -1;
        negative['totalSize'] = -1;
        await bad(await call('POST', '/sessions', json: negative));
        final badDate = base();
        ((badDate['files']! as List).first
                as Map<String, Object?>)['modified'] =
            'yesterday';
        await bad(await call('POST', '/sessions', json: badDate));
        final badCaps = base();
        (badCaps['sender']! as Map<String, Object?>)['caps'] = [1, 2];
        await bad(await call('POST', '/sessions', json: badCaps));
        expect(fake.calls, isNot(contains('createSession')));
      },
    );

    test(
      '413 TOO_LARGE when the JSON body exceeds 256 KiB (content-length)',
      () async {
        final json = sampleRequest().toJson()
          ..['pad'] = 'x' * (kMaxJsonBytes + 100);
        final r = await call('POST', '/sessions', json: json);
        expectError(r, LsErrorCode.tooLarge);
        expect(fake.calls, isNot(contains('createSession')));
      },
    );

    test(
      '413 TOO_LARGE for a 2 MiB body and the connection stays usable',
      () async {
        final json = sampleRequest().toJson()
          ..['pad'] = 'x' * (2 * 1024 * 1024);
        expectError(
          await call('POST', '/sessions', json: json),
          LsErrorCode.tooLarge,
        );
        expect((await call('GET', '/info')).status, 200);
      },
    );

    test('413 TOO_LARGE is enforced while reading chunked bodies without content-length', () async {
      final json = sampleRequest().toJson()..['pad'] = 'x' * (600 * 1024);
      final r = await call(
        'POST',
        '/sessions',
        bytes: utf8.encode(jsonEncode(json)),
        chunked: true,
      );
      expectError(r, LsErrorCode.tooLarge);
      expect(fake.calls, isNot(contains('createSession')));
    });

    test(
      'the limit is exact: 256 KiB is accepted, 256 KiB + 1 byte is not',
      () async {
        Uint8List bodyOfLength(int total) {
          final base = sampleRequest().toJson()..['pad'] = '';
          final overhead = utf8.encode(jsonEncode(base)).length;
          final json = base..['pad'] = 'x' * (total - overhead);
          final bytes = utf8.encode(jsonEncode(json));
          expect(bytes.length, total);
          return Uint8List.fromList(bytes);
        }

        final ok = await call(
          'POST',
          '/sessions',
          bytes: bodyOfLength(kMaxJsonBytes),
        );
        expect(ok.status, 202, reason: ok.text);
        final tooBig = await call(
          'POST',
          '/sessions',
          bytes: bodyOfLength(kMaxJsonBytes + 1),
        );
        expectError(tooBig, LsErrorCode.tooLarge);
      },
    );

    test('refuses a 100 MiB declared JSON body without reading it', () async {
      final answer = await rawHeadOnly(
        'POST $kApiPrefix/sessions HTTP/1.1\r\nHost: x\r\n'
        'Content-Type: application/json\r\nContent-Length: ${100 * 1024 * 1024}\r\n\r\n',
      );
      expect(
        answer.isEmpty || answer.startsWith('HTTP/1.1 413'),
        isTrue,
        reason: answer,
      );
      expect(fake.calls, isNot(contains('createSession')));
      expect((await call('GET', '/info')).status, 200);
    });
  });

  group('GET /sessions/{sid}?wait=N', () {
    test('200 SessionStatus shape; wait defaults to 0', () async {
      final r = await call('GET', '/sessions/abc-123');
      expect(r.status, 200);
      expect(r.map, {
        'sessionId': 'abc-123',
        'status': 'PENDING',
        'failureReason': null,
        'acceptedFiles': <String, Object?>{},
      });
      expect(fake.lastSessionId, 'abc-123');
      expect(fake.lastWait, Duration.zero);
    });

    test('wait is passed through and clamped to 0..25 seconds', () async {
      Future<Duration?> waitFor(String q) async {
        final r = await call('GET', '/sessions/s1$q');
        expect(r.status, 200, reason: '$q -> ${r.text}');
        return fake.lastWait;
      }

      expect(await waitFor('?wait=0'), Duration.zero);
      expect(await waitFor('?wait=7'), const Duration(seconds: 7));
      expect(await waitFor('?wait=25'), const Duration(seconds: 25));
      expect(await waitFor('?wait=26'), const Duration(seconds: 25));
      expect(await waitFor('?wait=100'), const Duration(seconds: 25));
      expect(
        await waitFor('?wait=99999999999999'),
        const Duration(seconds: 25),
      );
      expect(await waitFor('?wait=-1'), Duration.zero);
      expect(await waitFor('?wait=-99999999999999'), Duration.zero);
      expect(await waitFor('?other=1&wait=3'), const Duration(seconds: 3));
    });

    test('400 BAD_REQUEST for non-integer wait', () async {
      for (final q in ['abc', '1.5', '', '1e3', '0x10', ' 5']) {
        final r = await call(
          'GET',
          '/sessions/s1?wait=${Uri.encodeQueryComponent(q)}',
        );
        expectError(r, LsErrorCode.badRequest);
      }
      expect(fake.calls, isNot(contains('getSession')));
    });

    test('long-poll holds the response until the handler completes', () async {
      fake.onGetSession = (sid, wait) async {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        return SessionStatus(
          sessionId: sid,
          status: TransferStatus.inProgress,
          acceptedFiles: const {'f1': AcceptedFile(token: 't1')},
        );
      };
      final sw = Stopwatch()..start();
      final r = await call('GET', '/sessions/s1?wait=25');
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(350));
      expect(r.status, 200);
      expect(r.map['status'], 'IN_PROGRESS');
      expect(fake.lastWait, const Duration(seconds: 25));
    });

    test('404 NOT_FOUND from the handler', () async {
      fake.onGetSession = (_, _) async =>
          throw LsException(LsErrorCode.notFound, 'no session');
      expectError(await call('GET', '/sessions/zzz'), LsErrorCode.notFound);
    });

    test('410 CANCELLED when the handler throws it', () async {
      fake.onGetSession = (_, _) async =>
          throw LsException(LsErrorCode.cancelled, 'cancelled');
      expectError(await call('GET', '/sessions/s1'), LsErrorCode.cancelled);
    });

    test('410 CANCELLED when the handler reports FAILED(CANCELLED)', () async {
      fake.onGetSession = (sid, _) async => SessionStatus(
        sessionId: sid,
        status: TransferStatus.failed,
        failureReason: FailureReason.cancelled,
      );
      expectError(await call('GET', '/sessions/s1'), LsErrorCode.cancelled);
    });

    test('FAILED with another reason is a normal 200 body', () async {
      fake.onGetSession = (sid, _) async => SessionStatus(
        sessionId: sid,
        status: TransferStatus.failed,
        failureReason: FailureReason.rejected,
      );
      final r = await call('GET', '/sessions/s1');
      expect(r.status, 200);
      expect(r.map['status'], 'FAILED');
      expect(r.map['failureReason'], 'REJECTED');
    });

    test(
      'percent-encoded path parameters are decoded for the handler',
      () async {
        await call('GET', '/sessions/a%20b');
        expect(fake.lastSessionId, 'a b');
      },
    );
  });

  group('GET /sessions/{sid}/files/{fid}/state', () {
    test('200 {receivedRanges,chunkCount} with the bearer token', () async {
      final r = await call('GET', '/sessions/s1/files/f9/state', headers: auth);
      expect(r.status, 200);
      expect(r.map, {
        'receivedRanges': [
          [0, 1],
          [4, 4],
        ],
        'chunkCount': 6,
      });
      expect(fake.lastSessionId, 's1');
      expect(fake.lastFileId, 'f9');
      expect(fake.lastToken, 'tok-123');
    });

    test('401 TOKEN_INVALID when the Authorization header is missing or not Bearer', () async {
      for (final h in <Map<String, String>>[
        {},
        {'authorization': 'Basic dXNlcjpwdw=='},
        {'authorization': 'Bearer'},
        {'authorization': 'Bearer   '},
        {'authorization': 'tok-123'},
      ]) {
        expectError(
          await call('GET', '/sessions/s1/files/f1/state', headers: h),
          LsErrorCode.tokenInvalid,
        );
      }
      expect(fake.calls, isNot(contains('fileState')));
    });

    test('bearer scheme is case-insensitive', () async {
      final r = await call(
        'GET',
        '/sessions/s1/files/f1/state',
        headers: {'authorization': 'bearer abc'},
      );
      expect(r.status, 200);
      expect(fake.lastToken, 'abc');
    });

    test('404 NOT_FOUND and 401 from the handler', () async {
      fake.onFileState = (_, _, _) async =>
          throw LsException(LsErrorCode.notFound, 'x');
      expectError(
        await call('GET', '/sessions/s1/files/f1/state', headers: auth),
        LsErrorCode.notFound,
      );
      fake.onFileState = (_, _, _) async =>
          throw LsException(LsErrorCode.tokenInvalid, 'x');
      expectError(
        await call('GET', '/sessions/s1/files/f1/state', headers: auth),
        LsErrorCode.tokenInvalid,
      );
    });
  });

  group('PUT /sessions/{sid}/files/{fid}/chunks/{idx}', () {
    test(
      '200 {ack:true}; handler gets ids, index, token and lowercase hash',
      () async {
        final data = patternBytes(1000);
        final r = await call(
          'PUT',
          '/sessions/sA/files/fB/chunks/17',
          bytes: data,
          headers: {...auth, 'x-ls-chunk-sha256': 'ABCDEF${'0' * 58}'},
        );
        expect(r.status, 200, reason: r.text);
        expect(r.headers.contentType?.mimeType, 'application/json');
        expect(r.map['ack'], true);
        final c = fake.lastChunk!;
        expect(
          (c.sessionId, c.fileId, c.index, c.token),
          ('sA', 'fB', 17, 'tok-123'),
        );
        expect(c.chunkSha256, 'abcdef${'0' * 58}');
        expect(c.byteCount, 1000);
        expect(c.sha256Hex, sha256Hex(data));
      },
    );

    test('hash header is optional (handler receives null)', () async {
      final r = await call('PUT', chunkPath, bytes: [1, 2, 3], headers: auth);
      expect(r.status, 200);
      expect(fake.lastChunk!.chunkSha256, isNull);
    });

    test('a 6 MiB body reaches the handler complete, byte for byte', () async {
      final data = patternBytes(6 * 1024 * 1024);
      final r = await call(
        'PUT',
        chunkPath,
        bytes: data,
        headers: {...auth, 'x-ls-chunk-sha256': sha256Hex(data)},
      );
      expect(r.status, 200, reason: r.text);
      expect(fake.lastChunk!.byteCount, data.length);
      expect(fake.lastChunk!.sha256Hex, sha256Hex(data));
      expect(
        fake.lastChunk!.eventCount,
        greaterThan(1),
        reason: 'delivered as a stream',
      );
    });

    test('the body is streamed: the handler sees bytes before the client finishes sending', () async {
      final data = patternBytes(6 * 1024 * 1024);
      final firstBytes = Completer<int>();
      var total = 0;
      fake.onPutChunk = (sid, fid, idx, body, token, sha) async {
        await for (final c in body) {
          total += c.length;
          if (!firstBytes.isCompleted) firstBytes.complete(total);
        }
      };
      final req = await http.putUrl(
        Uri.parse('http://127.0.0.1:$port$kApiPrefix$chunkPath'),
      );
      req.headers.set('authorization', 'Bearer t');
      req.contentLength = data.length;
      req.add(Uint8List.sublistView(data, 0, 512 * 1024));
      await req.flush();
      // If the server buffered the whole body this would never complete.
      final seen = await firstBytes.future.timeout(const Duration(seconds: 10));
      expect(seen, lessThan(data.length));
      req.add(Uint8List.sublistView(data, 512 * 1024));
      final resp = await req.close();
      await resp.drain<void>();
      expect(resp.statusCode, 200);
      expect(total, data.length);
    });

    test(
      'backpressure: a slow handler does not make the server buffer the body',
      () async {
        final data = patternBytes(6 * 1024 * 1024);
        var received = 0;
        fake.onPutChunk = (sid, fid, idx, body, token, sha) async {
          await for (final c in body) {
            received += c.length;
            await Future<void>.delayed(const Duration(milliseconds: 2));
          }
        };
        final r = await call('PUT', chunkPath, bytes: data, headers: auth);
        expect(r.status, 200);
        expect(received, data.length);
      },
    );

    test(
      '401 TOKEN_INVALID without a Bearer token, handler not called',
      () async {
        expectError(
          await call('PUT', chunkPath, bytes: [1]),
          LsErrorCode.tokenInvalid,
        );
        expectError(
          await call(
            'PUT',
            chunkPath,
            bytes: [1],
            headers: {'authorization': 'Basic x'},
          ),
          LsErrorCode.tokenInvalid,
        );
        expect(fake.calls, isNot(contains('putChunk')));
      },
    );

    test('documented handler errors: 401 / 409 / 416 / 422', () async {
      const codes = {
        LsErrorCode.tokenInvalid: 401,
        LsErrorCode.wrongState: 409,
        LsErrorCode.outOfRange: 416,
        LsErrorCode.chunkHashMismatch: 422,
      };
      for (final e in codes.entries) {
        fake.onPutChunk = (_, _, _, _, _, _) async =>
            throw LsException(e.key, 'x');
        final r = await call('PUT', chunkPath, bytes: [1, 2, 3], headers: auth);
        expectError(r, e.key);
        expect(r.status, e.value);
      }
      expect(LsErrorCode.chunkHashMismatch.retryable, isTrue);
    });

    test('a handler that rejects without reading a 4 MiB body still yields a clean error', () async {
      fake.onPutChunk = (_, _, _, _, _, _) async =>
          throw LsException(LsErrorCode.tokenInvalid, 'bad token');
      final r = await call(
        'PUT',
        chunkPath,
        bytes: patternBytes(4 * 1024 * 1024),
        headers: auth,
      );
      expectError(r, LsErrorCode.tokenInvalid);
      // The (keep-alive) connection must still be healthy afterwards.
      expect((await call('GET', '/info')).status, 200);
    });

    test(
      'a handler that aborts mid-stream still yields a clean error',
      () async {
        fake.onPutChunk = (_, _, _, body, _, _) async {
          await for (final _ in body) {
            throw LsException(LsErrorCode.outOfRange, 'past declared size');
          }
        };
        final r = await call(
          'PUT',
          chunkPath,
          bytes: patternBytes(4 * 1024 * 1024),
          headers: auth,
        );
        expectError(r, LsErrorCode.outOfRange);
        expect((await call('GET', '/info')).status, 200);
      },
    );

    test('400 BAD_REQUEST: non-integer index, bad hash header', () async {
      expectError(
        await call(
          'PUT',
          '/sessions/s1/files/f1/chunks/abc',
          bytes: [1],
          headers: auth,
        ),
        LsErrorCode.badRequest,
      );
      expectError(
        await call(
          'PUT',
          '/sessions/s1/files/f1/chunks/1.5',
          bytes: [1],
          headers: auth,
        ),
        LsErrorCode.badRequest,
      );
      expectError(
        await call(
          'PUT',
          '/sessions/s1/files/f1/chunks/99999999999999999999',
          bytes: [1],
          headers: auth,
        ),
        LsErrorCode.badRequest,
      );
      expectError(
        await call(
          'PUT',
          chunkPath,
          bytes: [1],
          headers: {...auth, 'x-ls-chunk-sha256': 'zz'},
        ),
        LsErrorCode.badRequest,
      );
      expectError(
        await call(
          'PUT',
          chunkPath,
          bytes: [1],
          headers: {...auth, 'x-ls-chunk-sha256': 'g' * 64},
        ),
        LsErrorCode.badRequest,
      );
      expect(fake.calls, isNot(contains('putChunk')));
    });

    test('416 OUT_OF_RANGE for a negative index', () async {
      expectError(
        await call(
          'PUT',
          '/sessions/s1/files/f1/chunks/-1',
          bytes: [1],
          headers: auth,
        ),
        LsErrorCode.outOfRange,
      );
      expect(fake.calls, isNot(contains('putChunk')));
    });

    test('a Content-Length is required (chunked uploads get 400)', () async {
      final r = await call(
        'PUT',
        chunkPath,
        bytes: patternBytes(4096),
        headers: auth,
        chunked: true,
      );
      expectError(r, LsErrorCode.badRequest);
      expect(r.error['message'], contains('Content-Length'));
      expect(fake.calls, isNot(contains('putChunk')));
    });

    test('refuses an absurd declared Content-Length without reading the body', () async {
      final answer = await rawHeadOnly(
        'PUT $kApiPrefix$chunkPath HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer t\r\n'
        'Content-Length: ${1024 * 1024 * 1024}\r\n\r\n',
      );
      expect(
        answer.isEmpty || answer.startsWith('HTTP/1.1 413'),
        isTrue,
        reason: answer,
      );
      expect(fake.calls, isNot(contains('putChunk')));
      expect((await call('GET', '/info')).status, 200);
    });

    test('413 TOO_LARGE for a body over the 64 MiB chunk cap that the client really sends', () async {
      // 65 MiB is declared and sent; the server must not hand it to the
      // handler. (Delivery of the 413 itself is best-effort, see above.)
      final s = await Socket.connect('127.0.0.1', port);
      addTearDown(s.destroy);
      s.write(
        'PUT $kApiPrefix$chunkPath HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer t\r\n'
        'Content-Length: ${65 * 1024 * 1024}\r\n\r\n',
      );
      final answer = StringBuffer();
      final done = Completer<void>();
      s.listen(
        (d) => answer.write(utf8.decode(d, allowMalformed: true)),
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        onError: (Object _) {
          if (!done.isCompleted) done.complete();
        },
      );
      unawaited(() async {
        final piece = Uint8List(1024 * 1024);
        try {
          for (var i = 0; i < 65 && !done.isCompleted; i++) {
            s.add(piece);
            await s.flush();
          }
        } on Object {
          // server closed on us: expected
        }
      }());
      await done.future.timeout(const Duration(seconds: 20));
      expect(fake.calls, isNot(contains('putChunk')));
      expect((await call('GET', '/info')).status, 200);
    });

    test('a client that disconnects mid-body does not break the server', () async {
      final started = Completer<void>();
      final handlerDone = Completer<Object?>();
      fake.onPutChunk = (_, _, _, body, _, _) async {
        try {
          await for (final _ in body) {
            if (!started.isCompleted) started.complete();
          }
          handlerDone.complete(null);
        } catch (e) {
          handlerDone.complete(e);
          rethrow;
        }
      };
      final s = await Socket.connect('127.0.0.1', port);
      s.write(
        'PUT $kApiPrefix$chunkPath HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer t\r\n'
        'Content-Length: 1000000\r\n\r\n',
      );
      s.add(Uint8List(1000));
      await s.flush();
      await started.future.timeout(const Duration(seconds: 10));
      s.destroy();
      // The handler's stream terminates (with an error or early done) ...
      await handlerDone.future.timeout(const Duration(seconds: 10));
      // ... and the server keeps serving.
      expect((await call('GET', '/info')).status, 200);
    });
  });

  group('POST /sessions/{sid}/files/{fid}/complete', () {
    const path = '/sessions/s1/files/f1/complete';

    test(
      '200 {verified,sha256}; no body means no sha256 for the handler',
      () async {
        final r = await call('POST', path, headers: auth);
        expect(r.status, 200);
        expect(r.map['verified'], true);
        expect(r.map['sha256'], 'ab' * 32);
        expect(fake.lastSha256, isNull);
        expect(fake.lastToken, 'tok-123');
      },
    );

    test('optional JSON body {"sha256": ...} is passed on (lowercased); unknown fields ignored', () async {
      final h = 'CD' * 32;
      final r = await call(
        'POST',
        path,
        json: {'sha256': h, 'future': true},
        headers: auth,
      );
      expect(r.status, 200, reason: r.text);
      expect(fake.lastSha256, 'cd' * 32);
      expect(r.map['sha256'], 'cd' * 32);
    });

    test('an empty JSON object or null sha256 means none', () async {
      expect(
        (await call(
          'POST',
          path,
          json: <String, Object?>{},
          headers: auth,
        )).status,
        200,
      );
      expect(fake.lastSha256, isNull);
      expect(
        (await call(
          'POST',
          path,
          json: {'sha256': null},
          headers: auth,
        )).status,
        200,
      );
      expect(fake.lastSha256, isNull);
    });

    test(
      '400 BAD_REQUEST: malformed JSON, non-object, non-hex sha256',
      () async {
        expectError(
          await call('POST', path, bytes: utf8.encode('{'), headers: auth),
          LsErrorCode.badRequest,
        );
        expectError(
          await call('POST', path, json: [1], headers: auth),
          LsErrorCode.badRequest,
        );
        expectError(
          await call('POST', path, json: {'sha256': 'xyz'}, headers: auth),
          LsErrorCode.badRequest,
        );
        expectError(
          await call('POST', path, json: {'sha256': 5}, headers: auth),
          LsErrorCode.badRequest,
        );
        expectError(
          await call('POST', path, json: {'sha256': 'ab' * 31}, headers: auth),
          LsErrorCode.badRequest,
        );
        expect(fake.calls, isNot(contains('completeFile')));
      },
    );

    test('413 TOO_LARGE for a body over 256 KiB', () async {
      final r = await call(
        'POST',
        path,
        json: {'sha256': null, 'pad': 'x' * (kMaxJsonBytes + 1)},
        headers: auth,
      );
      expectError(r, LsErrorCode.tooLarge);
    });

    test('401 TOKEN_INVALID without bearer', () async {
      expectError(await call('POST', path), LsErrorCode.tokenInvalid);
      expect(fake.calls, isNot(contains('completeFile')));
    });

    test(
      'documented handler errors: 422 VERIFY_FAILED, 409 MISSING_CHUNKS',
      () async {
        fake.onComplete = (_, _, _, _) async =>
            throw LsException(LsErrorCode.verifyFailed, 'hash');
        final a = await call('POST', path, headers: auth);
        expectError(a, LsErrorCode.verifyFailed);
        expect(a.status, 422);
        fake.onComplete = (_, _, _, _) async =>
            throw LsException(LsErrorCode.missingChunks, 'gaps');
        final b = await call('POST', path, headers: auth);
        expectError(b, LsErrorCode.missingChunks);
        expect(b.status, 409);
      },
    );
  });

  group('POST /sessions/{sid}/finish and /cancel', () {
    test('finish: 200 with the COMPLETED SessionStatus', () async {
      final r = await call('POST', '/sessions/s1/finish');
      expect(r.status, 200);
      expect(r.map['sessionId'], 's1');
      expect(r.map['status'], 'COMPLETED');
    });

    test('finish: 409 WRONG_STATE', () async {
      fake.onFinish = (_) async =>
          throw LsException(LsErrorCode.wrongState, 'not done');
      final r = await call('POST', '/sessions/s1/finish');
      expectError(r, LsErrorCode.wrongState);
      expect(r.status, 409);
    });

    test('cancel: 200 and handler invoked; 404 passthrough', () async {
      final r = await call('POST', '/sessions/s1/cancel');
      expect(r.status, 200);
      expect(r.headers.contentType?.mimeType, 'application/json');
      expect(fake.calls.last, 'cancel');
      expect(fake.lastSessionId, 's1');
      fake.onCancel = (_) async =>
          throw LsException(LsErrorCode.notFound, 'gone');
      expectError(
        await call('POST', '/sessions/s1/cancel'),
        LsErrorCode.notFound,
      );
    });

    test('request bodies on finish/cancel are ignored and drained', () async {
      final r = await call(
        'POST',
        '/sessions/s1/cancel',
        bytes: patternBytes(100 * 1024),
      );
      expect(r.status, 200);
      expect((await call('GET', '/info')).status, 200);
    });
  });

  group('routing and generic error handling', () {
    test('unknown paths give a 404 NOT_FOUND envelope', () async {
      for (final p in [
        '/nope',
        '/sessions',
        '/sessions/s1/unknown',
        '/sessions/s1/files/f1',
        '/sessions/s1/files/f1/chunks',
        '/sessions/s1/files/f1/chunks/0/extra',
        '/info/extra',
      ]) {
        final r = await call('GET', p);
        expectError(r, LsErrorCode.notFound);
      }
    });

    test(
      'unknown path outside the API prefix and with another major',
      () async {
        for (final url in ['/', '/api', '/api/v2/info', '/info', '/api/v1']) {
          final req = await http.getUrl(
            Uri.parse('http://127.0.0.1:$port$url'),
          );
          final resp = await req.close();
          final r = Res(
            resp.statusCode,
            resp.headers,
            await utf8.decodeStream(resp),
          );
          expectError(r, LsErrorCode.notFound);
        }
      },
    );

    test('wrong HTTP method on a known path is 404 NOT_FOUND', () async {
      expectError(await call('DELETE', '/info'), LsErrorCode.notFound);
      expectError(
        await call('PUT', '/sessions/s1/finish'),
        LsErrorCode.notFound,
      );
      expectError(
        await call('GET', '/sessions/s1/cancel'),
        LsErrorCode.notFound,
      );
      expectError(await call('POST', '/info'), LsErrorCode.notFound);
    });

    test(
      'path identifiers are decoded and unsafe ones are rejected with 400',
      () async {
        expect((await call('GET', '/sessions/a%20b')).status, 200);
        expect(fake.lastSessionId, 'a b');
        for (final bad in [
          '%ff', // invalid UTF-8
          'a%2Fb', // encoded slash
          'a%5Cb', // encoded backslash
          '%00',
          '%0A',
          'x' * 129,
        ]) {
          expectError(
            await call('GET', '/sessions/$bad'),
            LsErrorCode.badRequest,
          );
          expectError(
            await call('GET', '/sessions/s1/files/$bad/state', headers: auth),
            LsErrorCode.badRequest,
          );
        }
        // Literal dot segments are normalised away by URL parsing, so they
        // never reach a handler (404 here, never a 200).
        for (final dots in ['..', '.', '%2e%2e', '%2E']) {
          fake.calls.clear();
          final r = await call('GET', '/sessions/$dots');
          expect(r.status, anyOf(400, 404), reason: r.text);
          expect(fake.calls, isEmpty);
        }
        expect((await call('GET', '/info')).status, 200);
      },
    );

    test(
      'unexpected exceptions become a generic 500 INTERNAL with no leaks',
      () async {
        fake.onGetSession = (_, _) async =>
            throw StateError('secret-token /home/alice/.ssh/id_rsa line 42');
        final r = await call('GET', '/sessions/s1');
        expectError(r, LsErrorCode.internal);
        expect(r.status, 500);
        for (final leak in [
          'secret-token',
          '/home',
          'alice',
          'StateError',
          'id_rsa',
          '#0',
          '.dart',
        ]) {
          expect(r.text, isNot(contains(leak)));
        }
        // Synchronous throws (deviceInfo getter) too.
        fake.onDeviceInfo = () =>
            throw const FileSystemException('disk gone', '/var/secret/path');
        final i = await call('GET', '/info');
        expectError(i, LsErrorCode.internal);
        expect(i.text, isNot(contains('/var/secret')));
        // Server survives.
        fake.onDeviceInfo = null;
        expect((await call('GET', '/info')).status, 200);
      },
    );

    test('responses are JSON and uncacheable', () async {
      final r = await call('GET', '/info');
      expect(r.headers.contentType?.mimeType, 'application/json');
      expect(r.headers.value('cache-control'), contains('no-store'));
    });

    test('server does not advertise its framework', () async {
      final r = await call('GET', '/info');
      expect(r.headers.value('x-powered-by'), isNull);
    });
  });

  group('rate limiting (POST /sessions only)', () {
    late DateTime now;

    setUp(() async {
      await server.stop(force: true);
      now = DateTime.utc(2026, 11, 3, 12);
      await startServer(
        enableRateLimit: true,
        rateLimiter: RateLimiter(clock: () => now),
      );
    });

    test(
      '10 per minute per IP, then 429 RATE_LIMITED with Retry-After',
      () async {
        for (var i = 0; i < 10; i++) {
          final r = await call(
            'POST',
            '/sessions',
            json: sampleRequest().toJson(),
          );
          expect(r.status, 202, reason: 'request ${i + 1}');
        }
        final limited = await call(
          'POST',
          '/sessions',
          json: sampleRequest().toJson(),
        );
        expectError(limited, LsErrorCode.rateLimited);
        expect(limited.status, 429);
        expect(limited.error['retryable'], isTrue);
        expect(
          int.parse(limited.headers.value('retry-after')!),
          greaterThan(0),
        );
        expect(fake.calls.where((c) => c == 'createSession').length, 10);
      },
    );

    test('limited requests are rejected before the body is parsed', () async {
      for (var i = 0; i < 10; i++) {
        await call('POST', '/sessions', json: sampleRequest().toJson());
      }
      expectError(
        await call('POST', '/sessions', bytes: utf8.encode('{garbage')),
        LsErrorCode.rateLimited,
      );
    });

    test('other routes are not limited', () async {
      for (var i = 0; i < 10; i++) {
        await call('POST', '/sessions', json: sampleRequest().toJson());
      }
      for (var i = 0; i < 30; i++) {
        expect((await call('GET', '/info')).status, 200);
      }
      expect((await call('GET', '/sessions/s1')).status, 200);
    });

    test('tokens refill with time', () async {
      for (var i = 0; i < 10; i++) {
        await call('POST', '/sessions', json: sampleRequest().toJson());
      }
      expect(
        (await call(
          'POST',
          '/sessions',
          json: sampleRequest().toJson(),
        )).status,
        429,
      );
      now = now.add(const Duration(seconds: 7));
      expect(
        (await call(
          'POST',
          '/sessions',
          json: sampleRequest().toJson(),
        )).status,
        202,
      );
      expect(
        (await call(
          'POST',
          '/sessions',
          json: sampleRequest().toJson(),
        )).status,
        429,
      );
    });
  });

  test('enableRateLimit: false never limits', () async {
    for (var i = 0; i < 25; i++) {
      expect(
        (await call(
          'POST',
          '/sessions',
          json: sampleRequest().toJson(),
        )).status,
        202,
      );
    }
  });
}
