import 'dart:async';

import '../client/api_client.dart';
import '../client/peer_client.dart';
import '../security/contracts.dart';
import 'candidate.dart';
import 'connection.dart';

/// HTTP(S) implementation of [Connection] representing a single candidate path.
class HttpConnection implements Connection {
  HttpConnection({
    required this.candidate,
    this.security = const SecurityConfig.plaintext(),
    this.clientFactory,
  });

  @override
  final Candidate candidate;
  final SecurityConfig security;
  final PeerClient Function(Candidate candidate, SecurityConfig security)?
  clientFactory;

  ConnectionState _state = ConnectionState.disconnected;
  Duration? _latency;
  PeerClient? _client;

  @override
  ConnectionState get state => _state;

  @override
  bool get isHealthy => _state == ConnectionState.connected;

  @override
  Duration? get latency => _latency;

  @override
  Future<PeerClient> open({Duration? timeout}) async {
    _state = ConnectionState.connecting;
    final effectiveTimeout = timeout ?? candidate.connectBudget;

    try {
      if (candidate.setupBudget > Duration.zero) {
        await candidate.setup().timeout(candidate.setupBudget);
      } else {
        await candidate.setup();
      }

      final client = clientFactory != null
          ? clientFactory!(candidate, security)
          : ApiClient(
              host: candidate.host,
              port: candidate.port,
              https: security.isSecure,
              security: security,
              expectedFingerprint: candidate.peerFingerprint.isNotEmpty
                  ? candidate.peerFingerprint
                  : null,
              connectTimeout: effectiveTimeout,
            );

      final stopwatch = Stopwatch()..start();
      try {
        await client.info().timeout(effectiveTimeout);
      } on TimeoutException catch (e) {
        _state = ConnectionState.failed;
        client.close();
        throw ConnectionTimeoutException(
          'Connection probe to ${candidate.host}:${candidate.port} timed out after ${effectiveTimeout.inSeconds}s',
          candidate: candidate,
          cause: e,
        );
      } on Object catch (e) {
        _state = ConnectionState.failed;
        client.close();
        final msg = e.toString().toLowerCase();
        if (msg.contains('fingerprint') ||
            msg.contains('certificate') ||
            msg.contains('cert_mismatch')) {
          throw FingerprintMismatchException(
            expectedFingerprint: candidate.peerFingerprint,
            presentedFingerprint: 'mismatch',
            candidate: candidate,
          );
        }
        throw ConnectionException(
          'Connection probe failed: $e',
          candidate: candidate,
          cause: e,
        );
      }

      stopwatch.stop();
      _latency = stopwatch.elapsed;
      _state = ConnectionState.connected;
      _client = client;
      return client;
    } catch (e) {
      _state = ConnectionState.failed;
      await candidate.teardown();
      rethrow;
    }
  }

  @override
  Future<void> close() async {
    _state = ConnectionState.closed;
    _client?.close();
    _client = null;
    await candidate.teardown();
  }
}
