// Hand-written HTTP/1.1 peers for the P5 client tests (docs/plans/inc3-p5-tests.md).
//
// They do NOT depend on ApiServer (P3): a raw TLS listener built from the P1 server context and a
// raw plain-TCP listener, both speaking a minimal HTTP/1.1 by hand and COUNTING what they receive,
// so "zero HTTP bytes reached the peer" is an observable fact and not an assumption.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';

/// One parsed HTTP request as the peer saw it on the wire.
class RawRequest {
  RawRequest({
    required this.method,
    required this.target,
    required this.headers,
    required this.body,
    required this.connection,
  });

  final String method;

  /// Request target exactly as sent (`/api/v1/sessions?x=1`).
  final String target;

  /// Header names lower-cased.
  final Map<String, String> headers;
  final Uint8List body;

  /// 1-based number of the TCP connection the request arrived on.
  final int connection;

  String? header(String name) => headers[name.toLowerCase()];

  String get path => Uri.parse(target).path;

  Object? get json => body.isEmpty ? null : jsonDecode(utf8.decode(body));

  @override
  String toString() => '$method $path';
}

class RawResponse {
  const RawResponse(
    this.status, {
    this.headers = const {},
    this.body = const [],
    this.close = false,
  });

  factory RawResponse.json(
    int status,
    Object? body, {
    Map<String, String> headers = const {},
    bool close = false,
  }) => RawResponse(
    status,
    headers: {'content-type': 'application/json', ...headers},
    body: utf8.encode(jsonEncode(body)),
    close: close,
  );

  /// The LSP-1 error envelope (4.3.5).
  factory RawResponse.error(
    int status,
    String code, {
    Map<String, String> headers = const {},
  }) => RawResponse.json(status, {
    'error': {'code': code, 'message': 'x', 'retryable': false},
  }, headers: headers);

  final int status;
  final Map<String, String> headers;
  final List<int> body;
  final bool close;
}

typedef RawHandler = FutureOr<RawResponse> Function(RawRequest request);

/// What a plain (non-TLS) peer does with bytes that are not an HTTP request (a TLS ClientHello).
enum GarbageReply {
  /// Answer like `dart:io` HttpServer does: `HTTP/1.1 400 Bad Request`, then close.
  badRequest,

  /// Close without a single byte.
  silent,
}

final RegExp _requestLine = RegExp(r'^([A-Z]{3,7}) (\S+) HTTP/1\.[01]$');

/// Shared HTTP/1.1 plumbing and counters.
abstract class RawPeer {
  RawPeer({
    required this.handler,
    required this.keepAlive,
    required this.clockOffset,
    required this.sendDate,
    required this.garbageReply,
  });

  RawHandler handler;
  final bool keepAlive;
  final GarbageReply garbageReply;

  /// Added to the wall clock for the `Date` header (fake server clock).
  Duration clockOffset;
  bool sendDate;

  /// Every complete HTTP request seen, in order.
  final List<RawRequest> requests = [];

  /// Application bytes received (after the TLS handshake for a TLS peer).
  int bytesReceived = 0;

  /// Everything received, as latin-1 text (capped), to look for sentinels.
  final StringBuffer _seen = StringBuffer();
  String get receivedText => _seen.toString();

  /// Bytes that were not the start of an HTTP request.
  int garbageBytes = 0;

  /// Connections that reached [serve] (for TLS: handshake completed).
  int connections = 0;

  final List<Socket> _sockets = [];

  DateTime get serverNow => DateTime.now().toUtc().add(clockOffset);

  void serve(Socket socket) {
    final feed = openConnection(socket);
    socket.listen(
      feed,
      onError: (Object _) => socket.destroy(),
      onDone: () => socket.destroy(),
      cancelOnError: true,
    );
  }

  /// Starts HTTP handling on [socket]; the returned function takes the bytes read from it.
  void Function(List<int>) openConnection(Socket socket) {
    connections++;
    final id = connections;
    _sockets.add(socket);
    var pending = Uint8List(0);
    var chain = Future<void>.value();
    var dead = false;

    Future<void> drain() async {
      while (!dead) {
        if (pending.isEmpty) return;
        // A request starts with an upper-case ASCII method; a TLS record does not.
        if (pending[0] < 0x41 || pending[0] > 0x5A) {
          garbageBytes += pending.length;
          pending = Uint8List(0);
          await _garbage(socket);
          dead = true;
          return;
        }
        final end = _indexOfHeadEnd(pending);
        if (end < 0) {
          if (pending.length > 65536) {
            dead = true;
            socket.destroy();
          }
          return;
        }
        final head = latin1
            .decode(pending, allowInvalid: true)
            .substring(0, end);
        final lines = head.split('\r\n');
        final m = _requestLine.firstMatch(lines.first);
        if (m == null) {
          garbageBytes += pending.length;
          pending = Uint8List(0);
          await _garbage(socket);
          dead = true;
          return;
        }
        final headers = <String, String>{};
        for (final l in lines.skip(1)) {
          final i = l.indexOf(':');
          if (i > 0) {
            headers[l.substring(0, i).trim().toLowerCase()] = l
                .substring(i + 1)
                .trim();
          }
        }
        final len = int.tryParse(headers['content-length'] ?? '0') ?? 0;
        final total = end + 4 + len;
        if (pending.length < total) return;
        final body = Uint8List.fromList(pending.sublist(end + 4, total));
        pending = Uint8List.fromList(pending.sublist(total));
        final req = RawRequest(
          method: m.group(1)!,
          target: m.group(2)!,
          headers: headers,
          body: body,
          connection: id,
        );
        requests.add(req);
        final res = await handler(req);
        if (dead) return;
        final close = res.close || !keepAlive;
        socket.add(_encode(res, close));
        await socket.flush();
        if (close) {
          dead = true;
          await socket.close();
          socket.destroy();
        }
      }
    }

    return (List<int> data) {
      bytesReceived += data.length;
      if (_seen.length < 1 << 20) _seen.write(latin1.decode(data));
      pending = Uint8List.fromList([...pending, ...data]);
      chain = chain.then((_) => drain()).catchError((Object _) {
        dead = true;
        socket.destroy();
      });
    };
  }

  Future<void> _garbage(Socket socket) async {
    if (garbageReply == GarbageReply.badRequest) {
      socket.add(
        latin1.encode(
          'HTTP/1.1 400 Bad Request\r\nConnection: close\r\n'
          'Content-Length: 0\r\n\r\n',
        ),
      );
      await socket.flush();
    }
    await socket.close();
    socket.destroy();
  }

  List<int> _encode(RawResponse res, bool close) {
    final b = StringBuffer('HTTP/1.1 ${res.status} X\r\n');
    final h = {...res.headers};
    if (sendDate && !h.keys.any((k) => k.toLowerCase() == 'date')) {
      h['date'] = HttpDate.format(serverNow);
    }
    h['content-length'] = '${res.body.length}';
    if (close) h['connection'] = 'close';
    h.forEach((k, v) => b.write('$k: $v\r\n'));
    b.write('\r\n');
    return [...latin1.encode(b.toString()), ...res.body];
  }

  static int _indexOfHeadEnd(Uint8List b) {
    for (var i = 0; i + 3 < b.length; i++) {
      if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  /// Requests the peer parsed whose header [name] is present.
  List<RawRequest> withHeader(String name) => [
    for (final r in requests)
      if (r.header(name) != null) r,
  ];

  Future<void> close();

  void _destroyAll() {
    for (final s in _sockets) {
      s.destroy();
    }
    _sockets.clear();
  }
}

/// TLS listener with the identity certificate from the P1 server context (TLS 1.3 only, no client
/// certificate request). `handshakeErrors` counts handshakes the client aborted.
class RawTlsPeer extends RawPeer {
  RawTlsPeer._(
    this._server,
    this.identity, {
    required super.handler,
    required super.keepAlive,
    required super.clockOffset,
    required super.sendDate,
  }) : super(garbageReply: GarbageReply.silent);

  final SecureServerSocket _server;
  final IdentityProvider identity;
  int handshakeErrors = 0;

  int get port => _server.port;

  String get fingerprint => identity.identity.fingerprint;

  /// Binds loopback; [port] 0 picks a free port. [handler] defaults to an `/info` that tells the
  /// truth (this identity's fingerprint).
  static Future<RawTlsPeer> start(
    IdentityProvider identity, {
    RawHandler? handler,
    int port = 0,
    bool keepAlive = true,
    Duration clockOffset = Duration.zero,
    bool sendDate = true,
  }) async {
    SecureServerSocket? server;
    for (var attempt = 0; attempt < 40; attempt++) {
      try {
        server = await SecureServerSocket.bind(
          InternetAddress.loopbackIPv4,
          port,
          buildServerContext(identity),
          shared: true,
        );
        break;
      } on SocketException {
        if (port == 0 || attempt == 39) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    final peer = RawTlsPeer._(
      server!,
      identity,
      handler: handler ?? (r) => truthfulInfo(identity)(r),
      keepAlive: keepAlive,
      clockOffset: clockOffset,
      sendDate: sendDate,
    );
    server.listen(peer.serve, onError: (Object _) => peer.handshakeErrors++);
    return peer;
  }

  @override
  Future<void> close() async {
    _destroyAll();
    await _server.close();
  }
}

/// Plain TCP listener speaking HTTP/1.1: stands in for an LSP/1.0 or plaintext-profile peer, and
/// sees whatever a TLS client sends to it as [garbageBytes].
class RawPlainPeer extends RawPeer {
  RawPlainPeer._(
    this._server, {
    required super.handler,
    required super.keepAlive,
    required super.garbageReply,
  }) : super(clockOffset: Duration.zero, sendDate: true);

  final ServerSocket _server;

  int get port => _server.port;

  static Future<RawPlainPeer> start({
    RawHandler? handler,
    bool keepAlive = true,
    GarbageReply garbageReply = GarbageReply.badRequest,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final peer = RawPlainPeer._(
      server,
      handler: handler ?? legacyInfo,
      keepAlive: keepAlive,
      garbageReply: garbageReply,
    );
    server.listen(peer.serve, onError: (Object _) {});
    return peer;
  }

  @override
  Future<void> close() async {
    _destroyAll();
    await _server.close();
  }
}

/// One port that serves BOTH protocols by looking at the first byte (a TLS record starts with
/// 0x16): lets a test see whether a client that failed TLS tries plain HTTP on the same port.
/// (Production never does this, docs/plans/inc3.md D1 rejected option d.) Counters: [requests]
/// and [bytesReceived] count TLS traffic after the handshake as well as plain requests;
/// [plainRequests] counts only the requests that arrived without TLS.
class RawSniffPeer extends RawPeer {
  RawSniffPeer._(this._server, this.identity, {required super.handler})
    : super(
        keepAlive: true,
        clockOffset: Duration.zero,
        sendDate: true,
        garbageReply: GarbageReply.silent,
      );

  final ServerSocket _server;
  final IdentityProvider identity;
  final Set<int> _plainConnections = {};

  /// Connections that did not start with a TLS record.
  int get plainConnections => _plainConnections.length;

  /// Requests that arrived on a connection that did not start with a TLS record.
  List<RawRequest> get plainRequests => [
    for (final r in requests)
      if (_plainConnections.contains(r.connection)) r,
  ];

  int tlsHandshakesStarted = 0;
  int tlsHandshakesFailed = 0;

  int get port => _server.port;

  static Future<RawSniffPeer> start(
    IdentityProvider identity, {
    RawHandler? handler,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final ctx = buildServerContext(identity);
    late RawSniffPeer peer;
    peer = RawSniffPeer._(
      server,
      identity,
      handler: handler ?? truthfulInfo(identity),
    );
    server.listen((raw) {
      late StreamSubscription<List<int>> sub;
      sub = raw.listen(
        (data) async {
          sub.pause();
          if (data.isNotEmpty && data[0] == 0x16) {
            peer.tlsHandshakesStarted++;
            try {
              final s = await SecureSocket.secureServer(
                raw,
                ctx,
                bufferedData: data,
              );
              peer.serve(s);
            } on Object {
              peer.tlsHandshakesFailed++;
              raw.destroy();
            }
          } else {
            peer._plainConnections.add(peer.connections + 1);
            final feed = peer.openConnection(raw);
            sub.onData(feed);
            feed(data);
            sub.resume();
          }
        },
        onError: (Object _) => raw.destroy(),
        onDone: () => raw.destroy(),
      );
    });
    return peer;
  }

  @override
  Future<void> close() async {
    _destroyAll();
    await _server.close();
  }
}

/// DeviceInfo a peer reports about itself.
DeviceInfo infoFor(String deviceId, String fingerprint, {int port = 53318}) =>
    DeviceInfo(
      deviceId: deviceId,
      alias: 'peer',
      platform: 'linux',
      fingerprint: fingerprint,
      port: port,
      version: fingerprint.isEmpty ? kProtocolVersion : kProtocolVersionSecure,
    );

/// `/info` answers with this identity's real fingerprint; everything else is a 404 envelope.
RawHandler truthfulInfo(IdentityProvider identity) => (r) {
  if (r.method == 'GET' && r.path == '/api/v1/info') {
    return RawResponse.json(
      200,
      infoFor(
        identity.identity.deviceId,
        identity.identity.fingerprint,
      ).toJson(),
    );
  }
  return RawResponse.error(404, 'NOT_FOUND');
};

/// A legacy peer: `/info` has an empty fingerprint, `v` 1.0.
FutureOr<RawResponse> legacyInfo(RawRequest r) {
  if (r.method == 'GET' && r.path == '/api/v1/info') {
    return RawResponse.json(200, infoFor('legacy-peer', '').toJson());
  }
  return RawResponse.json(200, {
    'sessionId': 'sess-legacy',
    'status': 'IN_PROGRESS',
    'acceptedFiles': <String, Object?>{},
  });
}

/// A canned `SessionStatus` JSON.
Map<String, Object?> statusJson(
  String status, {
  String sid = 'sess-1',
  String? nonce,
  Map<String, Object?> accepted = const {},
}) => {
  'sessionId': sid,
  'status': status,
  'failureReason': null,
  'acceptedFiles': accepted,
  if (nonce != null) 'sas': {'nonce': nonce},
};

/// Verifies `X-LS-Auth` headers the way the P3 server will (P1's `verifyAuthHeader`), with this
/// peer's own fingerprint as the channel binding.
class ProofChecker {
  ProofChecker(this.ownFingerprint, {DateTime Function()? now})
    : _now = now ?? (() => DateTime.now().toUtc()),
      nonces = NonceCache(clock: now);

  final String ownFingerprint;
  final DateTime Function() _now;
  final NonceCache nonces;

  AuthResult check(RawRequest r, {String? asFingerprint}) => verifyAuthHeader(
    header: r.header(kAuthHeader),
    method: r.method,
    pathAndQuery: pathAndQueryOf(Uri.parse(r.target)),
    body: r.body,
    ownFingerprint: asFingerprint ?? ownFingerprint,
    now: _now(),
    nonces: asFingerprint == null ? nonces : NonceCache(),
  );
}

/// `ts` (ms) and nonce text of an `X-LS-Auth` value.
({int ts, String nonce}) proofParts(String header) {
  final p = header.split('.');
  return (ts: int.parse(p[2]), nonce: p[3]);
}
