import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../client/peer_client.dart';
import '../model/device.dart';
import '../model/session_models.dart';
import '../model/transfer_status.dart';
import '../security/tunnel_crypto.dart';
import 'candidate.dart';
import 'connection.dart';

abstract class OriginPullConnection implements Connection {
  @override
  final Candidate candidate;
  final Uri originBase;
  final String token;
  final TunnelKeys keys;
  final String claim;

  ConnectionState _state = ConnectionState.disconnected;
  Duration? _latency;
  OriginPullPeerClient? _client;

  OriginPullConnection({
    required this.candidate,
    required this.originBase,
    required this.token,
    required this.keys,
    required this.claim,
  });

  @override
  ConnectionState get state => _state;

  @override
  bool get isHealthy => _state == ConnectionState.connected;

  @override
  Duration? get latency => _latency;

  HttpClient createHttpClient();

  @override
  Future<OriginPullPeerClient> open({Duration? timeout}) async {
    _state = ConnectionState.connecting;
    final stopwatch = Stopwatch()..start();
    try {
      final httpClient = createHttpClient();
      if (timeout != null) {
        httpClient.connectionTimeout = timeout;
      }
      final client = OriginPullPeerClient(
        originBase: originBase,
        token: token,
        keys: keys,
        claim: claim,
        httpClient: httpClient,
      );

      // Probe manifest to confirm connectivity
      await client.probe(timeout: timeout ?? const Duration(seconds: 10));
      stopwatch.stop();
      _latency = stopwatch.elapsed;
      _state = ConnectionState.connected;
      _client = client;
      return client;
    } catch (e) {
      _state = ConnectionState.failed;
      throw ConnectionException(
        'Failed to open pull connection to $originBase',
        candidate: candidate,
        cause: e,
      );
    }
  }

  @override
  Future<void> close() async {
    _client?.close();
    _client = null;
    _state = ConnectionState.closed;
  }
}

class OriginPullPeerClient implements PeerClient {
  final Uri originBase;
  final String token;
  final TunnelKeys keys;
  final String claim;
  final HttpClient httpClient;

  OriginPullPeerClient({
    required this.originBase,
    required this.token,
    required this.keys,
    required this.claim,
    required this.httpClient,
  });

  Future<void> probe({Duration timeout = const Duration(seconds: 10)}) async {
    final uri = originBase.resolve('/t/$token/manifest');
    final req = await httpClient.getUrl(uri).timeout(timeout);
    req.headers.set('X-LS-Claim', claim);
    final resp = await req.close().timeout(timeout);
    if (resp.statusCode != HttpStatus.ok &&
        resp.statusCode != HttpStatus.noContent) {
      throw ConnectionException('Probe returned HTTP ${resp.statusCode}');
    }
    await resp.drain();
  }

  Future<String> getManifestRaw() async {
    final uri = originBase.resolve('/t/$token/manifest');
    final req = await httpClient.getUrl(uri);
    req.headers.set('X-LS-Claim', claim);
    final resp = await req.close();
    if (resp.statusCode != HttpStatus.ok) {
      throw ConnectionException(
        'Failed to get manifest: HTTP ${resp.statusCode}',
      );
    }
    final sealedBytes = await resp.fold<List<int>>([], (p, e) => p..addAll(e));
    final decrypted = keys.open(TunnelPurpose.manifest, sealedBytes);
    return utf8.decode(decrypted);
  }

  Future<Uint8List> getChunkRaw(int fileIndex, int chunkIndex) async {
    final uri = originBase.resolve('/t/$token/f/$fileIndex/c/$chunkIndex');
    final req = await httpClient.getUrl(uri);
    req.headers.set('X-LS-Claim', claim);
    final resp = await req.close();
    if (resp.statusCode != HttpStatus.ok) {
      throw ConnectionException(
        'Failed to get chunk $chunkIndex of file $fileIndex: HTTP ${resp.statusCode}',
      );
    }
    final sealedBytes = await resp.fold<List<int>>([], (p, e) => p..addAll(e));
    return keys.open(
      TunnelPurpose.chunk,
      sealedBytes,
      fileIndex: fileIndex,
      chunkIndex: chunkIndex,
    );
  }

  Future<bool> sendChunkAck(int fileIndex, int chunkIndex) async {
    final uri = originBase.resolve('/t/$token/ack');
    final plainAck = jsonEncode({
      'fid': fileIndex,
      'idx': chunkIndex,
      'final': false,
    });
    final sealedAck = keys.seal(
      TunnelPurpose.ack,
      utf8.encode(plainAck),
      fileIndex: fileIndex,
      chunkIndex: chunkIndex,
    );
    final req = await httpClient.postUrl(uri);
    req.headers.set('X-LS-Claim', claim);
    req.headers.set('X-LS-File-Index', '$fileIndex');
    req.headers.set('X-LS-Chunk-Index', '$chunkIndex');
    req.headers.contentType = ContentType('application', 'octet-stream');
    req.add(sealedAck);
    final resp = await req.close();
    await resp.drain();
    return resp.statusCode == HttpStatus.ok ||
        resp.statusCode == HttpStatus.noContent;
  }

  Future<bool> sendFinalAck() async {
    final uri = originBase.resolve('/t/$token/ack');
    final plainAck = jsonEncode({'final': true, 'verified': true});
    final sealedAck = keys.seal(
      TunnelPurpose.ack,
      utf8.encode(plainAck),
      fileIndex: kTunnelManifestFileIndex,
      chunkIndex: 0,
    );
    final req = await httpClient.postUrl(uri);
    req.headers.set('X-LS-Claim', claim);
    req.headers.contentType = ContentType('application', 'octet-stream');
    req.add(sealedAck);
    final resp = await req.close();
    await resp.drain();
    return resp.statusCode == HttpStatus.ok ||
        resp.statusCode == HttpStatus.noContent;
  }

  @override
  void close() {
    httpClient.close(force: true);
  }

  @override
  Future<void> cancel(String sessionId) async {}

  @override
  Future<FileVerification> completeFile(
    String sessionId,
    String fileId, {
    required String token,
    String? sha256,
  }) async => FileVerification(verified: true, sha256: sha256 ?? '');

  @override
  Future<SessionStatus> createSession(SessionRequest request) async =>
      const SessionStatus(
        sessionId: 'pull_session',
        status: TransferStatus.inProgress,
      );

  @override
  Future<FileState> fileState(
    String sessionId,
    String fileId, {
    required String token,
  }) async => const FileState(receivedRanges: [], chunkCount: 0);

  @override
  Future<SessionStatus> finish(String sessionId) async => const SessionStatus(
    sessionId: 'pull_session',
    status: TransferStatus.completed,
  );

  @override
  Future<DeviceInfo> info() async => const DeviceInfo(
    deviceId: 'tunnel-origin',
    alias: 'Tunnel Origin',
    platform: 'linux',
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
  }) async {}

  @override
  Future<DeviceInfo> register(DeviceInfo self) async => self;

  @override
  Future<SessionStatus> waitSession(
    String sessionId, {
    int waitSeconds = 25,
  }) async =>
      SessionStatus(sessionId: sessionId, status: TransferStatus.inProgress);
}
