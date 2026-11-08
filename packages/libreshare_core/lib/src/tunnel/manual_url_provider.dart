import 'dart:async';

import 'tunnel_provider.dart';

class ManualUrlProvider implements TunnelProvider {
  final Uri url;

  ManualUrlProvider({required this.url}) {
    if (!url.isScheme('https')) {
      throw ArgumentError.value(
        url,
        'url',
        'Manual tunnel URL must be an https scheme',
      );
    }
    if (url.host.isEmpty) {
      throw ArgumentError.value(
        url,
        'url',
        'Manual tunnel URL must have a valid host',
      );
    }
  }

  @override
  String get id => 'manual-url';

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<TunnelHandle> open(
    int localPort, {
    Duration ready = const Duration(seconds: 45),
  }) async {
    return _ManualUrlHandle(publicBase: url);
  }
}

class _ManualUrlHandle implements TunnelHandle {
  @override
  final Uri publicBase;
  final StreamController<TunnelEvent> _eventController =
      StreamController<TunnelEvent>.broadcast();
  bool _closed = false;

  _ManualUrlHandle({required this.publicBase});

  @override
  Stream<TunnelEvent> get events async* {
    if (!_closed) {
      yield const TunnelUpEvent();
    }
    yield* _eventController.stream;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _eventController.add(const TunnelLostEvent('closed'));
    await _eventController.close();
  }
}
