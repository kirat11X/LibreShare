import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:json_schema/json_schema.dart';
import 'package:libreshare_core/libreshare_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String? _findUp(String relative) {
  var dir = Directory.current.absolute;
  while (true) {
    final candidate = p.join(dir.path, relative);
    if (FileSystemEntity.typeSync(candidate) != FileSystemEntityType.notFound) {
      return candidate;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
}

final String schemasDir =
    _findUp(p.join('docs', 'protocol', 'schemas')) ??
    (throw StateError(
      'docs/protocol/schemas not found above ${Directory.current}',
    ));

Map<String, Object?> _readJson(String path) =>
    (jsonDecode(File(path).readAsStringSync()) as Map).cast<String, Object?>();

final Map<String, Map<String, Object?>> _docs = {};
final Map<String, Map<String, Object?>> _byId = {};
final Map<String, JsonSchema> _schemas = {};

void _loadSchemas() {
  final files =
      Directory(schemasDir)
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.schema.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in files) {
    final doc = _readJson(f.path);
    final name = p.basename(f.path).replaceFirst('.schema.json', '');
    _docs[name] = doc;
    final id = doc[r'$id'];
    if (id is String) {
      _byId[id] = doc;
    }
  }

  final provider = RefProvider.sync(
    (String ref) => _byId[ref] ?? _byId[ref.split('#').first],
  );
  for (final e in _docs.entries) {
    _schemas[e.key] = JsonSchema.create(
      e.value,
      schemaVersion: SchemaVersion.draft2020_12,
      refProvider: provider,
    );
  }
}

void expectValid(String schema, Object? instance, [String? what]) {
  final s = _schemas[schema] ?? (throw ArgumentError('no schema $schema'));
  final r = s.validate(instance, validateFormats: true);
  expect(
    r.isValid,
    isTrue,
    reason:
        '${what ?? 'instance'} vs $schema: ${r.errors.join('; ')}\n'
        '${jsonEncode(instance)}',
  );
}

class CapturedExchange {
  CapturedExchange({
    required this.method,
    required this.uri,
    required this.requestHeaders,
    required this.requestBody,
    required this.status,
    required this.responseHeaders,
    required this.responseBody,
  });

  final String method;
  final Uri uri;
  final Map<String, String> requestHeaders;
  final List<int> requestBody;
  final int status;
  final Map<String, String> responseHeaders;
  final List<int> responseBody;

  Object? get requestJson =>
      requestBody.isEmpty ? null : jsonDecode(utf8.decode(requestBody));

  Object? get responseJson =>
      responseBody.isEmpty ? null : jsonDecode(utf8.decode(responseBody));
}

class InterceptingProxy {
  InterceptingProxy(this._targetPort);

  final int _targetPort;
  HttpServer? _server;
  final List<CapturedExchange> exchanges = [];
  final HttpClient _client = HttpClient();

  int get port => _server?.port ?? 0;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handle);
  }

  Future<void> _handle(HttpRequest request) async {
    final reqBody = <int>[];
    await for (final chunk in request.asBroadcastStream()) {
      reqBody.addAll(chunk);
    }

    final reqHeaders = <String, String>{};
    request.headers.forEach((name, values) {
      reqHeaders[name.toLowerCase()] = values.join(', ');
    });

    // Forward to target ApiServer
    final targetUri = request.uri.replace(
      scheme: 'http',
      host: '127.0.0.1',
      port: _targetPort,
    );

    final fwdReq = await _client.openUrl(request.method, targetUri);
    request.headers.forEach((name, values) {
      if (name.toLowerCase() != 'host') {
        for (final v in values) {
          fwdReq.headers.add(name, v);
        }
      }
    });

    if (reqBody.isNotEmpty) {
      fwdReq.add(reqBody);
    }
    final fwdRes = await fwdReq.close();

    final resBody = <int>[];
    await for (final chunk in fwdRes) {
      resBody.addAll(chunk);
    }

    final resHeaders = <String, String>{};
    fwdRes.headers.forEach((name, values) {
      resHeaders[name.toLowerCase()] = values.join(', ');
    });

    // Record exchange
    exchanges.add(
      CapturedExchange(
        method: request.method,
        uri: request.uri,
        requestHeaders: reqHeaders,
        requestBody: reqBody,
        status: fwdRes.statusCode,
        responseHeaders: resHeaders,
        responseBody: resBody,
      ),
    );

    // Forward response back to caller
    request.response.statusCode = fwdRes.statusCode;
    fwdRes.headers.forEach((name, values) {
      for (final v in values) {
        request.response.headers.add(name, v);
      }
    });
    if (resBody.isNotEmpty) {
      request.response.add(resBody);
    }
    await request.response.close();
  }

  Future<void> close() async {
    _client.close(force: true);
    await _server?.close(force: true);
  }
}

void main() {
  setUpAll(() {
    _loadSchemas();
  });

  group('Card T8: Live Wire Protocol Schema Conformance', () {
    late Directory tempDownloadDir;
    late LibreShareEngine receiverEngine;
    late InterceptingProxy proxy;
    late HttpClient client;

    setUp(() async {
      tempDownloadDir = await Directory.systemTemp.createTemp('t8_schema_dl_');

      // Receiver engine with auto-accept
      receiverEngine = LibreShareEngine(
        self: DeviceInfo(
          deviceId: 't8-receiver-id',
          alias: 'T8 Receiver',
          platform: 'linux',
        ),
        downloadDir: tempDownloadDir,
        preferredPort: 0,
        discovery: DiscoveryConfig.disabled,
        autoAccept: true,
      );
      await receiverEngine.start();
      final targetPort = receiverEngine.port;

      // Start intercepting proxy
      proxy = InterceptingProxy(targetPort);
      await proxy.start();

      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await proxy.close();
      await receiverEngine.dispose(force: true);
      if (await tempDownloadDir.exists()) {
        await tempDownloadDir.delete(recursive: true);
      }
    });

    Future<(int, dynamic)> httpJson(
      String method,
      String path, {
      Object? body,
      Map<String, String> headers = const {},
    }) async {
      final uri = Uri.parse('http://127.0.0.1:${proxy.port}$path');
      final req = await client.openUrl(method, uri);
      headers.forEach(req.headers.set);

      if (body != null) {
        final encoded = utf8.encode(jsonEncode(body));
        req.headers.set('content-type', 'application/json');
        req.headers.set('content-length', encoded.length.toString());
        req.add(encoded);
      }
      final res = await req.close();
      final text = await utf8.decodeStream(res);
      final json = text.isEmpty ? null : jsonDecode(text);
      return (res.statusCode, json);
    }

    test('full loopback transfer captures live traffic matching protocol schemas', () async {
      final testData = utf8.encode(
        'Live schema conformance test payload bytes 123456',
      );
      final testSha = sha256.convert(testData).toString();

      // 1. GET /api/v1/info
      final (infoStatus, infoBody) = await httpJson('GET', '$kApiPrefix/info');
      expect(infoStatus, equals(200));

      // 2. POST /api/v1/register
      final (regStatus, regBody) = await httpJson(
        'POST',
        '$kApiPrefix/register',
        body: {
          'deviceId': 't8-test-sender',
          'alias': 'T8 Sender',
          'platform': 'linux',
          'port': 0,
        },
      );
      expect(regStatus, equals(200));

      // 3. POST /api/v1/sessions
      final sessionReq = {
        'sender': {
          'deviceId': 't8-test-sender',
          'alias': 'T8 Sender',
          'platform': 'linux',
          'port': 0,
        },
        'files': [
          {
            'fileId': 'file-t8-1',
            'fileName': 'test_data.bin',
            'size': testData.length,
            'chunkCount': 1,
            'sha256': testSha,
            'modified': DateTime.utc(2026, 11, 7, 12, 0, 0).toIso8601String(),
          },
        ],
        'totalSize': testData.length,
      };

      final (sessStatus, sessBody) = await httpJson(
        'POST',
        '$kApiPrefix/sessions',
        body: sessionReq,
      );
      expect(sessStatus, equals(200));
      final sessionId = sessBody['sessionId'] as String;
      final fileToken =
          (sessBody['acceptedFiles'] as Map)['file-t8-1']['token'] as String;

      // 4. GET /api/v1/sessions/:id?wait=0
      final (pollStatus, pollBody) = await httpJson(
        'GET',
        '$kApiPrefix/sessions/$sessionId?wait=0',
      );
      expect(pollStatus, equals(200));

      // 5. GET /api/v1/sessions/:id/files/:fileId/state
      final (stateStatus, stateBody) = await httpJson(
        'GET',
        '$kApiPrefix/sessions/$sessionId/files/file-t8-1/state',
        headers: {'authorization': 'Bearer $fileToken'},
      );
      expect(stateStatus, equals(200));

      // 6. PUT /api/v1/sessions/:id/files/:fileId/chunks/0
      final chunkUri = Uri.parse(
        'http://127.0.0.1:${proxy.port}$kApiPrefix/sessions/$sessionId/files/file-t8-1/chunks/0',
      );
      final chunkReq = await client.openUrl('PUT', chunkUri);
      chunkReq.headers.set('content-type', 'application/octet-stream');
      chunkReq.headers.set('content-length', testData.length.toString());
      chunkReq.headers.set('authorization', 'Bearer $fileToken');
      chunkReq.headers.set(kChunkHashHeader, testSha);
      chunkReq.add(testData);
      final chunkRes = await chunkReq.close();
      expect(chunkRes.statusCode, equals(200));

      // 7. POST /api/v1/sessions/:id/files/:fileId/complete
      final (compStatus, compBody) = await httpJson(
        'POST',
        '$kApiPrefix/sessions/$sessionId/files/file-t8-1/complete',
        headers: {'authorization': 'Bearer $fileToken'},
      );
      expect(compStatus, equals(200));

      // 8. Negative control: Bad POST /api/v1/sessions -> error envelope
      final (errStatus, errBody) = await httpJson(
        'POST',
        '$kApiPrefix/sessions',
        body: {'sender': 'invalid_sender_shape_should_be_object'},
      );
      expect(errStatus, greaterThanOrEqualTo(400));

      // --- VERIFICATION OF ALL CAPTURED LIVE TRAFFIC ---
      expect(proxy.exchanges, isNotEmpty);

      const documentedRoutes = [
        r'^/api/v1/info$',
        r'^/api/v1/register$',
        r'^/api/v1/sessions$',
        r'^/api/v1/sessions/[^/]+$',
        r'^/api/v1/sessions/[^/]+/files/[^/]+/state$',
        r'^/api/v1/sessions/[^/]+/files/[^/]+/chunks/\d+$',
        r'^/api/v1/sessions/[^/]+/files/[^/]+/complete$',
      ];

      for (final ex in proxy.exchanges) {
        // Assert route is documented
        final path = ex.uri.path;
        final matchesKnown = documentedRoutes.any(
          (pattern) => RegExp(pattern).hasMatch(path),
        );
        expect(
          matchesKnown,
          isTrue,
          reason: 'Undocumented route called: $path',
        );

        // Assert query parameters are documented
        for (final q in ex.uri.queryParameters.keys) {
          expect(
            q,
            anyOf('wait', 'token'),
            reason: 'Undocumented query parameter "$q" in $path',
          );
        }

        // Schema validation by route
        if (path == '$kApiPrefix/info') {
          expectValid('device-info', ex.responseJson, 'GET /info response');
        } else if (path == '$kApiPrefix/register') {
          expectValid('device-info', ex.requestJson, 'POST /register request');
          expectValid(
            'device-info',
            ex.responseJson,
            'POST /register response',
          );
        } else if (path == '$kApiPrefix/sessions' && ex.status == 200) {
          expectValid(
            'session-request',
            ex.requestJson,
            'POST /sessions request',
          );
          expectValid(
            'session-status',
            ex.responseJson,
            'POST /sessions response',
          );
        } else if (path.startsWith('$kApiPrefix/sessions/') &&
            path.endsWith('/state')) {
          expectValid('file-state', ex.responseJson, 'GET /state response');
        } else if (path.startsWith('$kApiPrefix/sessions/') &&
            !path.contains('/files/')) {
          expectValid(
            'session-status',
            ex.responseJson,
            'GET /sessions/{id} response',
          );
        } else if (ex.status >= 400) {
          expectValid(
            'error-envelope',
            ex.responseJson,
            'Error response for $path',
          );
        }

        // Header casing and constraints
        if (ex.responseHeaders.containsKey('content-type') &&
            ex.responseHeaders['content-type']!.contains('json')) {
          expect(
            ex.responseHeaders['content-type'],
            contains('application/json'),
          );
        }
        if (ex.requestHeaders.containsKey(kChunkHashHeader)) {
          expect(
            RegExp(r'^[0-9a-f]{64}$')
                .hasMatch(ex.requestHeaders[kChunkHashHeader]!),
            isTrue,
            reason: '$kChunkHashHeader must be lowercase 64-character hex',
          );
        }
      }
    });
  });
}
