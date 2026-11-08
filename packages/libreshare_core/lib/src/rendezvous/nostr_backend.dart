// Multi-relay WebSocket Nostr transport with failover, deduping, and safety clamps.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

import 'nip01.dart';
import 'rendezvous_backend.dart';

final Logger _log = Logger('NostrBackend');

/// Maximum incoming frame size allowed from a relay (128 KiB safety clamp).
const int kMaxRelayFrameBytes = 128 * 1024;

/// Connection handle to an individual WebSocket relay.
class _RelayClient {
  _RelayClient(this.url);
  final Uri url;
  WebSocket? ws;
  bool isConnected = false;
  StreamSubscription<dynamic>? sub;

  Future<bool> connect({Duration timeout = const Duration(seconds: 5)}) async {
    try {
      ws = await WebSocket.connect(url.toString()).timeout(timeout);
      ws!.pingInterval = const Duration(seconds: 30);
      isConnected = true;
      return true;
    } catch (e) {
      _log.warning('Failed to connect to relay $url: $e');
      isConnected = false;
      return false;
    }
  }

  void send(String message) {
    if (isConnected && ws != null) {
      try {
        ws!.add(message);
      } catch (e) {
        _log.warning('Send to $url failed: $e');
        isConnected = false;
      }
    }
  }

  Future<void> close() async {
    isConnected = false;
    await sub?.cancel();
    sub = null;
    try {
      await ws?.close();
    } catch (_) {}
    ws = null;
  }
}

/// Production multi-relay Nostr transport backend (LSP-R1 Section 3).
class NostrBackend implements RendezvousBackend {
  NostrBackend({this.reconnectBackoff = true});

  final bool reconnectBackoff;

  final StreamController<RendezvousStatus> _statusCtrl =
      StreamController<RendezvousStatus>.broadcast();
  final StreamController<RelayEvent> _eventCtrl =
      StreamController<RelayEvent>.broadcast();

  final List<_RelayClient> _relays = [];
  final Set<String> _channels = {};
  final Set<String> _seenEventIds = {};
  static final BigInt _ephemeralSk = BigInt.parse(
    'c867207612f026a7a58a74c7980ad4e3e371b2d4f23b7b5fb913b2e53ef71661',
    radix: 16,
  );

  RendezvousStatus _currentStatus = RendezvousStatus.disconnected;

  @override
  Stream<RendezvousStatus> get statusStream => _statusCtrl.stream;

  @override
  Stream<RelayEvent> get events => _eventCtrl.stream;

  RendezvousStatus get status => _currentStatus;

  @override
  Future<void> connect(List<Uri> relayUrls) async {
    await disconnect();
    _updateStatus(RendezvousStatus.connecting);

    for (final url in relayUrls) {
      final client = _RelayClient(url);
      _relays.add(client);
    }

    final futures = _relays.map((r) => _connectRelay(r));
    await Future.wait(futures);

    _evalStatus();
  }

  Future<void> _connectRelay(_RelayClient client) async {
    final success = await client.connect();
    if (success && client.ws != null) {
      client.sub = client.ws!.listen(
        (data) => _handleRelayMessage(client, data),
        onDone: () {
          client.isConnected = false;
          _evalStatus();
        },
        onError: (_) {
          client.isConnected = false;
          _evalStatus();
        },
      );

      // Re-subscribe all active channels on this newly connected relay
      for (final chan in _channels) {
        _sendReq(client, chan);
      }
    }
  }

  void _evalStatus() {
    final connectedCount = _relays.where((r) => r.isConnected).length;
    if (connectedCount == 0) {
      _updateStatus(RendezvousStatus.disconnected);
    } else if (connectedCount < _relays.length) {
      _updateStatus(RendezvousStatus.degraded);
    } else {
      _updateStatus(RendezvousStatus.connected);
    }
  }

  void _updateStatus(RendezvousStatus s) {
    if (_currentStatus != s) {
      _currentStatus = s;
      _statusCtrl.add(s);
    }
  }

  void _sendReq(_RelayClient client, String channelIdHex) {
    final req = jsonEncode([
      'REQ',
      'sub_$channelIdHex',
      {
        '#p': [channelIdHex.toLowerCase()],
        'kinds': [20059, 1059],
      },
    ]);
    client.send(req);
  }

  void _handleRelayMessage(_RelayClient client, dynamic data) {
    if (data is! String) return;

    // Safety clamp: drop frames exceeding 128 KiB
    if (data.length > kMaxRelayFrameBytes) {
      _log.warning(
        'Dropped oversized relay frame of ${data.length} bytes from ${client.url}',
      );
      return;
    }

    final dynamic parsed;
    try {
      parsed = jsonDecode(data);
    } catch (_) {
      return;
    }

    if (parsed is! List || parsed.isEmpty) return;
    final msgType = parsed[0] as String?;

    if (msgType == 'EVENT' &&
        parsed.length >= 3 &&
        parsed[2] is Map<String, dynamic>) {
      final eventMap = parsed[2] as Map<String, dynamic>;
      final eventId = eventMap['id'] as String? ?? '';

      // Deduplicate events arriving across multiple relays
      if (eventId.isEmpty || _seenEventIds.contains(eventId)) {
        return;
      }
      _seenEventIds.add(eventId);
      if (_seenEventIds.length > 5000) {
        _seenEventIds.remove(_seenEventIds.first);
      }

      final tags =
          (eventMap['tags'] as List?)?.cast<List<dynamic>>() ??
          const <List<dynamic>>[];
      String channelId = '';
      for (final tag in tags) {
        if (tag.isNotEmpty && tag[0] == 'p' && tag.length > 1) {
          channelId = (tag[1] as String).toLowerCase();
          break;
        }
      }

      final content = eventMap['content'] as String? ?? '';
      final payload = base64Url.decode(content);

      final relayEvent = RelayEvent(
        id: eventId,
        channelIdHex: channelId,
        payload: payload,
        createdAt: eventMap['created_at'] as int? ?? 0,
        pubkeyHex: eventMap['pubkey'] as String? ?? '',
        sigHex: eventMap['sig'] as String? ?? '',
      );

      _eventCtrl.add(relayEvent);
    }
  }

  @override
  Future<void> subscribe(String channelIdHex) async {
    final chan = channelIdHex.toLowerCase();
    _channels.add(chan);
    for (final client in _relays) {
      if (client.isConnected) {
        _sendReq(client, chan);
      }
    }
  }

  @override
  Future<void> unsubscribe(String channelIdHex) async {
    final chan = channelIdHex.toLowerCase();
    _channels.remove(chan);
    final closeMsg = jsonEncode(['CLOSE', 'sub_$chan']);
    for (final client in _relays) {
      client.send(closeMsg);
    }
  }

  @override
  Future<void> publish(RelayEvent event) async {
    final Map<String, dynamic> nostrJson;
    if (event.sigHex.isNotEmpty && event.pubkeyHex.isNotEmpty) {
      nostrJson = {
        'id': event.id,
        'pubkey': event.pubkeyHex,
        'created_at': event.createdAt,
        'kind': 20059,
        'tags': [
          ['p', event.channelIdHex.toLowerCase()],
          ['expiration', '${event.createdAt + event.ttlSeconds}'],
        ],
        'content': base64Url.encode(event.payload),
        'sig': event.sigHex,
      };
    } else {
      final ne = NostrEvent.createAndSign(
        sk: _ephemeralSk,
        kind: 20059,
        tags: [
          ['p', event.channelIdHex.toLowerCase()],
          ['expiration', '${event.createdAt + event.ttlSeconds}'],
        ],
        content: base64Url.encode(event.payload),
        createdAt: event.createdAt,
      );
      nostrJson = ne.toJson();
    }

    final eventMsg = jsonEncode(['EVENT', nostrJson]);
    for (final client in _relays) {
      if (client.isConnected) {
        client.send(eventMsg);
      }
    }
  }

  @override
  Future<void> disconnect() async {
    for (final client in _relays) {
      await client.close();
    }
    _relays.clear();
    _channels.clear();
    _updateStatus(RendezvousStatus.disconnected);
  }

  Future<void> close() async {
    await disconnect();
    await _statusCtrl.close();
    await _eventCtrl.close();
  }
}
