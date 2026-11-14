import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:libreshare_core/src/web_portal/web_portal_models.dart';
import 'package:libreshare_core/src/web_portal/web_portal_handler.dart';
import 'package:libreshare_core/src/web_portal/web_portal_service.dart';
import 'package:libreshare_core/src/web_portal/web_portal_assets.dart';

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
  late Directory tempDir;
  late _TestStorageDelegate storageDelegate;
  late File sampleFile;
  late WebSharedFile sharedFile;
  late WebPortalConfig config;
  late WebPortalHandler portalHandler;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('web_portal_test_');
    storageDelegate = _TestStorageDelegate(tempDir);

    sampleFile = File('${tempDir.path}/hello.txt');
    sampleFile.writeAsStringSync('Hello, LibreShare Web Portal!');

    sharedFile = WebSharedFile(
      id: 'file-123',
      name: 'hello.txt',
      size: sampleFile.lengthSync(),
      mimeType: 'text/plain',
      file: sampleFile,
    );

    config = const WebPortalConfig(deviceName: 'Test Device', version: '1.0.0');

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

  group('SPA Assets', () {
    test(
      'GET /web returns 200, Content-Type text/html, and HTML body',
      () async {
        final request = Request('GET', Uri.parse('http://127.0.0.1/web'));
        final response = await portalHandler.handler(request);

        expect(response.statusCode, equals(200));
        expect(response.headers['content-type'], contains('text/html'));
        final body = await response.readAsString();
        expect(body, contains('<!DOCTYPE html>'));
        expect(body, contains(WebPortalAssets.indexHtml));
      },
    );

    test(
      'GET /web/ returns 200, Content-Type text/html, and HTML body',
      () async {
        final request = Request('GET', Uri.parse('http://127.0.0.1/web/'));
        final response = await portalHandler.handler(request);

        expect(response.statusCode, equals(200));
        expect(response.headers['content-type'], contains('text/html'));
        final body = await response.readAsString();
        expect(body, contains('<!DOCTYPE html>'));
      },
    );

    test(
      'GET /web/manifest.json returns 200, application/manifest+json, and valid PWA manifest',
      () async {
        final request = Request(
          'GET',
          Uri.parse('http://127.0.0.1/web/manifest.json'),
        );
        final response = await portalHandler.handler(request);

        expect(response.statusCode, equals(200));
        expect(
          response.headers['content-type'],
          contains('application/manifest+json'),
        );
        final body = await response.readAsString();
        final manifest = jsonDecode(body) as Map<String, dynamic>;
        expect(manifest['name'], equals('LibreShare Web Portal'));
        expect(manifest['display'], equals('standalone'));
        expect(manifest['start_url'], equals('/web/'));
      },
    );
  });

  group('API Info & Files', () {
    test(
      'GET /web/api/info returns 200 with JSON matching WebPortalInfo',
      () async {
        final request = Request(
          'GET',
          Uri.parse('http://127.0.0.1/web/api/info'),
        );
        final response = await portalHandler.handler(request);

        expect(response.statusCode, equals(200));
        expect(response.headers['content-type'], contains('application/json'));
        final json =
            jsonDecode(await response.readAsString()) as Map<String, dynamic>;
        expect(json['deviceName'], equals('Test Device'));
        expect(json['version'], equals('1.0.0'));
        expect(json['pinRequired'], isFalse);
        expect(json['sharedFileCount'], equals(1));
        expect(json['totalSharedBytes'], equals(sampleFile.lengthSync()));
      },
    );

    test(
      'GET /web/api/files returns 200 with JSON list of WebSharedFile',
      () async {
        final request = Request(
          'GET',
          Uri.parse('http://127.0.0.1/web/api/files'),
        );
        final response = await portalHandler.handler(request);

        expect(response.statusCode, equals(200));
        expect(response.headers['content-type'], contains('application/json'));
        final list = jsonDecode(await response.readAsString()) as List;
        expect(list.length, equals(1));
        final fileMap = list[0] as Map<String, dynamic>;
        expect(fileMap['id'], equals('file-123'));
        expect(fileMap['name'], equals('hello.txt'));
        expect(fileMap['size'], equals(sampleFile.lengthSync()));
        expect(fileMap['mimeType'], equals('text/plain'));
      },
    );
  });

  group('Downloads & Streaming', () {
    test('GET /web/download/<validId> returns 200, Content-Disposition attachment, Content-Length, streaming exact bytes', () async {
      final request = Request(
        'GET',
        Uri.parse('http://127.0.0.1/web/download/file-123'),
      );
      final response = await portalHandler.handler(request);

      expect(response.statusCode, equals(200));
      expect(response.headers['content-disposition'], contains('attachment'));
      expect(response.headers['content-disposition'], contains('hello.txt'));
      expect(
        response.headers['content-length'],
        equals(sampleFile.lengthSync().toString()),
      );

      final bodyBytes = await response.read().expand((chunk) => chunk).toList();
      expect(bodyBytes, equals(sampleFile.readAsBytesSync()));
    });

    test('GET /web/download/<invalidId> returns 404', () async {
      final request = Request(
        'GET',
        Uri.parse('http://127.0.0.1/web/download/invalid-file-id'),
      );
      final response = await portalHandler.handler(request);

      expect(response.statusCode, equals(404));
    });

    test("Range requests: GET /web/download/<validId> with 'Range': 'bytes=0-4' returns 206 Partial Content and 5 bytes", () async {
      final request = Request(
        'GET',
        Uri.parse('http://127.0.0.1/web/download/file-123'),
        headers: {'range': 'bytes=0-4'},
      );
      final response = await portalHandler.handler(request);

      expect(response.statusCode, equals(206));
      expect(response.headers['content-range'], contains('bytes 0-4/'));
      final bodyBytes = await response.read().expand((chunk) => chunk).toList();
      expect(bodyBytes.length, equals(5));
      final fullBytes = sampleFile.readAsBytesSync();
      expect(bodyBytes, equals(fullBytes.sublist(0, 5)));
    });

    test("Range requests: GET /web/download/<validId> with 'Range': 'bytes=5-' returns 206 and remaining bytes", () async {
      final request = Request(
        'GET',
        Uri.parse('http://127.0.0.1/web/download/file-123'),
        headers: {'range': 'bytes=5-'},
      );
      final response = await portalHandler.handler(request);

      expect(response.statusCode, equals(206));
      final bodyBytes = await response.read().expand((chunk) => chunk).toList();
      final fullBytes = sampleFile.readAsBytesSync();
      expect(bodyBytes.length, equals(fullBytes.length - 5));
      expect(bodyBytes, equals(fullBytes.sublist(5)));
    });
  });

  group('Uploads', () {
    test("POST /web/api/upload with file content and header 'X-Filename': 'upload.txt' writes to downloadDirectory, calls onFileReceived, and returns 200 JSON WebUploadResult(success: true)", () async {
      final content = utf8.encode('Uploaded content data');
      final request = Request(
        'POST',
        Uri.parse('http://127.0.0.1/web/api/upload'),
        headers: {
          'x-filename': 'upload.txt',
          'content-length': content.length.toString(),
        },
        body: content,
      );

      final response = await portalHandler.handler(request);

      expect(response.statusCode, equals(200));
      final json =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(json['success'], isTrue);
      expect(json['originalName'], equals('upload.txt'));
      expect(json['bytesWritten'], equals(content.length));

      final savedPath = json['savedPath'] as String;
      final savedFile = File(savedPath);
      expect(savedFile.existsSync(), isTrue);
      expect(savedFile.readAsBytesSync(), equals(content));
      expect(storageDelegate.receivedFiles.length, equals(1));
      expect(
        storageDelegate.receivedFiles.first.savedPath,
        equals(savedFile.path),
      );
      expect(
        storageDelegate.receivedFiles.first.originalName,
        equals('upload.txt'),
      );
      expect(
        storageDelegate.receivedFiles.first.bytesWritten,
        equals(content.length),
      );
    });

    test("Collision resolution: uploading 'upload.txt' when 'upload.txt' already exists saves as 'upload (1).txt'", () async {
      final existingFile = File('${tempDir.path}/upload.txt');
      existingFile.writeAsStringSync('Existing original content');

      final newContent = utf8.encode('New second content');
      final request = Request(
        'POST',
        Uri.parse('http://127.0.0.1/web/api/upload'),
        headers: {
          'x-filename': 'upload.txt',
          'content-length': newContent.length.toString(),
        },
        body: newContent,
      );

      final response = await portalHandler.handler(request);

      expect(response.statusCode, equals(200));
      final json =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(json['success'], isTrue);
      expect(json['originalName'], equals('upload.txt'));
      final savedPath = json['savedPath'] as String;
      expect(savedPath, endsWith('upload (1).txt'));

      final savedFile = File(savedPath);
      expect(savedFile.existsSync(), isTrue);
      expect(savedFile.readAsBytesSync(), equals(newContent));
      // Existing file unchanged
      expect(
        existingFile.readAsStringSync(),
        equals('Existing original content'),
      );
    });
  });

  group('WebPortalService Lifecycle', () {
    test('Service start() binds ephemeral port, portalUri returns http://127.0.0.1:<port>/web, stop() closes server', () async {
      final service = WebPortalService(
        config: config,
        storageDelegate: storageDelegate,
        getSharedFiles: () => [sharedFile],
        preferredPort: 0,
      );

      expect(service.isRunning, isFalse);
      expect(service.portalUri, isNull);

      await service.start(bindAddress: InternetAddress.loopbackIPv4);

      expect(service.isRunning, isTrue);
      expect(service.port, greaterThan(0));
      expect(service.portalUri, isNotNull);
      expect(
        service.portalUri.toString(),
        equals('http://127.0.0.1:${service.port}/web'),
      );

      await service.stop();

      expect(service.isRunning, isFalse);
    });
  });
}
