// Fake in-process ntfy.sh compatible HTTP server for testing NtfyBackend.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

class FakeNtfyServer {
  FakeNtfyServer._(this._server);

  final HttpServer _server;
  final Map<String, List<Map<String, dynamic>>> _topics = {};
  bool _returnError = false;

  int get port => _server.port;
  Uri get uri => Uri.parse('http://${_server.address.host}:${_server.port}');

  void setErrorMode(bool enabled) {
    _returnError = enabled;
  }

  static Future<FakeNtfyServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = FakeNtfyServer._(server);
    server.listen(instance._handleRequest);
    return instance;
  }

  void _handleRequest(HttpRequest request) async {
    if (_returnError) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }

    final segments = request.uri.pathSegments;
    if (segments.isEmpty) {
      request.response.statusCode = HttpStatus.ok;
      request.response.write('ntfy fake server');
      await request.response.close();
      return;
    }

    final topic = segments[0];

    if (request.method == 'POST' || request.method == 'PUT') {
      final body = await utf8.decoder.bind(request).join();
      final msgList = _topics.putIfAbsent(topic, () => []);
      final msgRecord = {
        'id':
            'ntfy-msg-${DateTime.now().millisecondsSinceEpoch}-${msgList.length}',
        'time': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'event': 'message',
        'topic': topic,
        'message': body,
      };
      msgList.add(msgRecord);

      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(msgRecord));
      await request.response.close();
      return;
    }

    if (request.method == 'GET') {
      final msgList = _topics[topic] ?? [];
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;

      // Format as JSON stream (line-delimited JSON like ntfy.sh)
      for (final msg in msgList) {
        request.response.writeln(jsonEncode(msg));
      }
      await request.response.close();
      return;
    }

    request.response.statusCode = HttpStatus.methodNotAllowed;
    await request.response.close();
  }

  Future<void> close() async {
    await _server.close(force: true);
  }
}
