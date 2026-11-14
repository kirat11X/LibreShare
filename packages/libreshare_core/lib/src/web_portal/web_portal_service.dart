import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf_io.dart' as shelf_io;

import 'web_portal_handler.dart';
import 'web_portal_models.dart';

/// Hosts the HTTP service serving the LibreShare Web Portal.
class WebPortalService {
  final WebPortalConfig config;
  final WebPortalStorageDelegate storageDelegate;
  final List<WebSharedFile> Function() getSharedFiles;
  final int preferredPort;

  HttpServer? _server;
  late final WebPortalHandler handler;

  WebPortalService({
    required this.config,
    required this.storageDelegate,
    required this.getSharedFiles,
    this.preferredPort = 53320,
  }) {
    handler = WebPortalHandler(
      config: config,
      storageDelegate: storageDelegate,
      getSharedFiles: getSharedFiles,
    );
  }

  bool get isRunning => _server != null;

  int get port => _server?.port ?? 0;

  Uri? get portalUri => getPortalUri();

  /// Returns the Web Portal URI, optionally substituting a specific host/IP
  /// (such as the LAN Wi-Fi IP) when bound to `0.0.0.0`.
  Uri? getPortalUri({String? host}) {
    if (!isRunning) return null;
    var address = host ?? _server!.address.address;
    if (address == '0.0.0.0' || address == '::') {
      address = '127.0.0.1';
    }
    return Uri.parse('http://$address:$port/web');
  }

  /// Starts the HTTP server and attaches the Web Portal handler.
  Future<void> start({InternetAddress? bindAddress}) async {
    if (isRunning) return;

    final targetAddress = bindAddress ?? InternetAddress.anyIPv4;
    try {
      _server = await HttpServer.bind(targetAddress, preferredPort);
    } catch (_) {
      _server = await HttpServer.bind(targetAddress, 0);
    }
    shelf_io.serveRequests(_server!, handler.handler);
  }

  /// Gracefully closes the HTTP server.
  Future<void> stop() async {
    if (_server != null) {
      await _server!.close(force: true);
      _server = null;
    }
  }
}
