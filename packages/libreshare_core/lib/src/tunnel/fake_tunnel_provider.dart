import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'tunnel_provider.dart';

final class CapturedFrame {
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final Uint8List body;
  final int statusCode;
  final DateTime timestamp;

  CapturedFrame({
    required this.method,
    required this.uri,
    required this.headers,
    required this.body,
    required this.statusCode,
    required this.timestamp,
  });
}

class FakeTunnelProvider implements TunnelProvider {
  final int maxInFlight;
  final int maxRequestBodyBytes;
  final Duration simulatedLatency;
  final double simulatedLossRate;

  // Hostile mode knobs
  final int hostileBitFlipChunkIndex;
  final int hostileDropChunkIndex;
  final bool hostileSwapChunks;

  final List<CapturedFrame> captureBuffer = [];

  FakeTunnelProvider({
    this.maxInFlight = 200,
    this.maxRequestBodyBytes = 100 * 1024 * 1024, // 100 MiB
    this.simulatedLatency = Duration.zero,
    this.simulatedLossRate = 0.0,
    this.hostileBitFlipChunkIndex = -1,
    this.hostileDropChunkIndex = -1,
    this.hostileSwapChunks = false,
  });

  @override
  String get id => 'fake';

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<TunnelHandle> open(
    int localPort, {
    Duration ready = const Duration(seconds: 45),
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final handle = _FakeTunnelHandle(
      provider: this,
      server: server,
      originPort: localPort,
    );
    await handle.init();
    return handle;
  }

  bool containsPlaintext(List<int> marker) {
    if (marker.isEmpty) return false;
    for (final frame in captureBuffer) {
      if (_containsSublist(frame.body, marker)) {
        return true;
      }
    }
    return false;
  }

  static bool _containsSublist(List<int> source, List<int> pattern) {
    if (pattern.length > source.length) return false;
    for (var i = 0; i <= source.length - pattern.length; i++) {
      var match = true;
      for (var j = 0; j < pattern.length; j++) {
        if (source[i + j] != pattern[j]) {
          match = false;
          break;
        }
      }
      if (match) return true;
    }
    return false;
  }
}

class _FakeTunnelHandle implements TunnelHandle {
  final FakeTunnelProvider provider;
  final HttpServer server;
  final int originPort;
  final HttpClient _client = HttpClient();
  final StreamController<TunnelEvent> _eventController =
      StreamController<TunnelEvent>.broadcast();

  int _inFlightCount = 0;
  bool _closed = false;

  _FakeTunnelHandle({
    required this.provider,
    required this.server,
    required this.originPort,
  });

  @override
  Uri get publicBase => Uri.parse('http://127.0.0.1:${server.port}');

  @override
  Stream<TunnelEvent> get events async* {
    if (!_closed) {
      yield const TunnelUpEvent();
    }
    yield* _eventController.stream;
  }

  Future<void> init() async {
    server.listen(
      _handleIncomingRequest,
      onError: (e) {
        if (!_closed) {
          _eventController.add(TunnelLostEvent(e.toString()));
        }
      },
    );
  }

  Future<void> _handleIncomingRequest(HttpRequest clientReq) async {
    if (_closed) {
      clientReq.response.statusCode = HttpStatus.serviceUnavailable;
      await clientReq.response.close();
      return;
    }

    if (_inFlightCount >= provider.maxInFlight) {
      clientReq.response
        ..statusCode = HttpStatus.tooManyRequests
        ..headers.set('Retry-After', '5')
        ..write('Too Many Requests');
      await clientReq.response.close();
      return;
    }

    _inFlightCount++;

    try {
      if (provider.simulatedLatency > Duration.zero) {
        await Future<void>.delayed(provider.simulatedLatency);
      }

      // Check hostile chunk drop
      if (provider.hostileDropChunkIndex >= 0) {
        final path = clientReq.uri.path;
        if (path.endsWith('/c/${provider.hostileDropChunkIndex}')) {
          clientReq.response.statusCode = HttpStatus.gatewayTimeout;
          await clientReq.response.close();
          return;
        }
      }

      // Read client request body up to maxRequestBodyBytes
      final bodyBytes = <int>[];
      var exceeded = false;
      await for (final chunk in clientReq) {
        bodyBytes.addAll(chunk);
        if (bodyBytes.length > provider.maxRequestBodyBytes) {
          exceeded = true;
          break;
        }
      }

      if (exceeded) {
        clientReq.response
          ..statusCode = HttpStatus.requestEntityTooLarge
          ..write('Payload Too Large');
        await clientReq.response.close();
        return;
      }

      final reqHeaders = <String, String>{};
      clientReq.headers.forEach((name, values) {
        reqHeaders[name] = values.join(', ');
      });

      provider.captureBuffer.add(
        CapturedFrame(
          method: clientReq.method,
          uri: clientReq.uri,
          headers: reqHeaders,
          body: Uint8List.fromList(bodyBytes),
          statusCode: 0,
          timestamp: DateTime.now(),
        ),
      );

      // Check hostile chunk swap (swap /c/0 and /c/1)
      var targetUri = clientReq.uri;
      if (provider.hostileSwapChunks) {
        final path = targetUri.path;
        if (path.endsWith('/c/0')) {
          targetUri = targetUri.replace(path: path.replaceAll('/c/0', '/c/1'));
        } else if (path.endsWith('/c/1')) {
          targetUri = targetUri.replace(path: path.replaceAll('/c/1', '/c/0'));
        }
      }

      // Forward to origin
      final originUri = Uri.parse(
        'http://127.0.0.1:$originPort${targetUri.path}${targetUri.hasQuery ? '?${targetUri.query}' : ''}',
      );
      final originReq = await _client.openUrl(clientReq.method, originUri);

      // Copy headers
      clientReq.headers.forEach((name, values) {
        if (name.toLowerCase() != 'host') {
          for (final val in values) {
            originReq.headers.add(name, val);
          }
        }
      });
      originReq.headers.set('Host', '127.0.0.1:$originPort');
      originReq.headers.set(
        'Cf-Connecting-Ip',
        clientReq.connectionInfo?.remoteAddress.address ?? '127.0.0.1',
      );

      if (bodyBytes.isNotEmpty) {
        originReq.add(bodyBytes);
      }

      final originResp = await originReq.close();
      var respBody = await originResp.fold<List<int>>(
        [],
        (p, e) => p..addAll(e),
      );

      // Hostile bit-flip modification
      if (provider.hostileBitFlipChunkIndex >= 0 &&
          clientReq.uri.path.endsWith(
            '/c/${provider.hostileBitFlipChunkIndex}',
          )) {
        if (respBody.isNotEmpty) {
          final tampered = List<int>.from(respBody);
          // Flip lowest bit of first byte
          tampered[tampered.length ~/ 2] ^= 0x01;
          respBody = tampered;
        }
      }

      // Record captured response
      final respHeaders = <String, String>{};
      originResp.headers.forEach((name, values) {
        respHeaders[name] = values.join(', ');
      });

      provider.captureBuffer.add(
        CapturedFrame(
          method: clientReq.method,
          uri: clientReq.uri,
          headers: respHeaders,
          body: Uint8List.fromList(respBody),
          statusCode: originResp.statusCode,
          timestamp: DateTime.now(),
        ),
      );

      // Return to client
      clientReq.response.statusCode = originResp.statusCode;
      originResp.headers.forEach((name, values) {
        for (final val in values) {
          clientReq.response.headers.add(name, val);
        }
      });

      clientReq.response.add(respBody);
      await clientReq.response.close();
    } finally {
      _inFlightCount--;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _eventController.add(const TunnelLostEvent('closed'));
    await _eventController.close();
    _client.close(force: true);
    await server.close(force: true);
  }
}
