// In-process WebSocket Nostr Relay on 127.0.0.1 for integration testing.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'nip01.dart';

/// Subscription state on a client connection.
class _Subscription {
  _Subscription({
    required this.subId,
    required this.pTags,
    required this.kinds,
  });
  final String subId;
  final Set<String> pTags;
  final Set<int> kinds;

  bool matches(NostrEvent event) {
    if (kinds.isNotEmpty && !kinds.contains(event.kind)) {
      return false;
    }
    if (pTags.isEmpty) return true;
    for (final tag in event.tags) {
      if (tag.isNotEmpty && tag[0] == 'p' && tag.length > 1) {
        if (pTags.contains(tag[1].toLowerCase())) return true;
      }
    }
    return false;
  }
}

/// Hermetic in-process Nostr relay over real localhost WebSockets.
class LoopbackNostrRelay {
  LoopbackNostrRelay({this.verifySignatures = true});

  final bool verifySignatures;
  HttpServer? _server;
  final List<WebSocket> _clients = [];
  final Map<WebSocket, Map<String, _Subscription>> _clientSubs = {};
  final List<NostrEvent> _events = [];

  bool _isKilled = false;

  int get port => _server?.port ?? 0;
  Uri get url => Uri.parse('ws://127.0.0.1:$port');

  /// Starts the relay on an ephemeral localhost port.
  Future<void> start() async {
    _server = await HttpServer.bind('127.0.0.1', 0);
    _server!.listen(_handleHttpRequest);
  }

  void _handleHttpRequest(HttpRequest request) {
    if (_isKilled) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      request.response.close();
      return;
    }

    if (WebSocketTransformer.isUpgradeRequest(request)) {
      WebSocketTransformer.upgrade(request).then(_handleWebSocket);
    } else {
      // NIP-11 Information Document
      request.response.headers.contentType = ContentType(
        'application',
        'nostr+json',
      );
      request.response.write(
        jsonEncode({
          'name': 'LibreShare Test Relay',
          'description': 'In-process loopback relay for automated testing',
          'supported_nips': [1, 11, 40],
          'software': 'libreshare-loopback',
          'version': '1.0.0',
        }),
      );
      request.response.close();
    }
  }

  void _handleWebSocket(WebSocket ws) {
    if (_isKilled) {
      ws.close();
      return;
    }
    _clients.add(ws);
    _clientSubs[ws] = {};

    ws.listen(
      (data) => _handleClientMessage(ws, data),
      onDone: () => _removeClient(ws),
      onError: (_) => _removeClient(ws),
    );
  }

  void _removeClient(WebSocket ws) {
    _clients.remove(ws);
    _clientSubs.remove(ws);
  }

  void _safeSend(WebSocket ws, dynamic msg) {
    try {
      ws.add(msg);
    } catch (_) {}
  }

  void _handleClientMessage(WebSocket ws, dynamic data) {
    if (data is! String) return;

    final dynamic parsed;
    try {
      parsed = jsonDecode(data);
    } catch (_) {
      _safeSend(ws, jsonEncode(['NOTICE', 'error: malformed JSON']));
      return;
    }

    if (parsed is! List || parsed.isEmpty) return;
    final msgType = parsed[0] as String?;

    switch (msgType) {
      case 'EVENT':
        if (parsed.length < 2 || parsed[1] is! Map<String, dynamic>) {
          _safeSend(ws, jsonEncode(['NOTICE', 'error: invalid EVENT payload']));
          return;
        }
        final eventMap = parsed[1] as Map<String, dynamic>;
        final event = NostrEvent.fromJson(eventMap);

        if (verifySignatures && !event.verify()) {
          _safeSend(
            ws,
            jsonEncode([
              'OK',
              event.id,
              false,
              'invalid: signature verification failed',
            ]),
          );
          return;
        }

        _events.add(event);
        _safeSend(ws, jsonEncode(['OK', event.id, true, '']));

        // Broadcast to all matching client subscriptions
        _broadcastEvent(event);
        break;

      case 'REQ':
        if (parsed.length < 3) return;
        final subId = parsed[1] as String? ?? '';
        final pTags = <String>{};
        final kinds = <int>{};

        for (var i = 2; i < parsed.length; i++) {
          if (parsed[i] is Map<String, dynamic>) {
            final f = parsed[i] as Map<String, dynamic>;
            final pList = (f['#p'] as List?)?.cast<String>();
            if (pList != null) {
              pTags.addAll(pList.map((p) => p.toLowerCase()));
            }
            final kList = (f['kinds'] as List?)?.cast<int>();
            if (kList != null) {
              kinds.addAll(kList);
            }
          }
        }

        final sub = _Subscription(subId: subId, pTags: pTags, kinds: kinds);
        _clientSubs[ws]?[subId] = sub;

        // Deliver existing matching events
        for (final ev in _events) {
          if (sub.matches(ev)) {
            _safeSend(ws, jsonEncode(['EVENT', subId, ev.toJson()]));
          }
        }
        _safeSend(ws, jsonEncode(['EOSE', subId]));
        break;

      case 'CLOSE':
        if (parsed.length >= 2) {
          final subId = parsed[1] as String? ?? '';
          _clientSubs[ws]?.remove(subId);
        }
        break;
    }
  }

  void _broadcastEvent(NostrEvent event) {
    for (final ws in List<WebSocket>.from(_clients)) {
      final subs = _clientSubs[ws];
      if (subs == null) continue;

      for (final sub in subs.values) {
        if (sub.matches(event)) {
          try {
            ws.add(jsonEncode(['EVENT', sub.subId, event.toJson()]));
          } catch (_) {}
        }
      }
    }
  }

  /// Injects an oversized frame (> 128 KiB) to all connected clients.
  void injectOversizedFrame() {
    final oversized = jsonEncode(['EVENT', 'test', 'A' * (130 * 1024)]);
    for (final ws in List<WebSocket>.from(_clients)) {
      try {
        ws.add(oversized);
      } catch (_) {}
    }
  }

  /// Terminates the relay abruptly (simulating network cut or crash mid-run).
  Future<void> killMidRun() async {
    _isKilled = true;
    for (final ws in List<WebSocket>.from(_clients)) {
      try {
        await ws.close(WebSocketStatus.goingAway, 'Relay killed');
      } catch (_) {}
    }
    _clients.clear();
    _clientSubs.clear();
    await _server?.close(force: true);
    _server = null;
  }

  /// Cleanly closes the relay.
  Future<void> stop() async {
    await killMidRun();
  }
}
