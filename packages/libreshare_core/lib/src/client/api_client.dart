/// HTTP[S] implementation of [PeerClient] on `dart:io` [HttpClient] (spec §3,
/// §4.3). Connections are pooled and reused; chunk uploads are streamed with
/// an explicit Content-Length (never buffered).
///
/// Error contract (see [PeerClient]): every non-2xx response is turned into an
/// [LsException] from the §4.3 error envelope (non-JSON bodies map to
/// [LsErrorCode.internal]); transport failures surface as [SocketException] /
/// [TimeoutException] / TLS exceptions, unwrapped. dart:io's [HttpException]
/// (connection closed before a full response) is reported as a
/// [SocketException] so callers have a single transport-error type.
///
/// Never logs tokens, PINs or bodies.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../model/device.dart';
import '../model/ls_exception.dart';
import '../model/session_models.dart';
import '../protocol.dart';
import '../security/contracts.dart';
import '../security/crypto_primitives.dart' show fingerprintHex;
import '../security/identity_proof.dart';
import '../security/tls_context.dart';
import 'peer_client.dart';
import 'peer_security_exceptions.dart';

/// Largest response body we will buffer (a SessionStatus for 10,000 files is
/// roughly 1 MB; this is a safety net against a hostile peer).
const int _maxResponseBytes = 16 * 1024 * 1024;

class ApiClient implements SecurePeerClient {
  ApiClient({
    required this.host,
    required this.port,
    this.https = false,
    this.security = const SecurityConfig.plaintext(),
    this.expectedFingerprint,
    SecurityContext? securityContext,
    bool Function(X509Certificate cert, String host, int port)?
    badCertificateCallback,
    this.connectTimeout = const Duration(seconds: 3),
    this.requestTimeout = const Duration(seconds: 30),
  }) : _http = HttpClient(
         // The secure profile trusts no root: every certificate reaches the pin check below.
         context: security.isSecure ? buildClientContext() : securityContext,
       ) {
    if (security.isSecure) {
      final pin = expectedFingerprint;
      if (pin != null && !_fp64.hasMatch(pin)) {
        // Never degrade a malformed pin to "first contact".
        throw ArgumentError.value('not a fingerprint', 'expectedFingerprint');
      }
      _pin = pin?.toUpperCase();
      _http.badCertificateCallback = (cert, host, port) =>
          _checkCertificate(cert);
    } else if (badCertificateCallback != null) {
      _http.badCertificateCallback = badCertificateCallback;
    }
    _http
      ..connectionTimeout = connectTimeout
      // Peers live on the LAN: never route through an environment proxy.
      ..findProxy = ((_) => 'DIRECT')
      ..userAgent = 'LibreShare/$kProtocolVersion';
  }

  final String host;
  final int port;
  final bool https;

  /// Secure profile: TLS 1.3 with the server pinned, signed requests (P5 implements; Inc 3).
  final SecurityConfig security;

  /// Fingerprint the server must present (uppercase hex SHA-256 of its certificate). Null in the
  /// secure profile = first contact: any certificate is accepted for the handshake, its
  /// fingerprint is exposed as [serverFingerprint] and the caller must run the SAS flow.
  final String? expectedFingerprint;

  /// The pin, normalised to uppercase (null = plaintext profile or first contact).
  String? _pin;

  /// Fingerprint of the server certificate seen in the handshake. Every connection of this
  /// client is checked against the pin, or against the first certificate seen (first contact),
  /// so it is the fingerprint of the connection a request travels on.
  String? _seenFp;

  /// Set by the certificate callback when it refused a certificate; consumed by the handshake
  /// failure it caused.
  PeerFingerprintMismatchException? _mismatch;

  Uint8List? _seenDer;

  /// DER of the server certificate presented in the handshake (the one [serverFingerprint]
  /// hashes); null before the first TLS connection or in the plaintext profile. Public data,
  /// never logged.
  Uint8List? get serverCertificateDer => security.isSecure ? _seenDer : null;

  /// Server clock minus local clock, learnt from a `Date` header after a stale-proof refusal.
  Duration _skew = Duration.zero;

  static final RegExp _fp64 = RegExp(r'^[0-9A-Fa-f]{64}$');

  /// Decides whether the handshake may continue (called by dart:io for every new connection,
  /// before any HTTP byte is written).
  bool _checkCertificate(X509Certificate cert) {
    final presented = fingerprintHex(cert.der);
    final required = _pin ?? _seenFp;
    if (required == null) {
      // First contact: accept for the handshake, remember it, the SAS flow authenticates.
      _seenFp = presented;
      _seenDer = Uint8List.fromList(cert.der);
      return true;
    }
    if (certificateMatchesPin(cert, required)) {
      _seenFp = required;
      _seenDer = Uint8List.fromList(cert.der);
      return true;
    }
    _mismatch = PeerFingerprintMismatchException(
      shortFp(required),
      shortFp(presented),
    );
    return false;
  }

  // --- SecurePeerClient ---
  @override
  String? get serverFingerprint => security.isSecure ? _seenFp : null;

  @override
  Future<SessionStatus> revealSas(
    String sessionId, {
    required String nonce,
  }) async => _model(
    await _send(
      'POST',
      ['sessions', sessionId, 'sas'],
      json: {'nonce': nonce},
      proof: true,
    ),
    SessionStatus.fromJson,
  );

  @override
  Future<PairResponse> pair(PairRequest request) async => _model(
    await _send('POST', const ['pair'], json: request.toJson(), proof: true),
    PairResponse.fromJson,
  );

  /// Per-candidate connect timeout (spec §6: 3 s).
  final Duration connectTimeout;

  /// Whole-request timeout for ordinary calls (long-poll and chunk PUT adapt
  /// it, see [longPollTimeout]).
  final Duration requestTimeout;

  final HttpClient _http;

  /// Request timeout used for `GET /sessions/{sid}?wait=N`: the server holds
  /// the request for up to N seconds, so allow N + 10 s.
  @visibleForTesting
  static Duration longPollTimeout(int waitSeconds) =>
      Duration(seconds: (waitSeconds < 0 ? 0 : waitSeconds) + 10);

  // --------------------------------------------------------------- PeerClient

  @override
  Future<DeviceInfo> info() async {
    // A proof goes only to a peer that is already authenticated by its pin (LSP-1 4.3.6).
    final info = _model(
      await _send('GET', const ['info'], proof: _pin != null),
      DeviceInfo.fromJson,
    );
    if (security.isSecure) _checkInfoFingerprint(info);
    return info;
  }

  /// `/info.fingerprint` must be the hash of the certificate this connection presented.
  void _checkInfoFingerprint(DeviceInfo info) {
    final claimed = info.fingerprint;
    final seen = _seenFp;
    if (claimed.isEmpty || seen == null) throw const InsecurePeerException();
    if (claimed.toUpperCase() != seen) {
      throw PeerFingerprintMismatchException(shortFp(seen), shortFp(claimed));
    }
  }

  @override
  Future<DeviceInfo> register(DeviceInfo self) async => _model(
    await _send(
      'POST',
      const ['register'],
      json: self.toJson(),
      proof: security.isSecure,
    ),
    DeviceInfo.fromJson,
  );

  @override
  Future<SessionStatus> createSession(SessionRequest request) async => _model(
    await _send(
      'POST',
      const ['sessions'],
      json: request.toJson(),
      proof: security.isSecure,
    ),
    SessionStatus.fromJson,
  );

  @override
  Future<SessionStatus> waitSession(
    String sessionId, {
    int waitSeconds = 25,
  }) async {
    final wait = waitSeconds < 0 ? 0 : waitSeconds;
    return _model(
      await _send(
        'GET',
        ['sessions', sessionId],
        query: {'wait': '$wait'},
        timeout: longPollTimeout(wait),
      ),
      SessionStatus.fromJson,
    );
  }

  @override
  Future<FileState> fileState(
    String sessionId,
    String fileId, {
    required String token,
  }) async => _model(
    await _send('GET', [
      'sessions',
      sessionId,
      'files',
      fileId,
      'state',
    ], token: token),
    FileState.fromJson,
  );

  @override
  Future<void> putChunk(
    String sessionId,
    String fileId,
    int index,
    Stream<List<int>> body, {
    required int length,
    required String chunkSha256,
    required String token,
  }) async {
    await _send(
      'PUT',
      ['sessions', sessionId, 'files', fileId, 'chunks', '$index'],
      token: token,
      stream: body,
      streamLength: length,
      extraHeaders: {kChunkHashHeader: chunkSha256},
    );
  }

  @override
  Future<FileVerification> completeFile(
    String sessionId,
    String fileId, {
    required String token,
    String? sha256,
  }) async => _model(
    await _send(
      'POST',
      ['sessions', sessionId, 'files', fileId, 'complete'],
      token: token,
      json: sha256 == null ? null : {'sha256': sha256},
    ),
    FileVerification.fromJson,
  );

  @override
  Future<SessionStatus> finish(String sessionId) async => _model(
    await _send('POST', ['sessions', sessionId, 'finish']),
    SessionStatus.fromJson,
  );

  @override
  Future<void> cancel(String sessionId) async {
    await _send('POST', ['sessions', sessionId, 'cancel']);
  }

  /// Closes the pool, aborting in-flight requests. Safe to call twice.
  @override
  void close() => _http.close(force: true);

  // ---------------------------------------------------------------- transport

  Uri _uri(List<String> segments, Map<String, String>? query) {
    final api = kApiPrefix.split('/').where((s) => s.isNotEmpty);
    return Uri(
      scheme: (https || security.isSecure) ? 'https' : 'http',
      host: host,
      port: port,
      pathSegments: [...api, ...segments],
      queryParameters: query,
    );
  }

  /// Performs one request and returns the decoded JSON body of a 2xx answer
  /// (null for an empty body). Non-2xx answers throw [LsException].
  Future<Object?> _send(
    String method,
    List<String> segments, {
    Map<String, String>? query,
    Object? json,
    String? token,
    Stream<List<int>>? stream,
    int? streamLength,
    Map<String, String> extraHeaders = const {},
    Duration? timeout,
    bool proof = false,
  }) {
    final limit = timeout ?? requestTimeout;
    HttpClientRequest? request;

    Future<Object?> run() async {
      final jsonBytes = json == null ? null : utf8.encode(jsonEncode(json));
      for (var attempt = 0; ; attempt++) {
        final uri = _uri(segments, query);
        final req = request = await _http.openUrl(method, uri);
        req
          ..followRedirects = false
          ..headers.set(HttpHeaders.acceptHeader, 'application/json');
        if (token != null) {
          req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        }
        extraHeaders.forEach(req.headers.set);
        if (proof) {
          req.headers.set(
            kAuthHeader,
            _proofHeader(method, uri, jsonBytes ?? const []),
          );
        }

        if (stream != null) {
          req.headers.contentType = ContentType.binary;
          req.contentLength = streamLength!;
          await req.addStream(stream);
        } else if (jsonBytes != null) {
          req.headers.contentType = ContentType.json;
          req.contentLength = jsonBytes.length;
          req.add(jsonBytes);
        } else {
          req.contentLength = 0;
        }

        final response = await req.close();
        _checkResponseCertificate(response);
        final bytes = await _readBody(response);
        final status = response.statusCode;
        if (status >= 200 && status < 300) return _decodeSuccess(bytes);
        final error = _errorFrom(status, bytes);
        // Clock skew (LSP-1 4.3.6): one retry with a corrected timestamp and a fresh nonce.
        if (proof &&
            attempt == 0 &&
            status == 401 &&
            error.code == LsErrorCode.authInvalid) {
          final serverDate = _dateOf(response);
          if (serverDate != null) {
            _skew = serverDate.difference(DateTime.now().toUtc());
            continue;
          }
        }
        throw error;
      }
    }

    return run()
        .timeout(
          limit,
          onTimeout: () {
            request?.abort();
            throw TimeoutException('$method request timed out', limit);
          },
        )
        .onError<HttpException>(
          (e, st) => Error.throwWithStackTrace(SocketException(e.message), st),
        )
        .onError<TlsException>((e, st) {
          if (!security.isSecure) throw e;
          // A refused certificate is a key problem; any other handshake failure means the peer
          // cannot do TLS 1.3 (plaintext listener, old stack). Never retried in the clear.
          final mismatch = _mismatch;
          _mismatch = null;
          if (mismatch != null) Error.throwWithStackTrace(mismatch, st);
          // A TLS error with an OS-level cause (bad version, alert, HTTP reply to a ClientHello)
          // means the peer does not offer the secure profile. A handshake that was merely
          // terminated or reset carries none: that is a connection failure, not a downgrade.
          if (e.osError == null) {
            Error.throwWithStackTrace(SocketException(e.message), st);
          }
          Error.throwWithStackTrace(const InsecurePeerException(), st);
        });
  }

  /// `X-LS-Auth` for one request, bound to the certificate fingerprint of the connection.
  String _proofHeader(String method, Uri uri, List<int> body) {
    final serverFp = _seenFp;
    if (serverFp == null) throw const InsecurePeerException();
    return buildAuthHeader(
      identity: security.identity!,
      method: method,
      pathAndQuery: pathAndQueryOf(uri),
      body: body,
      serverFingerprint: serverFp,
      now: DateTime.now().toUtc().add(_skew),
    );
  }

  /// Defence in depth: the certificate of the answering connection is the one we checked.
  void _checkResponseCertificate(HttpClientResponse response) {
    if (!security.isSecure) return;
    final cert = response.certificate;
    final seen = _seenFp;
    if (cert == null || seen == null) return;
    final presented = fingerprintHex(cert.der);
    if (presented != seen) {
      throw PeerFingerprintMismatchException(shortFp(seen), shortFp(presented));
    }
  }

  static DateTime? _dateOf(HttpClientResponse response) {
    try {
      return response.headers.date?.toUtc();
    } on Object {
      return null;
    }
  }

  static Future<Uint8List> _readBody(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
      if (builder.length > _maxResponseBytes) {
        throw LsException(LsErrorCode.internal, 'Response too large');
      }
    }
    return builder.takeBytes();
  }

  static Object? _decodeSuccess(Uint8List bytes) {
    if (bytes.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw LsException(LsErrorCode.internal, 'Malformed response from peer');
    }
  }

  /// Parses the §4.3 error envelope; anything else becomes `INTERNAL`.
  static LsException _errorFrom(int status, Uint8List bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map && decoded['error'] is Map) {
        return LsException.fromEnvelope(
          decoded.cast<String, Object?>(),
          status: status,
        );
      }
    } on Object {
      // fall through: not an envelope
    }
    return LsException(LsErrorCode.internal, 'HTTP $status');
  }

  static T _model<T>(Object? json, T Function(Map<String, Object?>) parse) {
    try {
      if (json is! Map) throw const FormatException('object expected');
      return parse(json.cast<String, Object?>());
    } on TypeError {
      throw LsException(LsErrorCode.internal, 'Malformed response from peer');
    } on FormatException {
      throw LsException(LsErrorCode.internal, 'Malformed response from peer');
    }
  }
}
