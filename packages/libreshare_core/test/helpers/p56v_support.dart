// Helpers of the P5/P6b verifying-tester review tests (test/security/p5_review_test.dart,
// test/security/p6b_review_test.dart). Loopback only.
import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';

/// A TCP listener that accepts connections and kills them: [readFirst] waits for the first bytes
/// (the TLS ClientHello) before it does, otherwise the connection is destroyed on accept. It never
/// speaks TLS or HTTP, so it models a transient reset during the handshake.
class ResettingPeer {
  ResettingPeer._(this._server);

  final ServerSocket _server;
  int accepted = 0;

  int get port => _server.port;

  static Future<ResettingPeer> start({bool readFirst = true}) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final peer = ResettingPeer._(server);
    server.listen((socket) {
      peer.accepted++;
      if (!readFirst) {
        socket.destroy();
        return;
      }
      socket.listen(
        (_) => socket.destroy(),
        onError: (Object _) => socket.destroy(),
        onDone: socket.destroy,
      );
    });
    return peer;
  }

  Future<void> close() => _server.close();
}

/// Collects every log record (message, error text, stack text) emitted while it is attached.
class LogCapture {
  LogCapture() {
    _previous = Logger.root.level;
    Logger.root.level = Level.ALL;
    _sub = Logger.root.onRecord.listen((r) {
      lines.add(
        '${r.loggerName}: ${r.message} ${r.error ?? ''} ${r.stackTrace ?? ''}',
      );
    });
  }

  late final Level _previous;
  late final StreamSubscription<LogRecord> _sub;
  final List<String> lines = [];

  String get text => lines.join('\n');

  Future<void> close() async {
    await _sub.cancel();
    Logger.root.level = _previous;
  }
}
