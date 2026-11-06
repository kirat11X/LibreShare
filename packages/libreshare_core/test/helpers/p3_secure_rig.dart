/// Shared rig for the P3 tests: a real [ApiServer] (secure or plaintext profile) on loopback over
/// a recording [P3SecureHandler], plus a raw `dart:io` client that signs requests with the P1
/// proof functions. Nothing here is a copy of server logic: the rig only builds requests.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:logging/logging.dart';

import 'p3_secure_handler.dart';

/// A client identity: key pair plus convenience accessors.
class P3Peer {
  P3Peer(String deviceId)
    : key = KeyIdentity.fromGenerated(generateIdentityFor(deviceId));

  final KeyIdentity key;
  String get deviceId => key.identity.deviceId;
  String get fp => key.identity.fingerprint;
  Uint8List get certDer => key.identity.certDer;

  /// A `DeviceInfo` that names this identity (secure profile: `v` 1.1, fingerprint set).
  DeviceInfo info({String? fingerprint, String alias = 'Sender'}) => DeviceInfo(
    deviceId: deviceId,
    alias: alias,
    platform: 'linux',
    fingerprint: fingerprint ?? fp,
    version: kProtocolVersionSecure,
  );
}

/// Fake wall clock.
class P3Clock implements Clock {
  P3Clock([DateTime? start]) : _t = start ?? DateTime.utc(2026, 11, 5, 12);
  DateTime _t;
  @override
  DateTime now() => _t;
  void advance(Duration d) => _t = _t.add(d);
}

class P3Res {
  P3Res(this.status, this.headers, this.bytes);
  final int status;
  final Map<String, List<String>> headers;
  final Uint8List bytes;

  String get text => utf8.decode(bytes, allowMalformed: true);
  Object? get json => jsonDecode(text);
  Map<String, Object?> get map => (json! as Map).cast<String, Object?>();
  Map<String, Object?> get error =>
      (map['error']! as Map).cast<String, Object?>();
  String? header(String name) => headers[name.toLowerCase()]?.join(', ');

  /// Header names (lowercase), sorted.
  List<String> get headerNames => headers.keys.toList()..sort();

  /// Headers without `date` (whose value legitimately differs between two responses).
  Map<String, String> get headersWithoutDate => {
    for (final e in headers.entries)
      if (e.key != 'date') e.key: e.value.join(', '),
  };

  DateTime? get date {
    final d = header('date');
    if (d == null) return null;
    try {
      return HttpDate.parse(d);
    } on Object {
      return null;
    }
  }
}

/// Session request JSON of exactly [length] bytes (valid JSON, valid shape; padded by an unknown
/// top-level member, which every parser must ignore). null [length] = no padding.
List<int> p3SessionBody(P3Peer sender, {int? length, int files = 1}) {
  final items = [
    for (var i = 0; i < files; i++)
      FileItem(fileId: 'f$i', fileName: 'a$i.bin', size: 1, chunkCount: 1),
  ];
  final map = SessionRequest(
    sender: sender.info(),
    files: items,
    totalSize: files,
  ).toJson();
  if (length == null) return utf8.encode(jsonEncode(map));
  map['pad'] = '';
  final base = utf8.encode(jsonEncode(map)).length;
  if (length < base) throw ArgumentError('length too small: $base');
  map['pad'] = 'x' * (length - base);
  final out = utf8.encode(jsonEncode(map));
  assert(out.length == length);
  return out;
}

/// Same for `POST /register` (a DeviceInfo).
List<int> p3RegisterBody(DeviceInfo info, {int? length}) {
  final map = info.toJson();
  if (length == null) return utf8.encode(jsonEncode(map));
  map['pad'] = '';
  final base = utf8.encode(jsonEncode(map)).length;
  map['pad'] = 'x' * (length - base);
  return utf8.encode(jsonEncode(map));
}

/// A valid SAS nonce (22 base64url characters).
const String p3Nonce22 = 'ICEiIyQlJicoKSorLC0uLw';

class P3Rig {
  P3Rig._({
    required this.server,
    required this.handler,
    required this.trust,
    required this.serverKey,
    required this.port,
    required this.secure,
  });

  final ApiServer server;
  final P3SecureHandler handler;
  final InMemoryTrustStore trust;
  final KeyIdentity? serverKey;
  final int port;
  final bool secure;

  /// Fingerprints of the certificates the client saw in TLS handshakes.
  final List<String> seenServerFingerprints = [];

  final Map<String?, HttpClient> _clients = {};

  String get serverFp => serverKey!.identity.fingerprint;

  /// Starts a server. [secure] false = plaintext profile (Inc 1/2 behaviour).
  static Future<P3Rig> start({
    bool secure = true,
    P3SecureHandler? handler,
    bool Function()? contactsOnly,
    bool enableRateLimit = false,
    RateLimiter? rateLimiter,
    KeyIdentity? serverKey,
    InMemoryTrustStore? trust,
    void Function(DeviceInfo, String)? onRegister,
    InternetAddress? bindAddress,
  }) async {
    final h = handler ?? P3SecureHandler();
    final t = trust ?? InMemoryTrustStore();
    final key = secure ? (serverKey ?? p3ServerKey) : null;
    final server = ApiServer(
      handler: h,
      security: secure
          ? SecurityConfig.tls(identity: key!, trust: t)
          : const SecurityConfig.plaintext(),
      contactsOnly: contactsOnly,
      bindAddress: bindAddress ?? InternetAddress.loopbackIPv4,
      preferredPort: 0,
      enableRateLimit: enableRateLimit,
      rateLimiter: rateLimiter,
      onRegister: onRegister,
    );
    final port = await server.start();
    return P3Rig._(
      server: server,
      handler: h,
      trust: t,
      serverKey: key,
      port: port,
      secure: secure,
    );
  }

  Future<void> stop() async {
    for (final c in _clients.values) {
      c.close(force: true);
    }
    _clients.clear();
    await server.stop(force: true);
  }

  HttpClient _client(String? from) => _clients.putIfAbsent(from, () {
    final c = HttpClient(context: secure ? buildClientContext() : null)
      ..badCertificateCallback = (cert, host, port) {
        seenServerFingerprints.add(fingerprintHex(cert.der));
        return true;
      };
    if (from != null) {
      // Same TLS handshake as the default path, but from another loopback source address.
      c.connectionFactory = (uri, proxyHost, proxyPort) async {
        final task = await Socket.startConnect(
          uri.host,
          uri.port,
          sourceAddress: InternetAddress(from),
        );
        if (!secure) return task;
        return ConnectionTask.fromSocket(
          task.socket.then<Socket>(
            (plain) => SecureSocket.secure(
              plain,
              host: uri.host,
              context: buildClientContext(),
              onBadCertificate: (cert) {
                seenServerFingerprints.add(fingerprintHex(cert.der));
                return true;
              },
            ),
          ),
          task.cancel,
        );
      };
    }
    return c;
  });

  /// A brand-new client (own connection pool): use it to prove server-wide state (nonce cache).
  void dropConnections() {
    for (final c in _clients.values) {
      c.close(force: true);
    }
    _clients.clear();
  }

  Uri uri(String path) => Uri.parse(
    '${secure ? 'https' : 'http'}://127.0.0.1:$port$kApiPrefix$path',
  );

  /// The `X-LS-Auth` value [who] would send for this request. [path] is relative to the API
  /// prefix and may carry a query. All fields can be bent for negative tests.
  String proof(
    P3Peer who,
    String method,
    String path,
    List<int> body, {
    DateTime? now,
    String? serverFp,
    Uint8List? nonce,
    String? signedMethod,
    String? signedPath,
    List<int>? signedBody,
  }) => buildAuthHeader(
    identity: who.key,
    method: signedMethod ?? method,
    pathAndQuery: signedPath ?? pathAndQueryOf(uri(path)),
    body: signedBody ?? body,
    serverFingerprint: serverFp ?? this.serverFp,
    now: now,
    nonce: nonce,
  );

  /// Sends one request. With [signAs] the correct proof for exactly this request is attached;
  /// [authHeader] attaches that literal value instead (for malformed or bent proofs).
  Future<P3Res> request(
    String method,
    String path, {
    Object? json,
    List<int>? body,
    Map<String, String> headers = const {},
    P3Peer? signAs,
    String? authHeader,
    bool chunked = false,
    String? from,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    var bytes = body;
    if (json != null) bytes = utf8.encode(jsonEncode(json));
    final req = await _client(from).openUrl(method, uri(path));
    headers.forEach(req.headers.set);
    if (json != null) req.headers.contentType = ContentType.json;
    final auth =
        authHeader ??
        (signAs == null ? null : proof(signAs, method, path, bytes ?? []));
    if (auth != null) req.headers.set(kAuthHeader, auth);
    if (bytes != null) {
      if (chunked) {
        req.headers.chunkedTransferEncoding = true;
      } else {
        req.contentLength = bytes.length;
      }
      req.add(bytes);
    }
    final resp = await req.close().timeout(timeout);
    final out = BytesBuilder(copy: false);
    await for (final part in resp.timeout(timeout)) {
      out.add(part);
    }
    final hs = <String, List<String>>{};
    resp.headers.forEach((k, v) => hs[k.toLowerCase()] = List.of(v));
    return P3Res(resp.statusCode, hs, out.takeBytes());
  }

  /// Convenience: the valid, signed `POST /sessions` of [who].
  Future<P3Res> postSession(
    P3Peer who, {
    List<int>? body,
    String? from,
    Map<String, String> headers = const {},
  }) => request(
    'POST',
    '/sessions',
    body: body ?? p3SessionBody(who),
    headers: {'content-type': 'application/json', ...headers},
    signAs: who,
    from: from,
  );
}

/// Shared, lazily created identities (each takes ~20 ms to generate).
final KeyIdentity p3ServerKey = KeyIdentity.fromGenerated(
  generateIdentityFor('ls-p3-server'),
);
final KeyIdentity p3OtherServerKey = KeyIdentity.fromGenerated(
  generateIdentityFor('ls-p3-other-server'),
);
final P3Peer p3Alice = P3Peer('ls-p3-alice');
final P3Peer p3Bob = P3Peer('ls-p3-bob');
final P3Peer p3Mallory = P3Peer('ls-p3-mallory');

/// Makes [who] a contact (`known` or `trusted`) of the rig's trust store.
Future<void> p3Pin(
  P3Rig rig,
  P3Peer who, {
  PeerTrust trust = PeerTrust.known,
}) => rig.trust.pin(
  deviceId: who.deviceId,
  fingerprint: who.fp,
  alias: who.deviceId,
  trust: trust,
);

// ------------------------------------------------------------------ raw TLS / TCP

/// A raw client connection that accumulates everything the server sends.
class P3Raw {
  P3Raw._(this.socket) {
    socket.listen(
      (d) => received.add(d),
      onDone: () {
        if (!_closed.isCompleted) _closed.complete();
      },
      onError: (Object _) {
        if (!_closed.isCompleted) _closed.complete();
      },
    );
  }

  final Socket socket;
  final BytesBuilder received = BytesBuilder(copy: false);
  final Completer<void> _closed = Completer<void>();

  /// Opens a TLS connection (any certificate accepted) to [port] on loopback.
  static Future<P3Raw> tls(int port) async {
    final s = await SecureSocket.connect(
      '127.0.0.1',
      port,
      context: buildClientContext(),
      onBadCertificate: (_) => true,
    );
    return P3Raw._(s);
  }

  /// Opens a plain TCP connection.
  static Future<P3Raw> plain(int port) async =>
      P3Raw._(await Socket.connect('127.0.0.1', port));

  void write(String s) => socket.add(utf8.encode(s));
  void writeBytes(List<int> b) => socket.add(b);

  bool get isClosed => _closed.isCompleted;

  /// Completes when the peer closed the connection; false on timeout.
  Future<bool> waitClosed([
    Duration timeout = const Duration(seconds: 5),
  ]) async {
    try {
      await _closed.future.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  /// Waits until the received text contains a complete HTTP response head (or the peer closed).
  Future<String> waitForHead([
    Duration timeout = const Duration(seconds: 10),
  ]) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      final t = text;
      if (t.contains('\r\n\r\n') || isClosed) return t;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return text;
  }

  String get text => utf8.decode(received.toBytes(), allowMalformed: true);

  int get statusCode {
    final m = RegExp(r'^HTTP/1\.[01] (\d{3})').firstMatch(text);
    return m == null ? -1 : int.parse(m.group(1)!);
  }

  void destroy() => socket.destroy();
}

// ------------------------------------------------------------------ log capture

/// Captures every `package:logging` record while active. Tests assert that no secret shows up.
class P3LogCapture {
  P3LogCapture() {
    _oldLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    _sub = Logger.root.onRecord.listen((r) {
      records.add('${r.loggerName}|${r.level}|${r.message}|${r.error}');
    });
  }

  final List<String> records = [];
  late final Level _oldLevel;
  late final StreamSubscription<LogRecord> _sub;

  String get all => records.join('\n');

  Future<void> close() async {
    await _sub.cancel();
    Logger.root.level = _oldLevel;
  }
}
