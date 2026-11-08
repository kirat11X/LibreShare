// InMemoryRelay backend for hermetic unit testing and simulated multi-relay failover.
library;

import 'dart:async';

import 'rendezvous_backend.dart';

/// Hermetic in-memory relay backend implementing [RendezvousBackend].
class InMemoryRelay implements RendezvousBackend {
  InMemoryRelay({this.name = 'in-memory-relay'});

  final String name;

  final StreamController<RendezvousStatus> _statusCtrl =
      StreamController<RendezvousStatus>.broadcast();
  final StreamController<RelayEvent> _eventCtrl =
      StreamController<RelayEvent>.broadcast();

  final Set<String> _subscriptions = {};
  bool _isConnected = false;
  int _publishedCount = 0;

  /// Total number of published events processed.
  int get publishedCount => _publishedCount;

  /// Optional hook to simulate network delays.
  Duration? latency;

  /// Channels whose traffic is intentionally dropped (for fault testing).
  final Set<String> droppedChannels = {};

  @override
  Stream<RendezvousStatus> get statusStream => _statusCtrl.stream;

  @override
  Stream<RelayEvent> get events => _eventCtrl.stream;

  bool get isConnected => _isConnected;

  @override
  Future<void> connect(List<Uri> relayUrls) async {
    _statusCtrl.add(RendezvousStatus.connecting);
    if (latency != null) {
      await Future<void>.delayed(latency!);
    } else {
      await Future<void>.delayed(Duration.zero);
    }
    _isConnected = true;
    _statusCtrl.add(RendezvousStatus.connected);
  }

  @override
  Future<void> disconnect() async {
    _isConnected = false;
    _subscriptions.clear();
    _statusCtrl.add(RendezvousStatus.disconnected);
  }

  @override
  Future<void> subscribe(String channelIdHex) async {
    _subscriptions.add(channelIdHex.toLowerCase());
  }

  @override
  Future<void> unsubscribe(String channelIdHex) async {
    _subscriptions.remove(channelIdHex.toLowerCase());
  }

  @override
  Future<void> publish(RelayEvent event) async {
    if (!_isConnected) {
      throw StateError('Cannot publish when relay is disconnected');
    }

    _publishedCount++;

    final chan = event.channelIdHex.toLowerCase();
    if (droppedChannels.contains(chan)) {
      // Intentionally drop event for fault testing
      return;
    }

    if (latency != null) {
      await Future<void>.delayed(latency!);
    }

    // Deliver to event stream if subscribed
    if (_subscriptions.contains(chan)) {
      _eventCtrl.add(event);
    }
  }

  /// Broadcasts an event to a specific target relay instance.
  void deliverExternal(RelayEvent event) {
    if (!_isConnected) return;
    final chan = event.channelIdHex.toLowerCase();
    if (droppedChannels.contains(chan)) return;

    if (_subscriptions.contains(chan)) {
      _eventCtrl.add(event);
    }
  }

  /// Closes all controllers.
  Future<void> close() async {
    await disconnect();
    await _statusCtrl.close();
    await _eventCtrl.close();
  }
}
