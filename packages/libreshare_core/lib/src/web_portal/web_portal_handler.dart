import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

import '../transfer/filename_sanitizer.dart';
import 'web_portal_assets.dart';
import 'web_portal_models.dart';

/// Interface for handling file storage from web uploads.
abstract class WebPortalStorageDelegate {
  Directory get downloadDirectory;
  Future<void> onFileReceived(WebUploadResult result);
}

/// Configuration settings for the Web Portal.
class WebPortalConfig {
  final String deviceName;
  final String version;
  final String? pin;
  final int maxUploadSizeBytes;
  final int maxConcurrentUploads;

  const WebPortalConfig({
    this.deviceName = 'LibreShare Device',
    this.version = '1.0.0',
    this.pin,
    this.maxUploadSizeBytes = 10 * 1024 * 1024 * 1024,
    this.maxConcurrentUploads = 4,
  });

  bool get pinRequired => pin != null && pin!.isNotEmpty;
}

/// Shelf handler for the LibreShare Web Portal.
class WebPortalHandler {
  final WebPortalConfig config;
  final WebPortalStorageDelegate storageDelegate;
  final List<WebSharedFile> Function() getSharedFiles;

  final Set<String> _validTokens = <String>{};
  int _failedAuthAttempts = 0;
  static const int _maxFailedAttemptsBeforeRateLimit = 5;

  late final Router _router;

  WebPortalHandler({
    required this.config,
    required this.storageDelegate,
    required this.getSharedFiles,
  }) {
    _router = Router()
      ..get('/web', _handleIndex)
      ..get('/web/', _handleIndex)
      ..get('/web/api/info', _handleInfo)
      ..get('/web/api/files', _handleFiles)
      ..post('/web/api/auth', _handleAuth)
      ..get('/web/download/<fileId>', _handleDownload)
      ..post('/web/api/upload', _handleUpload);
  }

  Handler get handler => _router.call;

  /// Sanitizes an input filename to avoid directory traversal.
  static String sanitizeFilename(String rawFilename) {
    if (rawFilename.trim().isEmpty) return 'unnamed';
    return sanitizeFileName(rawFilename);
  }

  Response _handleIndex(Request request) {
    return Response.ok(
      WebPortalAssets.indexHtml,
      headers: {
        'content-type': 'text/html; charset=utf-8',
        'cache-control': 'no-store',
      },
    );
  }

  Response _handleInfo(Request request) {
    final files = getSharedFiles();
    final totalBytes = files.fold<int>(0, (sum, f) => sum + f.size);

    final info = WebPortalInfo(
      deviceName: config.deviceName,
      version: config.version,
      pinRequired: config.pinRequired,
      sharedFileCount: files.length,
      totalSharedBytes: totalBytes,
    );

    return Response.ok(
      jsonEncode(info.toJson()),
      headers: {
        'content-type': 'application/json',
        'cache-control': 'no-store',
      },
    );
  }

  Future<Response> _handleAuth(Request request) async {
    if (_failedAuthAttempts >= _maxFailedAttemptsBeforeRateLimit) {
      return Response(
        429,
        body: jsonEncode({
          'error': 'Too many failed attempts. Try again later.',
        }),
        headers: {'content-type': 'application/json', 'retry-after': '60'},
      );
    }

    try {
      final bodyStr = await request.readAsString();
      final body = jsonDecode(bodyStr) as Map<String, dynamic>;
      final enteredPin = body['pin']?.toString();

      if (enteredPin != null && enteredPin == config.pin) {
        _failedAuthAttempts = 0;
        final token = const Uuid().v4();
        _validTokens.add(token);

        return Response.ok(
          jsonEncode({'token': token}),
          headers: {'content-type': 'application/json'},
        );
      } else {
        _failedAuthAttempts++;
        return Response(
          401,
          body: jsonEncode({'error': 'Invalid PIN'}),
          headers: {'content-type': 'application/json'},
        );
      }
    } catch (_) {
      _failedAuthAttempts++;
      return Response(
        401,
        body: jsonEncode({'error': 'Invalid authentication request'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  bool _isAuthorized(Request request) {
    if (!config.pinRequired) return true;

    final authHeader = request.headers['authorization'];
    if (authHeader != null && authHeader.startsWith('Bearer ')) {
      final token = authHeader.substring(7).trim();
      return _validTokens.contains(token);
    }

    return false;
  }

  Response _handleFiles(Request request) {
    if (!_isAuthorized(request)) {
      return Response(
        401,
        body: jsonEncode({'error': 'Authentication required'}),
        headers: {'content-type': 'application/json'},
      );
    }

    final files = getSharedFiles();
    final jsonList = files.map((f) => f.toJson()).toList();

    return Response.ok(
      jsonEncode(jsonList),
      headers: {
        'content-type': 'application/json',
        'cache-control': 'no-store',
      },
    );
  }

  Future<Response> _handleDownload(Request request, String fileId) async {
    if (!_isAuthorized(request)) {
      return Response(
        401,
        body: jsonEncode({'error': 'Authentication required'}),
        headers: {'content-type': 'application/json'},
      );
    }

    final files = getSharedFiles();
    final match = files.where((f) => f.id == fileId).toList();
    if (match.isEmpty) {
      return Response.notFound('File not found');
    }

    final shared = match.first;
    final file = shared.file;
    if (!file.existsSync()) {
      return Response.notFound('File missing from disk');
    }

    final fileSize = file.lengthSync();
    final rangeHeader = request.headers['range'];

    if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
      final rangeSpec = rangeHeader.substring(6).trim();
      final parts = rangeSpec.split('-');
      if (parts.length == 2) {
        final start = int.tryParse(parts[0]);
        var end = int.tryParse(parts[1]);

        if (start != null) {
          end ??= fileSize - 1;
          if (end >= fileSize) end = fileSize - 1;
          if (start <= end && start < fileSize) {
            final length = end - start + 1;
            return Response(
              206,
              body: file.openRead(start, end + 1),
              headers: {
                'content-type': shared.mimeType,
                'accept-ranges': 'bytes',
                'content-range': 'bytes $start-$end/$fileSize',
                'content-length': length.toString(),
                'content-disposition': 'attachment; filename="${shared.name}"',
              },
            );
          }
        }
      }
    }

    return Response.ok(
      file.openRead(),
      headers: {
        'content-type': shared.mimeType,
        'accept-ranges': 'bytes',
        'content-length': fileSize.toString(),
        'content-disposition': 'attachment; filename="${shared.name}"',
      },
    );
  }

  Future<Response> _handleUpload(Request request) async {
    if (!_isAuthorized(request)) {
      return Response(
        401,
        body: jsonEncode({'error': 'Authentication required'}),
        headers: {'content-type': 'application/json'},
      );
    }

    final rawName = request.headers['x-filename'] ?? 'upload.txt';
    final sanitizedName = sanitizeFilename(rawName);

    final destDir = storageDelegate.downloadDirectory;
    if (!destDir.existsSync()) {
      destDir.createSync(recursive: true);
    }

    // Resolve name collision
    File targetFile = File(p.join(destDir.path, sanitizedName));
    if (targetFile.existsSync()) {
      final dot = sanitizedName.lastIndexOf('.');
      final stem = dot > 0 ? sanitizedName.substring(0, dot) : sanitizedName;
      final ext = dot > 0 ? sanitizedName.substring(dot) : '';
      var counter = 1;
      while (targetFile.existsSync()) {
        targetFile = File(p.join(destDir.path, '$stem ($counter)$ext'));
        counter++;
      }
    }

    try {
      final sink = targetFile.openWrite();
      await sink.addStream(request.read());
      await sink.flush();
      await sink.close();

      final bytesWritten = targetFile.lengthSync();
      final result = WebUploadResult(
        originalName: rawName,
        savedPath: targetFile.path,
        bytesWritten: bytesWritten,
        success: true,
      );

      await storageDelegate.onFileReceived(result);

      return Response.ok(
        jsonEncode(result.toJson()),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'success': false, 'error': e.toString()}),
        headers: {'content-type': 'application/json'},
      );
    }
  }
}
