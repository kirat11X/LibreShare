# Increment Web Portal Seams & Contracts (Orchestrator-Owned)

Source: `docs/plans/inc-web-portal.md`.
Directory: `packages/libreshare_core/lib/src/web_portal/`.

All interfaces and public signatures defined here are the contract. Subagents must not change public signatures or alter tests.

---

## 1. `packages/libreshare_core/lib/src/web_portal/web_portal_models.dart`

```dart
import 'dart:io';

/// Information about a file offered by the native device for web download.
class WebSharedFile {
  final String id;
  final String name;
  final int size;
  final String mimeType;
  final File file;

  const WebSharedFile({
    required this.id,
    required this.name,
    required this.size,
    required this.mimeType,
    required this.file,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'size': size,
    'mimeType': mimeType,
  };
}

/// Status of the Web Portal service.
class WebPortalInfo {
  final String deviceName;
  final String version;
  final bool pinRequired;
  final int sharedFileCount;
  final int totalSharedBytes;

  const WebPortalInfo({
    required this.deviceName,
    required this.version,
    required this.pinRequired,
    required this.sharedFileCount,
    required this.totalSharedBytes,
  });

  Map<String, dynamic> toJson() => {
    'deviceName': deviceName,
    'version': version,
    'pinRequired': pinRequired,
    'sharedFileCount': sharedFileCount,
    'totalSharedBytes': totalSharedBytes,
  };
}

/// Result of a file upload from the browser.
class WebUploadResult {
  final String originalName;
  final String savedPath;
  final int bytesWritten;
  final bool success;
  final String? error;

  const WebUploadResult({
    required this.originalName,
    required this.savedPath,
    required this.bytesWritten,
    required this.success,
    this.error,
  });

  Map<String, dynamic> toJson() => {
    'originalName': originalName,
    'savedPath': savedPath,
    'bytesWritten': bytesWritten,
    'success': success,
    if (error != null) 'error': error,
  };
}
```

---

## 2. `packages/libreshare_core/lib/src/web_portal/web_portal_handler.dart`

```dart
import 'dart:async';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'web_portal_models.dart';

abstract class WebPortalStorageDelegate {
  Directory get downloadDirectory;
  Future<void> onFileReceived(WebUploadResult result);
}

class WebPortalConfig {
  final String deviceName;
  final String version;
  final String? pin; // null = no PIN required
  final int maxUploadSizeBytes; // e.g. 10 GB
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

/// Shelf handler for the Web Portal.
class WebPortalHandler {
  final WebPortalConfig config;
  final WebPortalStorageDelegate storageDelegate;
  final List<WebSharedFile> Function() getSharedFiles;

  WebPortalHandler({
    required this.config,
    required this.storageDelegate,
    required this.getSharedFiles,
  });

  /// Shelf Handler dispatching all `/web` requests.
  Handler get handler;

  /// Helper to sanitize uploaded filename to prevent directory traversal.
  static String sanitizeFilename(String rawFilename);
}
```

---

## 3. `packages/libreshare_core/lib/src/web_portal/web_portal_service.dart`

```dart
import 'dart:async';
import 'dart:io';
import 'web_portal_handler.dart';
import 'web_portal_models.dart';

class WebPortalService {
  final WebPortalConfig config;
  final WebPortalStorageDelegate storageDelegate;
  final List<WebSharedFile> Function() getSharedFiles;
  final int preferredPort;

  HttpServer? _server;

  WebPortalService({
    required this.config,
    required this.storageDelegate,
    required this.getSharedFiles,
    this.preferredPort = 53320,
  });

  bool get isRunning => _server != null;
  int get port => _server?.port ?? 0;
  Uri? get portalUri;

  Future<void> start({InternetAddress? bindAddress});
  Future<void> stop();
}
```

---

## 4. `packages/libreshare_core/lib/src/web_portal/web_portal_assets.dart`

```dart
/// Embedded HTML5/CSS/JS Single-Page Web App for browser users.
/// Self-contained, responsive, clean Material-inspired UI.
class WebPortalAssets {
  static const String indexHtml = '''<!DOCTYPE html>
<html lang="en">
...
</html>''';
}
```
