// A loopback "peer" for the P6b probe tests: a real TLS 1.3 listener built with
// the P1 identity certificate (or a plaintext listener), answering GET /info
// and POST /register with a hand-made DeviceInfo, and recording every HTTP
// request it parsed. A request that never reaches `requests` was never sent
// (for TLS: the client aborted at the handshake or sent bytes the HTTP parser
// rejected).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';

import 'p6b_support.dart';

class SeenRequest {
  SeenRequest(this.method, this.path, this.headers, this.body);
  final String method;
  final String path;

  /// Lower-cased header name -> first value.
  final Map<String, String> headers;
  final Uint8List body;
}

class LoopbackPeer {
  LoopbackPeer._(
    this._server,
    this.identity,
    this.infoFingerprint,
    this.isTls,
  ) {
    _sub = _server.listen(_handle, onError: (Object _) {});
  }

  /// A TLS 1.3 listener whose certificate is [identity]'s. [infoFingerprint]
  /// is what the DeviceInfo it serves claims (default: the certificate's own);
  /// pass another value to play a liar.
  static Future<LoopbackPeer> tls(
    P6bPeer identity, {
    String? infoFingerprint,
  }) async {
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      buildServerContext(identity.key),
    );
    return LoopbackPeer._(server, identity, infoFingerprint, true);
  }

  /// A plaintext HTTP listener that claims [identity]'s fingerprint (the
  /// stand-in for an LSP/1.0 or `--insecure-plaintext` receiver).
  static Future<LoopbackPeer> plain(
    P6bPeer identity, {
    String? infoFingerprint,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return LoopbackPeer._(server, identity, infoFingerprint, false);
  }

  final HttpServer _server;
  final P6bPeer identity;
  final String? infoFingerprint;
  final bool isTls;
  late final StreamSubscription<HttpRequest> _sub;

  final List<SeenRequest> requests = [];

  int get port => _server.port;

  /// The DeviceInfo this peer serves.
  DeviceInfo get info => identity.info(
    port: port,
    fingerprint: isTls
        ? (infoFingerprint ?? identity.fp)
        : (infoFingerprint ?? ''),
    version: isTls ? kProtocolVersionSecure : kProtocolVersion,
  );

  /// What a client should know about it from an announce.
  DeviceInfo announced({String? fingerprint}) => DeviceInfo(
    deviceId: identity.id,
    alias: 'dev-${identity.id}',
    platform: 'linux',
    fingerprint: fingerprint ?? identity.fp,
    port: port,
    version: kProtocolVersionSecure,
  );

  Future<void> _handle(HttpRequest request) async {
    final body = BytesBuilder();
    await for (final chunk in request) {
      body.add(chunk);
    }
    final headers = <String, String>{};
    request.headers.forEach((name, values) {
      if (values.isNotEmpty) headers[name.toLowerCase()] = values.first;
    });
    requests.add(
      SeenRequest(request.method, request.uri.path, headers, body.takeBytes()),
    );
    final ok =
        (request.method == 'GET' && request.uri.path == '/api/v1/info') ||
        (request.method == 'POST' && request.uri.path == '/api/v1/register');
    final response = request.response;
    if (!ok) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    final json = utf8.encode(jsonEncode(info.toJson()));
    response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..contentLength = json.length
      ..add(json);
    await response.close();
  }

  Future<void> close() async {
    await _sub.cancel();
    await _server.close(force: true);
  }
}
