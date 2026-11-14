import 'dart:io';

/// Represents a file shared via the LibreShare web portal.
class WebSharedFile {
  /// Unique identifier for downloading this file.
  final String id;

  /// Display name of the file.
  final String name;

  /// Total size of the file in bytes.
  final int size;

  /// MIME type of the file.
  final String mimeType;

  /// Underlying local file system entity.
  final File file;

  WebSharedFile({
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

/// Metadata and status about the web portal and host device.
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

  factory WebPortalInfo.fromJson(Map<String, dynamic> json) => WebPortalInfo(
    deviceName: json['deviceName'] as String? ?? 'LibreShare Device',
    version: json['version'] as String? ?? '1.0.0',
    pinRequired: json['pinRequired'] as bool? ?? false,
    sharedFileCount: (json['sharedFileCount'] as num?)?.toInt() ?? 0,
    totalSharedBytes: (json['totalSharedBytes'] as num?)?.toInt() ?? 0,
  );
}

/// Result returned after uploading a file via the web portal.
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

  factory WebUploadResult.fromJson(Map<String, dynamic> json) =>
      WebUploadResult(
        originalName: json['originalName'] as String? ?? '',
        savedPath: json['savedPath'] as String? ?? '',
        bytesWritten: (json['bytesWritten'] as num?)?.toInt() ?? 0,
        success: json['success'] as bool? ?? false,
        error: json['error'] as String?,
      );
}
