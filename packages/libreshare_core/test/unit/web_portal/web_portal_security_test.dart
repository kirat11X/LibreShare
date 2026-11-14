import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:libreshare_core/src/web_portal/web_portal_models.dart';
import 'package:libreshare_core/src/web_portal/web_portal_handler.dart';

class _TestStorageDelegate implements WebPortalStorageDelegate {
  @override
  final Directory downloadDirectory;
  final List<WebUploadResult> receivedFiles = [];

  _TestStorageDelegate(this.downloadDirectory);

  @override
  Future<void> onFileReceived(WebUploadResult result) async {
    receivedFiles.add(result);
  }
}

void main() {
  group('Filename Sanitization', () {
    test('sanitizes ../../etc/passwd to passwd', () {
      expect(
        WebPortalHandler.sanitizeFilename('../../etc/passwd'),
        equals('passwd'),
      );
    });

    test(r'sanitizes ..\windows\system32\cmd.exe to cmd.exe', () {
      expect(
        WebPortalHandler.sanitizeFilename(r'..\windows\system32\cmd.exe'),
        equals('cmd.exe'),
      );
    });

    test('sanitizes foo/../../bar.txt to bar.txt', () {
      expect(
        WebPortalHandler.sanitizeFilename('foo/../../bar.txt'),
        equals('bar.txt'),
      );
    });

    test('strips null byte from null\\u0000byte.txt', () {
      final sanitized = WebPortalHandler.sanitizeFilename('null\u0000byte.txt');
      expect(sanitized.contains('\u0000'), isFalse);
      expect(sanitized, equals('nullbyte.txt'));
    });

    test('sanitizes empty string to unnamed', () {
      expect(WebPortalHandler.sanitizeFilename(''), equals('unnamed'));
    });
  });

  group('PIN Protection', () {
    late Directory tempDir;
    late _TestStorageDelegate storageDelegate;
    late File sampleFile;
    late WebSharedFile sharedFile;
    late WebPortalConfig config;
    late WebPortalHandler portalHandler;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('web_portal_sec_test_');
      storageDelegate = _TestStorageDelegate(tempDir);

      sampleFile = File('${tempDir.path}/secret.txt');
      sampleFile.writeAsStringSync('Top Secret Data');

      sharedFile = WebSharedFile(
        id: 'sec-file-1',
        name: 'secret.txt',
        size: sampleFile.lengthSync(),
        mimeType: 'text/plain',
        file: sampleFile,
      );

      config = const WebPortalConfig(
        deviceName: 'PIN Protected Device',
        version: '1.0.0',
        pin: '1234',
      );

      portalHandler = WebPortalHandler(
        config: config,
        storageDelegate: storageDelegate,
        getSharedFiles: () => [sharedFile],
      );
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('GET /web/api/files without auth returns 401', () async {
      final request = Request(
        'GET',
        Uri.parse('http://127.0.0.1/web/api/files'),
      );
      final response = await portalHandler.handler(request);
      expect(response.statusCode, equals(401));
    });

    test('GET /web/download/<id> without auth returns 401', () async {
      final request = Request(
        'GET',
        Uri.parse('http://127.0.0.1/web/download/sec-file-1'),
      );
      final response = await portalHandler.handler(request);
      expect(response.statusCode, equals(401));
    });

    test('POST /web/api/upload without auth returns 401', () async {
      final request = Request(
        'POST',
        Uri.parse('http://127.0.0.1/web/api/upload'),
        headers: {'x-filename': 'test.txt'},
        body: 'sample data',
      );
      final response = await portalHandler.handler(request);
      expect(response.statusCode, equals(401));
    });

    test('POST /web/api/auth with {"pin": "wrong"} returns 401', () async {
      final request = Request(
        'POST',
        Uri.parse('http://127.0.0.1/web/api/auth'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'pin': 'wrong'}),
      );
      final response = await portalHandler.handler(request);
      expect(response.statusCode, equals(401));
    });

    test('POST /web/api/auth with {"pin": "1234"} returns 200 with auth token {"token": "..."}', () async {
      final request = Request(
        'POST',
        Uri.parse('http://127.0.0.1/web/api/auth'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'pin': '1234'}),
      );
      final response = await portalHandler.handler(request);
      expect(response.statusCode, equals(200));

      final json =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(json.containsKey('token'), isTrue);
      expect(json['token'], isA<String>());
      expect((json['token'] as String).isNotEmpty, isTrue);
    });

    test("Requests with 'Authorization': 'Bearer <token>' succeed", () async {
      final authRequest = Request(
        'POST',
        Uri.parse('http://127.0.0.1/web/api/auth'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'pin': '1234'}),
      );
      final authResponse = await portalHandler.handler(authRequest);
      expect(authResponse.statusCode, equals(200));
      final authJson =
          jsonDecode(await authResponse.readAsString()) as Map<String, dynamic>;
      final token = authJson['token'] as String;

      final filesRequest = Request(
        'GET',
        Uri.parse('http://127.0.0.1/web/api/files'),
        headers: {'authorization': 'Bearer $token'},
      );
      final filesResponse = await portalHandler.handler(filesRequest);
      expect(filesResponse.statusCode, equals(200));

      final downloadRequest = Request(
        'GET',
        Uri.parse('http://127.0.0.1/web/download/sec-file-1'),
        headers: {'authorization': 'Bearer $token'},
      );
      final downloadResponse = await portalHandler.handler(downloadRequest);
      expect(downloadResponse.statusCode, equals(200));
    });
  });

  group('Rate Limiting on Failed Auth', () {
    late Directory tempDir;
    late _TestStorageDelegate storageDelegate;
    late WebPortalConfig config;
    late WebPortalHandler portalHandler;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync(
        'web_portal_rate_limit_test_',
      );
      storageDelegate = _TestStorageDelegate(tempDir);

      config = const WebPortalConfig(
        deviceName: 'Rate Limited Device',
        pin: '1234',
      );

      portalHandler = WebPortalHandler(
        config: config,
        storageDelegate: storageDelegate,
        getSharedFiles: () => [],
      );
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('Repeated failed auth requests (e.g. 6 in a row) return 429 Too Many Requests', () async {
      for (int i = 0; i < 5; i++) {
        final request = Request(
          'POST',
          Uri.parse('http://127.0.0.1/web/api/auth'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({'pin': 'wrong'}),
        );
        final response = await portalHandler.handler(request);
        expect(
          response.statusCode,
          equals(401),
          reason: 'Attempt ${i + 1} should return 401',
        );
      }

      // 6th consecutive failed attempt must return 429
      final request6 = Request(
        'POST',
        Uri.parse('http://127.0.0.1/web/api/auth'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'pin': 'wrong'}),
      );
      final response6 = await portalHandler.handler(request6);
      expect(response6.statusCode, equals(429));
    });
  });
}
