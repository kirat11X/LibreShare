/// LSP/1 REST server (spec §4.3) on `dart:io` [HttpServer] + shelf/shelf_router.
///
/// The server is deliberately thin: it parses/validates the wire format, maps
/// [LsException]s to the §4.3 error envelope and streams chunk bodies straight
/// into [IncomingTransferHandler.putChunk]. All protocol *state* lives in the
/// handler. Plain HTTP when no [SecurityContext] is given (Increment 1);
/// Increment 3 passes a context (and `requestClientCertificate`) for mTLS.
///
/// Nothing sensitive is ever logged: no tokens, PINs, request bodies or
/// unexpected-exception messages (only the exception type and stack trace).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import '../model/device.dart';
import '../model/ls_exception.dart';
import '../model/session_models.dart';
import '../model/transfer_status.dart';
import '../protocol.dart';
import '../security/cert_factory.dart' show parseCertificate;
import '../security/contracts.dart';
import '../security/crypto_primitives.dart' show b64urlDecode;
import '../security/identity_proof.dart';
import '../security/tls_context.dart';
import 'capped_server_socket.dart';
import 'incoming_transfer_handler.dart';
import 'rate_limiter.dart';

final Logger _log = Logger('libreshare.api_server');

/// Request-context key under which the TLS peer certificate
/// ([X509Certificate]?) is made available to shelf handlers (Increment 3).
const String kPeerCertificateContextKey = 'ls.peerCertificate';

/// Request-context key holding the remote IP address string.
const String kRemoteAddressContextKey = 'ls.remoteAddress';

/// Protocol majors this server speaks (`supported` in 426 responses).
const List<String> kSupportedMajors = ['1'];

/// Longest long-poll the server honours (spec §4.3 `wait=25`).
const int kMaxWaitSeconds = 25;

/// Hard cap on one chunk PUT body (chunks are 4 MiB; this leaves room for
/// negotiated sizes while stopping absurd uploads).
const int kMaxChunkBodyBytes = 64 * 1024 * 1024;

const String _bodyKey = 'ls.requestBody';
const Duration _jsonReadTimeout = Duration(seconds: 30);
const Duration _drainTimeout = Duration(seconds: 10);

/// Secure profile: how many bodies above [kMaxJsonBytes] may be read at once (LSP-1 4.3.4).
const int _maxConcurrentOversize = 2;

/// Fixed text of every proof failure: it must not say which check failed (LSP-1 4.3.6).
const String _authFailedMessage = 'Authentication failed';

final RegExp _sasCommitFormat = RegExp(r'^[A-Za-z0-9_-]{43}$');
final RegExp _tsFormat = RegExp(r'^(0|[1-9][0-9]{0,15})$');
final RegExp _pinShape = RegExp(r'^[0-9]{6}$');
final RegExp _sasNonceFormat = RegExp(r'^[A-Za-z0-9_-]{22}$');

/// How much unread request body we are willing to swallow so that an early
/// error response is delivered cleanly (and the connection can be reused).
/// dart:io destroys the socket right after the response when the body was not
/// fully read, which can lose the response itself; beyond this limit the
/// client simply sees the connection closed.
const int _drainBytes = 8 * 1024 * 1024;

class ApiServer {
  ApiServer({
    required this.handler,
    InternetAddress? bindAddress,
    this.preferredPort = kDefaultPort,
    this.securityContext,
    this.maxPortFallback = kPortFallbackMax,
    this.requestClientCertificate = false,
    this.security = const SecurityConfig.plaintext(),
    this.contactsOnly,
    this.enableRateLimit = true,
    this.bodyIdleTimeout = const Duration(seconds: 5),
    RateLimiter? rateLimiter,
    this.onRegister,
    this.maxConnections = 64,
    this.maxConnectionsPerIp = 16,
    this.tlsHandshakeTimeout = kDefaultHandshakeTimeout,
  }) : bindAddress = bindAddress ?? InternetAddress.anyIPv4,
       _rateLimiter = rateLimiter ?? RateLimiter() {
    if (security.isSecure && handler is! SecureTransferHandler) {
      throw ArgumentError(
        'The secure profile needs a SecureTransferHandler',
        'handler',
      );
    }
    _router = Router(notFoundHandler: _notFound)
      ..get('$kApiPrefix/info', _getInfo)
      ..post('$kApiPrefix/register', _postRegister)
      ..post('$kApiPrefix/sessions', _postSessions)
      ..get('$kApiPrefix/sessions/<sid>', _getSession)
      ..get('$kApiPrefix/sessions/<sid>/files/<fid>/state', _getFileState)
      ..put('$kApiPrefix/sessions/<sid>/files/<fid>/chunks/<idx>', _putChunk)
      ..post('$kApiPrefix/sessions/<sid>/files/<fid>/complete', _postComplete)
      ..post('$kApiPrefix/sessions/<sid>/finish', _postFinish)
      ..post('$kApiPrefix/sessions/<sid>/cancel', _postCancel);
    if (security.isSecure) {
      // Plaintext profile: these routes do not exist and fall under the 404 routing rule.
      _router
        ..post('$kApiPrefix/sessions/<sid>/sas', _postSas)
        ..post('$kApiPrefix/pair', _postPair);
    }
  }

  /// Business logic behind the HTTP layer.
  final IncomingTransferHandler handler;

  /// Secure profile (TLS 1.3 listener, signed-proof checks). When [SecurityConfig.isSecure] the
  /// [handler] must be a [SecureTransferHandler] (else [ArgumentError]). The legacy
  /// [securityContext] and [requestClientCertificate] parameters apply to the plaintext profile
  /// only.
  final SecurityConfig security;

  /// Evaluated per request: true = Contacts-only visibility, strangers get the plain 404.
  final bool Function()? contactsOnly;

  /// Most TCP connections open at once (accepted until closed; idle sockets, half-sent request
  /// heads and unfinished TLS handshakes count). Further ones are closed at once.
  final int maxConnections;

  /// Most open TCP connections of one remote address (same rule as [maxConnections]).
  final int maxConnectionsPerIp;

  /// A TLS handshake still unfinished after this long is dropped (frees its connection slot).
  final Duration tlsHandshakeTimeout;

  /// Interface to bind (default: all IPv4 interfaces).
  final InternetAddress bindAddress;

  /// First port to try; 0 means "any free port".
  final int preferredPort;

  /// Highest port to fall back to (FR-01: 53318 .. [kPortFallbackMax]).
  final int maxPortFallback;

  /// null => plain HTTP. Non-null => `HttpServer.bindSecure`.
  final SecurityContext? securityContext;

  /// Ask TLS clients for a certificate (mTLS, Increment 3). Only used when
  /// [securityContext] is set.
  final bool requestClientCertificate;

  /// Apply the per-IP `POST /sessions` limit (10/min). Tests that hammer one
  /// loopback address disable it.
  final bool enableRateLimit;

  /// Called for every valid `POST /register` with the announcing peer and the
  /// IP address the request came from (discovery records it as a peer). Must
  /// not throw; one that does is contained.
  final void Function(DeviceInfo peer, String remoteAddress)? onRegister;

  /// Secure profile: a request body read is aborted (400) after this long without a body byte,
  /// which frees its oversize slot. A steady slow upload is not affected.
  final Duration bodyIdleTimeout;

  final RateLimiter _rateLimiter;
  late final Router _router;

  bool get _secure => security.isSecure;

  /// Replay cache of the identity proofs, one per server (LSP-1 4.3.6 check 5).
  final NonceCache _nonces = NonceCache();

  /// Oversize bodies being read right now (secure profile).
  int _oversizeReads = 0;
  HttpServer? _server;

  /// Listener already closed by a graceful [stop]; connections may still be
  /// draining. Kept so a later `stop(force: true)` can escalate.
  HttpServer? _closing;
  CappedServerSocket? _listener;
  CappedServerSocket? _closingListener;

  int _inFlight = 0;
  Completer<void>? _drained;

  bool get isRunning => _server != null;

  /// The port actually bound. Throws [StateError] unless running.
  int get port {
    final s = _server;
    if (s == null) throw StateError('ApiServer is not running');
    return s.port;
  }

  /// Binds [preferredPort], falling back to +1 … [maxPortFallback] if it is in
  /// use (FR-01). Returns the bound port. Throws [SocketException] if no port
  /// in the range is free (or for non-"in use" bind errors).
  Future<int> start() async {
    if (_server != null) throw StateError('ApiServer already started');
    final last = preferredPort == 0
        ? 0
        : math.max(preferredPort, maxPortFallback);
    for (var p = preferredPort; ; p++) {
      try {
        final listener = await _bind(p);
        final HttpServer server;
        try {
          server = HttpServer.listenOn(listener);
        } on Object {
          await listener.close();
          rethrow;
        }
        _listener = listener;
        server.listen(
          _onRequest,
          onError: (Object e) =>
              _log.fine('Connection-level error: ${e.runtimeType}'),
        );
        _server = server;
        _log.info('Listening on ${server.address.address}:${server.port}');
        return server.port;
      } on SocketException catch (e) {
        if (!_isAddressInUse(e)) rethrow;
        if (p >= last) {
          throw SocketException(
            'No free port in $preferredPort..$last '
            '(${e.osError?.message ?? e.message})',
            osError: e.osError,
          );
        }
        _log.fine('Port $p in use, trying ${p + 1}');
      }
    }
  }

  /// Stops listening. A graceful stop (default) closes the listener and then
  /// waits until every in-flight request has had its response fully written
  /// (so e.g. the reply to `POST /finish` is never cut off). It can wait as
  /// long as the slowest long-poll (≤ 25 s); callers wanting a bound call
  /// `stop(force: true)` — a second, forced call escalates a pending graceful
  /// stop and drops open connections immediately.
  Future<void> stop({bool force = false}) async {
    final running = _server;
    if (running != null) {
      _server = null;
      _closing = running;
      _closingListener = _listener;
      _listener = null;
    }
    final s = running ?? _closing;
    if (s == null) return;
    final listener = _closingListener;
    if (force) {
      await s.close(force: true);
      await listener?.close();
      listener?.destroyAll();
      return;
    }
    await s.close();
    await listener?.close();
    if (_inFlight > 0) {
      await (_drained ??= Completer<void>()).future;
    }
  }

  void _requestStarted() => _inFlight++;

  void _requestEnded() {
    if (_inFlight > 0) _inFlight--;
    if (_inFlight == 0) {
      final d = _drained;
      _drained = null;
      if (d != null && !d.isCompleted) d.complete();
    }
  }

  Future<CappedServerSocket> _bind(int port) {
    // Every profile goes through the connection-capped listener; TLS is applied per socket there.
    final SecurityContext? ctx = _secure
        // TLS 1.3 only, the device identity certificate, no client certificate requested.
        ? buildServerContext(security.identity!)
        : securityContext;
    return CappedServerSocket.bind(
      bindAddress,
      port,
      maxConnections: maxConnections,
      maxConnectionsPerIp: maxConnectionsPerIp,
      handshakeTimeout: tlsHandshakeTimeout,
      securityContext: ctx,
      requestClientCertificate: !_secure && requestClientCertificate,
    );
  }

  static bool _isAddressInUse(SocketException e) {
    final code = e.osError?.errorCode;
    // EADDRINUSE: Linux 98, macOS/BSD 48, Windows WSAEADDRINUSE 10048.
    if (code == 98 || code == 48 || code == 10048) return true;
    final text = '${e.message} ${e.osError?.message ?? ''}'.toLowerCase();
    // The VM reports a second bind of the same address:port *inside this
    // process* (e.g. two engines in one test) with errorCode -1 and this text.
    return text.contains('in use') || text.contains('shared flag');
  }

  // ---------------------------------------------------------------- plumbing

  void _onRequest(HttpRequest http) {
    try {
      // Same checks shelf's Request constructor makes; shelf_io would answer
      // an unparsable URL with a text/plain 400 (and log to stderr).
      final uri = http.requestedUri;
      // shelf refuses a request URL with a fragment ("#") or a relative one.
      if (uri.hasFragment || !uri.isAbsolute) throw const FormatException();
      uri.pathSegments;
      uri.queryParametersAll;
    } on Object {
      unawaited(_rejectMalformedUrl(http));
      return;
    }
    final body = _RequestBody(http);
    final remote = http.connectionInfo?.remoteAddress.address ?? 'unknown';
    _requestStarted();
    unawaited(
      http.response.done
          .then<void>((_) {}, onError: (Object _) {})
          .whenComplete(_requestEnded),
    );
    // shelf_io writes the response (and logs/500s anything that escapes).
    unawaited(
      shelf_io.handleRequest(http, (Request incoming) async {
        final request = incoming.change(
          context: {
            _bodyKey: body,
            kRemoteAddressContextKey: remote,
            kPeerCertificateContextKey: http.certificate,
          },
        );
        Response response;
        try {
          response = await _dispatch(request);
        } on LsException catch (e) {
          response = _errorResponse(e);
        } on _Throttled catch (e) {
          response = _errorResponse(e.error, headers: e.headers);
        } on Object catch (e, st) {
          response = _unexpected(request, body, e, st);
        }
        if (_secure) {
          // The client corrects its clock from this after a stale proof (LSP-1 4.3.6).
          response = response.change(
            headers: {HttpHeaders.dateHeader: HttpDate.format(DateTime.now())},
          );
        }
        // Swallow whatever request body is left so the response is delivered
        // cleanly and the keep-alive connection stays usable.
        await body.finish();
        return response;
      }, poweredByHeader: null),
    );
  }

  Future<void> _rejectMalformedUrl(HttpRequest http) async {
    final e = LsException(LsErrorCode.badRequest, 'Malformed URL');
    final res = http.response..statusCode = e.httpStatus;
    if (_secure) {
      res.headers.set(HttpHeaders.dateHeader, HttpDate.format(DateTime.now()));
    }
    res
      ..headers.contentType = ContentType(
        'application',
        'json',
        charset: 'utf-8',
      )
      ..write(jsonEncode(e.toEnvelope()));
    try {
      await res.close();
    } on Object {
      // peer already gone
    }
  }

  Future<Response> _dispatch(Request request) async {
    if (_secure && _contactsOnlyNow() && _isGated(request)) {
      // Contacts-only gate (LSP-1 5.4): before the rate limit, before any body byte is read.
      if (!_presentsContactCertificate(request.headers[kAuthHeader])) {
        return _notFound(request);
      }
    }
    return await _router(request);
  }

  /// Evaluated per request. A callback that fails counts as Contacts-only (fail closed).
  bool _contactsOnlyNow() {
    try {
      return contactsOnly?.call() ?? false;
    } on Object {
      return true;
    }
  }

  /// The routes hidden from strangers by Contacts-only visibility. `/pair` is exempt (the invite
  /// secret authenticates it) and so are the session and file routes (session id, file token).
  bool _isGated(Request r) {
    final path = r.requestedUri.path;
    return switch (r.method) {
      'GET' => path == '$kApiPrefix/info',
      'POST' =>
        path == '$kApiPrefix/register' || path == '$kApiPrefix/sessions',
      _ => false,
    };
  }

  /// True when [header] is well formed enough to name a certificate whose fingerprint is a
  /// contact (known or trusted; unknown, blocked and key-changed peers are strangers). This does
  /// not verify the proof: that follows in the route.
  bool _presentsContactCertificate(String? header) {
    if (header == null || header.length > kMaxAuthHeaderBytes) return false;
    final parts = header.split('.');
    if (parts.length != 5 || parts[0] != kAuthVersion) return false;
    try {
      // Well formed = the grammar of 4.3.6 (the signature is checked later, by the route).
      if (!_tsFormat.hasMatch(parts[2]) ||
          parts[3].length != 22 ||
          parts[4].length != 86 ||
          b64urlDecode(parts[3]).length != 16 ||
          b64urlDecode(parts[4]).length != 64) {
        return false;
      }
      final fp = parseCertificate(b64urlDecode(parts[1])).fingerprint;
      final trust = security.trust!.classifyFingerprint(fp).trust;
      return trust == PeerTrust.known || trust == PeerTrust.trusted;
    } on Object {
      return false;
    }
  }

  Response _unexpected(
    Request request,
    _RequestBody body,
    Object e,
    StackTrace st,
  ) {
    if (body.upstreamError != null) {
      // The client went away mid-upload; nothing is wrong on our side.
      _log.fine('Request aborted by peer: ${body.upstreamError.runtimeType}');
      return _errorResponse(
        LsException(LsErrorCode.badRequest, 'Request body interrupted'),
      );
    }
    // Only the type: exception messages may embed paths or secrets.
    _log.severe(
      'Unhandled ${e.runtimeType} serving ${request.method} route',
      null,
      st,
    );
    return _errorResponse(LsException(LsErrorCode.internal, 'Internal error'));
  }

  Response _notFound(Request request) =>
      _errorResponse(LsException(LsErrorCode.notFound, 'No such route'));

  static const Map<String, String> _jsonHeaders = {
    HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
    HttpHeaders.cacheControlHeader: 'no-store',
  };

  Response _json(int status, Object? body, [Map<String, String>? extra]) =>
      Response(
        status,
        body: jsonEncode(body),
        headers: {..._jsonHeaders, ...?extra},
      );

  Response _errorResponse(LsException e, {Map<String, String>? headers}) {
    final envelope = e.toEnvelope();
    if (e.code == LsErrorCode.upgradeRequired) {
      envelope['supported'] = kSupportedMajors;
    }
    final wait = e.retryAfter;
    return _json(e.httpStatus, envelope, {
      if (wait != null)
        HttpHeaders.retryAfterHeader: '${_retryAfterSeconds(wait)}',
      ...?headers,
    });
  }

  /// Whole seconds, rounded up, at least 1.
  static int _retryAfterSeconds(Duration d) =>
      math.max(1, (d.inMilliseconds / 1000).ceil());

  // ------------------------------------------------------------------ helpers

  static _RequestBody _bodyOf(Request r) =>
      r.context[_bodyKey]! as _RequestBody;

  static String _remoteOf(Request r) =>
      (r.context[kRemoteAddressContextKey] as String?) ?? 'unknown';

  /// Reads (≤ [kMaxJsonBytes]) the body and decodes it as a JSON object.
  Future<Map<String, Object?>> _readJsonObject(Request r) async {
    final bytes = await _bodyOf(r).readLimited(kMaxJsonBytes);
    if (bytes.isEmpty) {
      throw LsException(LsErrorCode.badRequest, 'JSON body required');
    }
    return _decodeObject(bytes);
  }

  static Map<String, Object?> _decodeObject(List<int> bytes) {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw LsException(LsErrorCode.badRequest, 'Malformed JSON');
    }
    if (decoded is! Map) {
      throw LsException(LsErrorCode.badRequest, 'JSON object expected');
    }
    return decoded.cast<String, Object?>();
  }

  /// Rejects an unknown protocol major (spec §4.6) with 426.
  static void _checkMajor(Object? v) {
    if (v == null) return;
    if (v is! String) {
      throw LsException(LsErrorCode.badRequest, "'v' must be a string");
    }
    final major = v.split('.').first;
    if (!kSupportedMajors.contains(major)) {
      throw LsException(
        LsErrorCode.upgradeRequired,
        'Unsupported protocol version',
      );
    }
  }

  /// Runs a model parser; wire-shape problems become 400. The re-encode forces
  /// the models' lazy list casts so bad element types fail here, not later
  /// inside the handler.
  static T _parse<T>(T Function() parse, Object? Function(T) toJson) {
    try {
      final value = parse();
      jsonEncode(toJson(value));
      return value;
    } on TypeError {
      throw LsException(LsErrorCode.badRequest, 'Invalid request structure');
    } on FormatException {
      throw LsException(LsErrorCode.badRequest, 'Invalid request value');
    }
  }

  static void _validateSessionRequest(
    SessionRequest req, {
    bool securePin = false,
  }) {
    // LSP-1 5.2: a present pin must be 6 ASCII digits; anything else is a shape error (never a
    // strike, never seen by the PIN verifier). The text is fixed and never echoes the value.
    final pin = req.pin;
    if (securePin && pin != null && !_pinShape.hasMatch(pin)) {
      throw LsException(LsErrorCode.badRequest, 'pin must be 6 digits');
    }
    if (req.chunkSize <= 0) {
      throw LsException(LsErrorCode.badRequest, 'chunkSize must be positive');
    }
    var sum = 0;
    for (final f in req.files) {
      if (f.size < 0 || f.chunkCount < 0) {
        throw LsException(
          LsErrorCode.badRequest,
          'File sizes and chunk counts must be >= 0',
        );
      }
      sum += f.size;
    }
    if (req.totalSize < 0 || sum != req.totalSize) {
      throw LsException(
        LsErrorCode.badRequest,
        'totalSize must equal the sum of file sizes',
      );
    }
  }

  /// Decodes and sanity-checks a `{sid}` / `{fid}` path parameter. ids are
  /// opaque to the server, but handlers may use them as map keys or file name
  /// parts, so path separators and control characters never get through.
  static String _id(String raw) {
    final String id;
    try {
      id = Uri.decodeComponent(raw);
    } on Object {
      throw LsException(LsErrorCode.badRequest, 'Malformed identifier');
    }
    if (id.isEmpty ||
        id.length > 128 ||
        id == '.' ||
        id == '..' ||
        id.runes.any((c) => c < 0x20 || c == 0x7f || c == 0x2f || c == 0x5c)) {
      throw LsException(LsErrorCode.badRequest, 'Invalid identifier');
    }
    return id;
  }

  /// `Authorization: Bearer <token>` (scheme case-insensitive).
  static String _bearer(Request r) {
    final header = r.headers[HttpHeaders.authorizationHeader];
    if (header != null) {
      final space = header.indexOf(' ');
      if (space > 0 && header.substring(0, space).toLowerCase() == 'bearer') {
        final token = header.substring(space + 1).trim();
        if (token.isNotEmpty && token.length <= 512) return token;
      }
    }
    throw LsException(LsErrorCode.tokenInvalid, 'Bearer token required');
  }

  static final RegExp _hex64 = RegExp(r'^[0-9a-fA-F]{64}$');
  // int.tryParse also accepts hex ("0x10") and surrounding whitespace.
  static final RegExp _decimal = RegExp(r'^-?[0-9]{1,18}$');

  static int? _strictInt(String raw) =>
      _decimal.hasMatch(raw) ? int.parse(raw) : null;

  static String _hex(Object? v, String what) {
    if (v is String && _hex64.hasMatch(v)) return v.toLowerCase();
    throw LsException(LsErrorCode.badRequest, '$what must be 64 hex digits');
  }

  // ----------------------------------------------------- secure profile helpers

  /// Reads a JSON body for the secure profile. Routes allowed more than [kMaxJsonBytes] pass
  /// [cap]; such a body needs a `Content-Length` (without one it is cut off at [kMaxJsonBytes])
  /// and at most [_maxConcurrentOversize] of them are read at the same time.
  Future<Uint8List> _readSecureBody(Request r, int cap) async {
    final body = _bodyOf(r);
    final declared = body.declaredLength;
    final oversize = declared > kMaxJsonBytes && declared <= cap;
    if (!oversize) {
      // A declared length above [cap] is refused with 413 without reading anything.
      return body.readLimited(
        declared < 0 ? kMaxJsonBytes : cap,
        idle: bodyIdleTimeout,
      );
    }
    if (_oversizeReads >= _maxConcurrentOversize) {
      throw _Throttled(
        LsException(LsErrorCode.rateLimited, 'Too many large requests'),
        retryAfterSeconds: 5,
      );
    }
    _oversizeReads++;
    try {
      return await body.readLimited(cap, idle: bodyIdleTimeout);
    } finally {
      _oversizeReads--;
    }
  }

  /// Verifies the `X-LS-Auth` proof against the request as received. Null when it fails.
  AuthenticatedPeer? _verifyProof(Request r, List<int> body) {
    final result = verifyAuthHeader(
      header: r.headers[kAuthHeader],
      method: r.method,
      pathAndQuery: pathAndQueryOf(r.requestedUri),
      body: body,
      ownFingerprint: security.identity!.identity.fingerprint,
      now: DateTime.now(),
      nonces: _nonces,
    );
    return result is AuthOk ? result.peer : null;
  }

  static LsException _authInvalid() =>
      LsException(LsErrorCode.authInvalid, _authFailedMessage);

  /// Secure profile: read the body (see [_readSecureBody]), then require a valid proof.
  Future<(Uint8List, AuthenticatedPeer)> _readAuthenticated(
    Request r, {
    int cap = kMaxJsonBytes,
  }) async {
    final bytes = await _readSecureBody(r, cap);
    final peer = _verifyProof(r, bytes);
    if (peer == null) throw _authInvalid();
    return (bytes, peer);
  }

  Response _rateLimitedResponse(String remote) {
    final wait = _rateLimiter.retryAfter(remote);
    return _errorResponse(
      LsException(LsErrorCode.rateLimited, 'Too many session requests'),
      headers: {
        HttpHeaders.retryAfterHeader: '${math.max(1, wait.inSeconds + 1)}',
      },
    );
  }

  SecureTransferHandler get _secureHandler => handler as SecureTransferHandler;

  // ------------------------------------------------------------------- routes

  Future<Response> _getInfo(Request r) async {
    if (_secure && _contactsOnlyNow()) {
      // Contacts-only: a contact is served after the full verification, and every failure of it
      // is the plain 404 (LSP-1 4.3.6).
      final bytes = await _readSecureBody(r, kMaxJsonBytes);
      if (_verifyProof(r, bytes) == null) return _notFound(r);
    }
    return _json(200, handler.deviceInfo.toJson());
  }

  Future<Response> _postRegister(Request r) async {
    AuthenticatedPeer? proven;
    final Map<String, Object?> map;
    if (_secure) {
      final (bytes, authenticated) = await _readAuthenticated(r);
      proven = authenticated;
      map = _decodeObject(bytes);
    } else {
      map = await _readJsonObject(r);
    }
    _checkMajor(map['v']);
    final peer = _parse(() => DeviceInfo.fromJson(map), (d) => d.toJson());
    // The registrant's own fingerprint, when it states one, must be the key that signed.
    if (proven != null &&
        peer.fingerprint.isNotEmpty &&
        peer.fingerprint.toUpperCase() != proven.fingerprint) {
      throw _authInvalid();
    }
    final hook = onRegister;
    if (hook != null) {
      try {
        hook(peer, _remoteOf(r));
      } on Object catch (e) {
        _log.fine('onRegister hook failed: ${e.runtimeType}');
      }
    }
    return _json(200, handler.register(peer).toJson());
  }

  Future<Response> _postSessions(Request r) async {
    final remote = _remoteOf(r);
    if (enableRateLimit && !_rateLimiter.tryAcquire(remote)) {
      return _rateLimitedResponse(remote);
    }
    AuthenticatedPeer? proven;
    final Map<String, Object?> map;
    if (_secure) {
      final (bytes, authenticated) = await _readAuthenticated(
        r,
        cap: kMaxSessionJsonBytes,
      );
      proven = authenticated;
      map = _decodeObject(bytes);
      final files = map['files'];
      if (files is List && files.length > kMaxFilesPerSession) {
        throw LsException(LsErrorCode.tooLarge, 'Too many files');
      }
    } else {
      map = await _readJsonObject(r);
    }
    final sender = map['sender'];
    if (sender is Map) _checkMajor(sender['v']);
    final commit = map['sasCommit'];
    if (_secure &&
        commit != null &&
        (commit is! String || !_sasCommitFormat.hasMatch(commit))) {
      throw LsException(LsErrorCode.badRequest, 'Invalid sasCommit');
    }
    final request = _parse(
      () => SessionRequest.fromJson(map),
      (s) => s.toJson(),
    );
    _validateSessionRequest(request, securePin: _secure);
    final status = _secure
        ? await _secureHandler.createAuthenticatedSession(
            request,
            remoteAddress: remote,
            peer: proven,
          )
        : await handler.createSession(request, remoteAddress: remote);
    return _json(
      status.status == TransferStatus.pending ? 202 : 200,
      status.toJson(),
    );
  }

  Future<Response> _getSession(Request r, String rawSid) async {
    final sid = _id(rawSid);
    final wait = _parseWait(r);
    final status = await handler.getSession(sid, wait: wait);
    if (status.status == TransferStatus.failed &&
        status.failureReason == FailureReason.cancelled) {
      throw LsException(LsErrorCode.cancelled, 'Session was cancelled');
    }
    return _json(200, status.toJson());
  }

  static Duration _parseWait(Request r) {
    final String? raw;
    try {
      raw = r.url.queryParameters['wait'];
    } on Object {
      throw LsException(LsErrorCode.badRequest, 'Malformed query string');
    }
    if (raw == null) return Duration.zero;
    final secs = _strictInt(raw);
    if (secs == null) {
      throw LsException(LsErrorCode.badRequest, "'wait' must be an integer");
    }
    return Duration(seconds: secs.clamp(0, kMaxWaitSeconds));
  }

  Future<Response> _getFileState(
    Request r,
    String rawSid,
    String rawFid,
  ) async {
    final sid = _id(rawSid);
    final fid = _id(rawFid);
    final token = _bearer(r);
    final state = await handler.fileState(sid, fid, token: token);
    return _json(200, state.toJson());
  }

  Future<Response> _putChunk(
    Request r,
    String rawSid,
    String rawFid,
    String idxRaw,
  ) async {
    final sid = _id(rawSid);
    final fid = _id(rawFid);
    final token = _bearer(r);
    final index = _strictInt(idxRaw);
    if (index == null) {
      throw LsException(
        LsErrorCode.badRequest,
        'Chunk index must be an integer',
      );
    }
    if (index < 0) {
      throw LsException(LsErrorCode.outOfRange, 'Chunk index out of range');
    }
    final hashHeader = r.headers[kChunkHashHeader];
    final sha = hashHeader == null
        ? null
        : _hex(hashHeader.trim(), kChunkHashHeader);
    if (_secure && sha == null) {
      throw LsException(LsErrorCode.badRequest, 'Chunk hash header required');
    }
    final body = _bodyOf(r);
    final length = body.declaredLength;
    if (length < 0) {
      throw LsException(LsErrorCode.badRequest, 'Content-Length required');
    }
    if (length > kMaxChunkBodyBytes) {
      throw LsException(LsErrorCode.tooLarge, 'Chunk body too large');
    }
    await handler.putChunk(
      sid,
      fid,
      index,
      body.open(),
      token: token,
      chunkSha256: sha,
    );
    return _json(200, {'ack': true, 'index': index});
  }

  Future<Response> _postComplete(
    Request r,
    String rawSid,
    String rawFid,
  ) async {
    final sid = _id(rawSid);
    final fid = _id(rawFid);
    final token = _bearer(r);
    final bytes = await _bodyOf(r).readLimited(kMaxJsonBytes);
    String? sha;
    if (bytes.isNotEmpty) {
      final raw = _decodeObject(bytes)['sha256'];
      if (raw != null) sha = _hex(raw, 'sha256');
    }
    final result = await handler.completeFile(
      sid,
      fid,
      token: token,
      sha256: sha,
    );
    return _json(200, result.toJson());
  }

  Future<Response> _postFinish(Request r, String rawSid) async {
    final status = await handler.finish(_id(rawSid));
    return _json(200, status.toJson());
  }

  Future<Response> _postCancel(Request r, String rawSid) async {
    await handler.cancel(_id(rawSid));
    return _json(200, {'cancelled': true});
  }

  /// `POST /sessions/{sid}/sas` (secure profile): the sender reveals its SAS nonce.
  Future<Response> _postSas(Request r, String rawSid) async {
    final sid = _id(rawSid);
    final (bytes, peer) = await _readAuthenticated(r);
    final nonce = _decodeObject(bytes)['nonce'];
    if (nonce is! String || !_sasNonceFormat.hasMatch(nonce)) {
      throw LsException(LsErrorCode.badRequest, 'Invalid nonce');
    }
    final status = await _secureHandler.revealSas(
      sid,
      nonce: nonce,
      peer: peer,
    );
    return _json(200, status.toJson());
  }

  /// `POST /pair` (secure profile): rate limit (shared bucket), size, proof, shape, version.
  /// The `sender.fingerprint` and `mac` checks belong to the handler.
  Future<Response> _postPair(Request r) async {
    final remote = _remoteOf(r);
    if (enableRateLimit && !_rateLimiter.tryAcquire(remote)) {
      return _rateLimitedResponse(remote);
    }
    final (bytes, peer) = await _readAuthenticated(r);
    final map = _decodeObject(bytes);
    final sender = map['sender'];
    if (sender is Map) _checkMajor(sender['v']);
    final request = _parse(() => PairRequest.fromJson(map), (p) => p.toJson());
    final response = await _secureHandler.pair(
      request,
      remoteAddress: remote,
      peer: peer,
    );
    return _json(200, response.toJson());
  }
}

/// Owns the one subscription to the underlying request body. It lets the
/// handler stream the body with backpressure, lets us bound JSON reads, and
/// guarantees the remainder is drained (bounded) even when the handler stops
/// early, so error responses are delivered cleanly.
class _RequestBody {
  _RequestBody(this._http);

  final HttpRequest _http;
  StreamSubscription<Uint8List>? _sub;
  StreamController<List<int>>? _out;
  void Function(Uint8List)? _sink;
  final Completer<void> _finished = Completer<void>();
  bool _claimed = false;
  bool _consumerGone = false;
  int _discarded = 0;
  int _drainLimit = _drainBytes;

  /// Set when the transport failed while we were reading.
  Object? upstreamError;

  /// Declared Content-Length, or -1 (chunked / absent).
  int get declaredLength => _http.contentLength;

  void _claim() {
    if (_claimed) throw StateError('Request body already consumed');
    _claimed = true;
  }

  /// The raw body as a single-subscription stream with backpressure.
  Stream<List<int>> open() {
    _claim();
    _drainLimit = kMaxChunkBodyBytes;
    final out = StreamController<List<int>>(
      onListen: () {
        _sink = _forward;
        _subscribe();
      },
      onPause: () {
        if (!_consumerGone) _sub?.pause();
      },
      onResume: () => _sub?.resume(),
      onCancel: () {
        // Handler stopped reading: keep draining (bounded) in the background.
        _consumerGone = true;
        _sub?.resume();
      },
    );
    _out = out;
    return out.stream;
  }

  void _forward(Uint8List chunk) => _out!.add(chunk);

  /// Reads at most [limit] bytes; throws 413 beyond that (while reading).
  Future<Uint8List> readLimited(int limit, {Duration? idle}) async {
    _claim();
    final declared = _http.contentLength;
    if (declared > limit) {
      throw LsException(LsErrorCode.tooLarge, 'Request body too large');
    }
    final builder = BytesBuilder(copy: false);
    var total = 0;
    var overflow = false;
    var idled = false;
    Timer? idleTimer;
    void arm() {
      if (idle == null) return;
      idleTimer?.cancel();
      idleTimer = Timer(idle, () {
        idled = true;
        _abandon();
      });
    }

    _sink = (chunk) {
      arm();
      total += chunk.length;
      if (total > limit) {
        overflow = true;
        builder.clear();
        _consumerGone = true; // discard (bounded) the rest
        _discarded = total;
        return;
      }
      builder.add(chunk);
    };
    arm();
    _subscribe();
    try {
      await _finished.future.timeout(
        _jsonReadTimeout,
        onTimeout: () {
          _abandon();
          throw LsException(LsErrorCode.badRequest, 'Request body timed out');
        },
      );
    } finally {
      idleTimer?.cancel();
    }
    if (idled) {
      throw LsException(LsErrorCode.badRequest, 'Request body timed out');
    }
    if (upstreamError != null) {
      Error.throwWithStackTrace(upstreamError!, StackTrace.current);
    }
    if (overflow) {
      throw LsException(LsErrorCode.tooLarge, 'Request body too large');
    }
    return builder.takeBytes();
  }

  /// Called after the response is ready: discard whatever is still unread.
  ///
  /// dart:io drains an unread body without any bound before it writes a
  /// response, and destroys the socket *without flushing* when it was not read
  /// completely. So we always subscribe (which disables its drain), swallow a
  /// bounded amount, and otherwise just pause: the response then flushes and
  /// dart:io closes the connection.
  Future<void> finish() async {
    _consumerGone = true;
    if (_finished.isCompleted) return;
    final declared = _http.contentLength;
    if (_sub == null) {
      if (declared == 0) return;
      _subscribe();
      if (declared > _drainLimit) {
        _abandon();
        return;
      }
    } else {
      _sub!.resume();
    }
    try {
      await _finished.future.timeout(_drainTimeout);
    } on TimeoutException {
      _abandon();
    }
  }

  /// Stop reading without cancelling (cancelling would lose the response).
  void _abandon() {
    _sub?.pause();
    _complete();
  }

  void _subscribe() {
    _sub = _http.listen(
      _onData,
      onError: (Object e, StackTrace st) {
        upstreamError = e;
        _out?.addError(e, st);
        _complete();
      },
      onDone: _complete,
      cancelOnError: true,
    );
  }

  void _onData(Uint8List chunk) {
    if (_consumerGone) {
      _discarded += chunk.length;
      if (_discarded > _drainLimit) {
        // Not worth reading further; the connection will be dropped.
        _abandon();
      }
      return;
    }
    _sink!(chunk);
  }

  void _complete() {
    final out = _out;
    if (out != null && !out.isClosed) unawaited(out.close());
    if (!_finished.isCompleted) _finished.complete();
  }
}

/// An [LsException] answered with a fixed `Retry-After`.
class _Throttled implements Exception {
  _Throttled(this.error, {required int retryAfterSeconds})
    : headers = {HttpHeaders.retryAfterHeader: '$retryAfterSeconds'};
  final LsException error;
  final Map<String, String> headers;
}
