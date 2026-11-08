import 'dart:io';

import 'origin_pull_connection.dart';

class TunnelConnection extends OriginPullConnection {
  TunnelConnection({
    required super.candidate,
    required super.originBase,
    required super.token,
    required super.keys,
    required super.claim,
  });

  @override
  HttpClient createHttpClient() {
    // Tunnel endpoints (e.g. *.trycloudflare.com) present public-CA certificates;
    // uses standard system root CA validation.
    return HttpClient();
  }
}
