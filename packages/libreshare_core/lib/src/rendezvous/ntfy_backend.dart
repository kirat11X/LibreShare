// NtfyBackend implementing RendezvousBackend via HTTP polling/streaming over ntfy topics.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'rendezvous_backend.dart';

/// Lightweight, $0-cost backup rendezvous transport over ntfy.sh topics.
class NtfyBackend implements RendezvousBackend {
  NtfyBackend({
    HttpClient? httpClient,
    this.pollInterval = const Duration(milliseconds: 250),
  }) : _httpClient = httpClient ?? HttpClient();

  final HttpClient _httpClient;
  final Duration pollInterval;

  final _statusController = StreamController<RendezvousStatus>.broadcast();
  final _eventsController = StreamController<RelayEvent>.broadcast();

  final List<Uri> _relayUrls = [];
  final Set<String> _subscribedChannels = {};
  final Set<String> _seenEventIds = {};
  final Map<String, Timer> _pollTimers = {};

  RendezvousStatus _currentStatus = RendezvousStatus.disconnected;
  bool _disposed = false;

  @override
  Stream<RendezvousStatus> get statusStream => _statusController.stream;

  @override
  Stream<RelayEvent> get events => _eventsController.stream;

  RendezvousStatus get status => _currentStatus;

  static String topicForChannel(String channelIdHex) {
    // Topic name must be valid URL path segment (alphanumeric/hyphens)
    final prefix = channelIdHex.length > 32
        ? channelIdHex.substring(0, 32)
        : channelIdHex;
    return 'ls-rdv-$prefix';
  }

  void _setStatus(RendezvousStatus newStatus) {
    if (_currentStatus != newStatus && !_disposed) {
      _currentStatus = newStatus;
      _statusController.add(newStatus);
    }
  }

  @override
  Future<void> connect(List<Uri> relayUrls) async {
    _relayUrls.clear();
    _relayUrls.addAll(relayUrls);

    if (_relayUrls.isEmpty) {
      _setStatus(RendezvousStatus.disconnected);
      return;
    }

    _setStatus(RendezvousStatus.connecting);
    // Verify reachability of at least one relay
    var reachable = false;
    for (final uri in _relayUrls) {
      try {
        final req = await _httpClient.getUrl(uri);
        final resp = await req.close();
        if (resp.statusCode < 500) {
          reachable = true;
          break;
        }
      } catch (_) {
        // Continue checking next relay
      }
    }

    if (reachable) {
      _setStatus(RendezvousStatus.connected);
    } else {
      _setStatus(RendezvousStatus.degraded);
    }
  }

  @override
  Future<void> disconnect() async {
    for (final timer in _pollTimers.values) {
      timer.cancel();
    }
    _pollTimers.clear();
    _subscribedChannels.clear();
    _setStatus(RendezvousStatus.disconnected);
  }

  @override
  Future<void> subscribe(String channelIdHex) async {
    if (_subscribedChannels.contains(channelIdHex)) return;
    _subscribedChannels.add(channelIdHex);

    // Initial poll immediately
    unawaited(_pollChannel(channelIdHex));

    // Periodic poll timer
    _pollTimers[channelIdHex] = Timer.periodic(pollInterval, (_) {
      if (!_disposed && _subscribedChannels.contains(channelIdHex)) {
        _pollChannel(channelIdHex);
      }
    });
  }

  @override
  Future<void> unsubscribe(String channelIdHex) async {
    _subscribedChannels.remove(channelIdHex);
    _pollTimers.remove(channelIdHex)?.cancel();
  }

  @override
  Future<void> publish(RelayEvent event) async {
    if (_relayUrls.isEmpty) return;

    final topic = topicForChannel(event.channelIdHex);
    final payloadJson = jsonEncode({
      'id': event.id,
      'channel': event.channelIdHex,
      'payload': base64Encode(event.payload),
      'createdAt': event.createdAt,
      'ttl': event.ttlSeconds,
      'pubkey': event.pubkeyHex,
      'sig': event.sigHex,
    });

    var published = false;
    for (final baseUri in _relayUrls) {
      final targetUri = baseUri.replace(
        path: '${baseUri.path.replaceAll(RegExp(r"/+$"), "")}/$topic',
      );
      try {
        final req = await _httpClient.postUrl(targetUri);
        req.headers.contentType = ContentType.json;
        req.write(payloadJson);
        final resp = await req.close();
        if (resp.statusCode == HttpStatus.ok) {
          published = true;
        }
      } catch (_) {
        // Failover to next relay
      }
    }

    if (!published && _currentStatus == RendezvousStatus.connected) {
      _setStatus(RendezvousStatus.degraded);
    }
  }

  Future<void> _pollChannel(String channelIdHex) async {
    if (_relayUrls.isEmpty || _disposed) return;
    final topic = topicForChannel(channelIdHex);

    for (final baseUri in _relayUrls) {
      final targetUri = baseUri.replace(
        path: '${baseUri.path.replaceAll(RegExp(r"/+$"), "")}/$topic/json',
      );

      try {
        final req = await _httpClient.getUrl(targetUri);
        final resp = await req.close();

        if (resp.statusCode != HttpStatus.ok) {
          continue;
        }

        final lines = await utf8.decoder
            .bind(resp)
            .transform(const LineSplitter())
            .toList();

        for (final line in lines) {
          if (line.trim().isEmpty) continue;
          try {
            final parsed = jsonDecode(line) as Map<String, dynamic>;
            final messageText = parsed['message'] as String?;
            if (messageText == null) continue;

            final inner = jsonDecode(messageText) as Map<String, dynamic>;
            final id = inner['id'] as String;
            if (_seenEventIds.contains(id)) continue;
            _seenEventIds.add(id);

            final event = RelayEvent(
              id: id,
              channelIdHex: inner['channel'] as String,
              payload: base64Decode(inner['payload'] as String),
              createdAt: (inner['createdAt'] as num).toInt(),
              ttlSeconds: (inner['ttl'] as num?)?.toInt() ?? 300,
              pubkeyHex: (inner['pubkey'] as String?) ?? '',
              sigHex: (inner['sig'] as String?) ?? '',
            );

            if (!_disposed) {
              _eventsController.add(event);
            }
          } catch (_) {
            // Ignore malformed individual frame
          }
        }
      } catch (_) {
        // Ignore single poll error
      }
    }
  }

  void dispose() {
    _disposed = true;
    disconnect();
    _statusController.close();
    _eventsController.close();
    _httpClient.close(force: true);
  }
}
