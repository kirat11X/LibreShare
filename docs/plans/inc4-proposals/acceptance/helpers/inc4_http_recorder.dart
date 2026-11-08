// Inc 4 acceptance helper: a TCP proxy that understands just enough HTTP/1.1
// (request line, Content-Length / chunked bodies, response status line) to
// record, for every request that REACHES the receiver, its method, path, how
// many body bytes were forwarded and which status the receiver answered. It
// is the "receiver log" of docs/plans/inc4.md section 4 (FR-13: count of PUT
// per chunk index) without touching lib/. Plain HTTP only (not TLS).
//
// Topology used by the tests:
//   sender -> [FaultyTcpProxy] -> HttpRecordingProxy -> receiver
// so a fault injected upstream shows up here as a request with fewer body
// bytes than its Content-Length and no status (never acknowledged).
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// One request as seen on its way to the receiver.
class RecordedRequest {
  RecordedRequest({
    required this.seq,
    required this.label,
    required this.connId,
    required this.method,
    required this.path,
    required this.contentLength,
    required this.at,
  });

  /// Arrival order across every recorder that shares one [RecordLog].
  final int seq;

  /// Which recorder (tier) saw it.
  final String label;
  final int connId;
  final String method;
  final String path;
  final int contentLength;
  final DateTime at;

  /// Body bytes forwarded to the receiver so far.
  int bodyBytes = 0;

  /// Status of the receiver's answer; null = never answered.
  int? status;

  bool get answered => status != null;
  bool get acked => status != null && status! >= 200 && status! < 300;
  bool get bodyComplete => bodyBytes >= contentLength;

  static final RegExp _chunk = RegExp(
    r'/sessions/([^/]+)/files/([^/]+)/chunks/(\d+)$',
  );

  bool get isChunkPut => method == 'PUT' && _chunk.hasMatch(path);
  int? get chunkIndex {
    final m = _chunk.firstMatch(path);
    return m == null ? null : int.parse(m.group(3)!);
  }

  String? get fileId => _chunk.firstMatch(path)?.group(2);

  @override
  String toString() =>
      '#$seq[$label c$connId] $method $path body=$bodyBytes/$contentLength '
      'status=$status';
}

/// Shared, ordered log of [RecordedRequest]s.
class RecordLog {
  final List<RecordedRequest> requests = [];
  int _seq = 0;

  int nextSeq() => _seq++;

  List<RecordedRequest> get chunkPuts =>
      requests.where((r) => r.isChunkPut).toList();

  /// Chunk indices acknowledged (2xx) so far.
  Set<int> get ackedIndices => {
    for (final r in chunkPuts)
      if (r.acked) r.chunkIndex!,
  };

  /// Number of PUTs (any outcome) per chunk index.
  Map<int, int> get putCounts {
    final m = <int, int>{};
    for (final r in chunkPuts) {
      m[r.chunkIndex!] = (m[r.chunkIndex!] ?? 0) + 1;
    }
    return m;
  }

  /// Indices acknowledged more than once, or PUT again after an ack.
  List<String> resentAfterAck() {
    final acked = <int>{};
    final bad = <String>[];
    for (final r in chunkPuts) {
      final i = r.chunkIndex!;
      if (acked.contains(i)) bad.add('chunk $i PUT again after ack: $r');
      if (r.acked) acked.add(i);
    }
    return bad;
  }
}

enum _St { head, fixed, chunkSize, chunkData, trailer, none }

/// Incremental HTTP/1.1 message framer (headers + body skipping).
class _Framer {
  _Framer({required this.isRequest, required this.onHead, this.onBody});

  final bool isRequest;

  /// start line, lower-case header map. Returns nothing.
  final void Function(String startLine, Map<String, String> headers) onHead;
  final void Function(int n)? onBody;

  final BytesBuilder _buf = BytesBuilder(copy: false);
  _St _st = _St.head;
  int _left = 0;
  final List<int> _line = [];
  bool _broken = false;

  void add(Uint8List data) {
    if (_broken) return;
    var i = 0;
    while (i < data.length) {
      switch (_st) {
        case _St.head:
          _buf.addByte(data[i++]);
          final b = _buf.length;
          if (b >= 4 && b <= 65536) {
            final bytes = _buf.toBytes();
            if (bytes[b - 4] == 13 &&
                bytes[b - 3] == 10 &&
                bytes[b - 2] == 13 &&
                bytes[b - 1] == 10) {
              _buf.clear();
              _endOfHead(String.fromCharCodes(bytes, 0, b - 4));
            }
          } else if (b > 65536) {
            _broken = true;
            return;
          }
        case _St.fixed:
          final n = _left < data.length - i ? _left : data.length - i;
          onBody?.call(n);
          _left -= n;
          i += n;
          if (_left == 0) _st = _St.head;
        case _St.chunkSize:
          final c = data[i++];
          if (c == 10) {
            final s = String.fromCharCodes(_line).split(';').first.trim();
            _line.clear();
            final size = int.tryParse(s, radix: 16);
            if (size == null) {
              _broken = true;
              return;
            }
            if (size == 0) {
              _st = _St.trailer;
            } else {
              _left = size + 2; // data + CRLF
              _st = _St.chunkData;
            }
          } else if (c != 13) {
            _line.add(c);
          }
        case _St.chunkData:
          final n = _left < data.length - i ? _left : data.length - i;
          onBody?.call(n);
          _left -= n;
          i += n;
          if (_left == 0) _st = _St.chunkSize;
        case _St.trailer:
          final c = data[i++];
          if (c == 10) {
            if (_line.isEmpty) {
              _st = _St.head;
            }
            _line.clear();
          } else if (c != 13) {
            _line.add(c);
          }
        case _St.none:
          _st = _St.head;
      }
    }
  }

  void _endOfHead(String head) {
    final lines = head.split('\r\n');
    final headers = <String, String>{};
    for (final l in lines.skip(1)) {
      final k = l.indexOf(':');
      if (k > 0) {
        headers[l.substring(0, k).trim().toLowerCase()] = l
            .substring(k + 1)
            .trim();
      }
    }
    onHead(lines.first, headers);
    var noBody = false;
    if (!isRequest) {
      final status = int.tryParse(
        lines.first.split(' ').elementAtOrNull(1) ?? '',
      );
      noBody = status == null || status == 204 || status == 304 || status < 200;
    }
    if (noBody) {
      _st = _St.head;
    } else if ((headers['transfer-encoding'] ?? '').toLowerCase().contains(
      'chunked',
    )) {
      _st = _St.chunkSize;
    } else {
      final cl = int.tryParse(headers['content-length'] ?? '') ?? 0;
      if (cl > 0) {
        _left = cl;
        _st = _St.fixed;
      } else {
        _st = _St.head;
      }
    }
  }
}

class HttpRecordingProxy {
  HttpRecordingProxy._(this._server, this.label, this.log, this.targetPort);

  /// Listens on a free loopback port and forwards to 127.0.0.1:[targetPort].
  static Future<HttpRecordingProxy> start({
    required int targetPort,
    required RecordLog log,
    String label = 'rec',
    InternetAddress? bindAddress,
    int? bytesPerSecond,
  }) async {
    final server = await ServerSocket.bind(
      bindAddress ?? InternetAddress.loopbackIPv4,
      0,
    );
    final p = HttpRecordingProxy._(server, label, log, targetPort)
      ..bytesPerSecond = bytesPerSecond;
    server.listen(p._onClient, onError: (Object _) {});
    return p;
  }

  final ServerSocket _server;
  final String label;
  final RecordLog log;

  /// Where new connections go; may be changed while running (receiver restart).
  int targetPort;

  /// Optional bandwidth cap on the request direction (client to receiver).
  /// Each forwarded piece is followed by a pause of length/bytesPerSecond, so
  /// a transfer takes a wall-clock time that does not depend on CPU or hash
  /// speed. Settable while running.
  int? bytesPerSecond;

  final Set<Socket> _sockets = {};
  int _nextConn = 0;
  bool _closed = false;

  int get port => _server.port;

  Iterable<RecordedRequest> get mine =>
      log.requests.where((r) => r.label == label);

  Future<void> _onClient(Socket client) async {
    if (_closed) {
      client.destroy();
      return;
    }
    final connId = _nextConn++;
    final Socket target;
    try {
      target = await Socket.connect(InternetAddress.loopbackIPv4, targetPort);
    } on Object {
      client.destroy();
      return;
    }
    _sockets
      ..add(client)
      ..add(target);
    final pending = <RecordedRequest>[];
    RecordedRequest? current;

    final reqFramer = _Framer(
      isRequest: true,
      onHead: (line, headers) {
        final parts = line.split(' ');
        final r = RecordedRequest(
          seq: log.nextSeq(),
          label: label,
          connId: connId,
          method: parts.first,
          path: parts.length > 1 ? parts[1] : '',
          contentLength: int.tryParse(headers['content-length'] ?? '') ?? 0,
          at: DateTime.now(),
        );
        log.requests.add(r);
        pending.add(r);
        current = r;
      },
      onBody: (n) => current?.bodyBytes += n,
    );
    final resFramer = _Framer(
      isRequest: false,
      onHead: (line, headers) {
        final status = int.tryParse(line.split(' ').elementAtOrNull(1) ?? '');
        if (pending.isNotEmpty) pending.removeAt(0).status = status;
      },
    );

    void closeBoth() {
      _sockets
        ..remove(client)
        ..remove(target);
      client.destroy();
      target.destroy();
    }

    // Harness hardening: a write racing a peer reset surfaces as an async
    // error on Socket.done / close(); it must never escape as an unhandled
    // zone error (it is not a property under test).
    unawaited(client.done.then((_) {}, onError: (Object _) {}));
    unawaited(target.done.then((_) {}, onError: (Object _) {}));

    late final StreamSubscription<Uint8List> cSub;
    cSub = client.listen(
      (d) {
        reqFramer.add(d);
        cSub.pause();
        target.add(d);
        target.flush().then((_) async {
          final bps = bytesPerSecond;
          if (bps != null && bps > 0) {
            await Future<void>.delayed(
              Duration(microseconds: d.length * 1000000 ~/ bps),
            );
          }
          if (!_closed) cSub.resume();
        }, onError: (Object _) => closeBoth());
      },
      onDone: () {
        try {
          target.close().then((_) {}, onError: (Object _) {});
        } on Object {
          // ignore
        }
      },
      onError: (Object _) => closeBoth(),
      cancelOnError: true,
    );
    target.listen(
      (d) {
        resFramer.add(d);
        try {
          client.add(d);
        } on Object {
          closeBoth();
        }
      },
      onDone: () {
        try {
          client.close().then((_) {}, onError: (Object _) {});
        } on Object {
          // ignore
        }
        _sockets
          ..remove(client)
          ..remove(target);
      },
      onError: (Object _) => closeBoth(),
      cancelOnError: true,
    );
  }

  /// Destroys every open connection (a dead path).
  void dropAll() {
    for (final s in _sockets.toList()) {
      s.destroy();
    }
    _sockets.clear();
  }

  Future<void> close() async {
    _closed = true;
    dropAll();
    await _server.close();
  }
}
