import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:libreshare_core/libreshare_core.dart';
import 'package:uuid/uuid.dart';

import 'engine_provider.dart';
import 'settings_provider.dart';

/// State of the local Web Portal server.
class WebPortalState {
  const WebPortalState({
    this.isRunning = false,
    this.portalUri,
    this.lanIp,
    this.port = 53320,
    this.pin,
    this.sharedFiles = const [],
    this.receivedFiles = const [],
    this.errorMessage,
  });

  final bool isRunning;
  final Uri? portalUri;
  final String? lanIp;
  final int port;
  final String? pin;
  final List<WebSharedFile> sharedFiles;
  final List<WebUploadResult> receivedFiles;
  final String? errorMessage;

  WebPortalState copyWith({
    bool? isRunning,
    Uri? portalUri,
    String? lanIp,
    int? port,
    String? pin,
    bool clearPin = false,
    List<WebSharedFile>? sharedFiles,
    List<WebUploadResult>? receivedFiles,
    String? errorMessage,
    bool clearError = false,
  }) {
    return WebPortalState(
      isRunning: isRunning ?? this.isRunning,
      portalUri: portalUri ?? this.portalUri,
      lanIp: lanIp ?? this.lanIp,
      port: port ?? this.port,
      pin: clearPin ? null : (pin ?? this.pin),
      sharedFiles: sharedFiles ?? this.sharedFiles,
      receivedFiles: receivedFiles ?? this.receivedFiles,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

class _AppWebPortalStorageDelegate implements WebPortalStorageDelegate {
  _AppWebPortalStorageDelegate({
    required this.downloadDir,
    required this.onReceived,
  });

  final Directory downloadDir;
  final void Function(WebUploadResult result) onReceived;

  @override
  Directory get downloadDirectory => downloadDir;

  @override
  Future<void> onFileReceived(WebUploadResult result) async {
    onReceived(result);
  }
}

class WebPortalNotifier extends Notifier<WebPortalState> {
  WebPortalService? _service;

  @override
  WebPortalState build() {
    ref.onDispose(() {
      _service?.stop();
      _service = null;
    });
    return const WebPortalState();
  }

  Future<void> start({int? port, String? pin}) async {
    if (state.isRunning) return;

    try {
      final downloadDir = ref.read(downloadDirProvider);
      if (!downloadDir.existsSync()) {
        downloadDir.createSync(recursive: true);
      }

      final engine = ref.read(engineOrNullProvider);
      final deviceName = engine?.deviceInfo.alias ?? 'LibreShare Device';

      // Find best LAN IP
      String? bestIp = engine?.myPeerLink?.ip;
      if (bestIp == null) {
        final ifaces = await const SystemNetworkInterfaceProvider().list();
        bestIp = ifaces.where((i) => i.kind == 'wifi').firstOrNull?.address.address ??
            ifaces.where((i) => i.kind == 'ethernet').firstOrNull?.address.address ??
            ifaces.firstOrNull?.address.address;
      }

      final chosenPort = port ?? state.port;
      final effectivePin = pin ?? state.pin;
      final config = WebPortalConfig(
        deviceName: deviceName,
        pin: effectivePin,
      );

      final delegate = _AppWebPortalStorageDelegate(
        downloadDir: downloadDir,
        onReceived: (result) {
          state = state.copyWith(
            receivedFiles: [result, ...state.receivedFiles],
          );
        },
      );

      final service = WebPortalService(
        config: config,
        storageDelegate: delegate,
        getSharedFiles: () => state.sharedFiles,
        preferredPort: chosenPort,
      );

      final bindAddress = ref.read(engineTuningProvider).bindAddress;
      await service.start(bindAddress: bindAddress);
      _service = service;

      final portalUri = service.getPortalUri(host: bestIp) ?? service.portalUri;

      state = state.copyWith(
        isRunning: true,
        portalUri: portalUri,
        lanIp: bestIp,
        port: service.port,
        pin: effectivePin,
        clearError: true,
      );
    } catch (e) {
      state = state.copyWith(
        isRunning: false,
        errorMessage: 'Failed to start Web Portal: $e',
      );
    }
  }

  Future<void> stop() async {
    if (_service != null) {
      await _service!.stop();
      _service = null;
    }
    state = state.copyWith(
      isRunning: false,
      portalUri: null,
      clearError: true,
    );
  }

  void addFiles(List<File> files) {
    final updated = List<WebSharedFile>.from(state.sharedFiles);
    for (final file in files) {
      if (!file.existsSync()) continue;
      final segments = file.uri.pathSegments;
      final name = segments.isNotEmpty
          ? segments.lastWhere((s) => s.isNotEmpty, orElse: () => 'file')
          : 'file';
      updated.add(
        WebSharedFile(
          id: const Uuid().v4(),
          name: name,
          size: file.lengthSync(),
          mimeType: 'application/octet-stream',
          file: file,
        ),
      );
    }
    state = state.copyWith(sharedFiles: updated);
  }

  void removeFile(String id) {
    final updated = state.sharedFiles.where((f) => f.id != id).toList();
    state = state.copyWith(sharedFiles: updated);
  }

  void setPin(String? pin) {
    state = state.copyWith(pin: pin, clearPin: pin == null || pin.isEmpty);
  }
}

final webPortalProvider =
    NotifierProvider<WebPortalNotifier, WebPortalState>(
      WebPortalNotifier.new,
    );
