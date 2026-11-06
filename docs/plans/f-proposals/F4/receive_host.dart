import 'dart:async';

import 'package:flutter/services.dart';

/// Channel identifier for the Android native receive service.
const String kReceiveServiceChannel = 'dev.libreshare/receive_service';

/// Android Foreground Service types supported by LibreShare.
enum AndroidForegroundServiceType {
  none(0, 'none'),
  dataSync(1, 'dataSync'),
  connectedDevice(16, 'connectedDevice');

  const AndroidForegroundServiceType(this.flag, this.wireName);

  final int flag;
  final String wireName;

  static AndroidForegroundServiceType fromFlag(int flag) {
    if ((flag & connectedDevice.flag) != 0) return connectedDevice;
    if ((flag & dataSync.flag) != 0) return dataSync;
    return none;
  }
}

/// Event emitted when Android OS invokes onTimeout for a foreground service.
class ServiceTimeoutEvent {
  const ServiceTimeoutEvent({
    required this.startId,
    required this.fgsType,
    required this.serviceType,
  });

  final int startId;
  final int fgsType;
  final AndroidForegroundServiceType serviceType;

  @override
  String toString() =>
      'ServiceTimeoutEvent(startId: $startId, fgsType: $fgsType, type: $serviceType)';
}

/// Abstract interface for managing the background receive host.
abstract class ReceiveHost {
  AndroidForegroundServiceType get activeType;
  Stream<ServiceTimeoutEvent> get timeoutEvents;

  Future<AndroidForegroundServiceType> startForegroundService({
    required String notificationTitle,
    required String notificationBody,
    AndroidForegroundServiceType? preferredType,
  });

  Future<void> stopForegroundService();
  Future<bool> isServiceRunning();
  void setOnTimeoutListener(void Function(int startId, int fgsType)? listener);
  void dispose();
}

/// Android native implementation of [ReceiveHost] via [MethodChannel].
class AndroidReceiveHost implements ReceiveHost {
  AndroidReceiveHost({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(kReceiveServiceChannel) {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  final MethodChannel _channel;
  final _timeoutController = StreamController<ServiceTimeoutEvent>.broadcast();
  void Function(int startId, int fgsType)? _onTimeoutListener;

  AndroidForegroundServiceType _activeType = AndroidForegroundServiceType.none;

  @override
  AndroidForegroundServiceType get activeType => _activeType;

  @override
  Stream<ServiceTimeoutEvent> get timeoutEvents => _timeoutController.stream;

  @override
  void setOnTimeoutListener(void Function(int startId, int fgsType)? listener) {
    _onTimeoutListener = listener;
  }

  void _assertNoSecrets(String text) {
    final lower = text.toLowerCase();
    if (text.contains('s=') ||
        lower.contains('privatekey') ||
        lower.contains('pin required') ||
        RegExp(r'[0-9a-fA-F]{17,}').hasMatch(text)) {
      throw ArgumentError(
        'Security violation: secret leaked in notification payload: $text',
      );
    }
  }

  @override
  Future<AndroidForegroundServiceType> startForegroundService({
    required String notificationTitle,
    required String notificationBody,
    AndroidForegroundServiceType? preferredType,
  }) async {
    _assertNoSecrets(notificationTitle);
    _assertNoSecrets(notificationBody);

    if (preferredType == AndroidForegroundServiceType.none) {
      _activeType = AndroidForegroundServiceType.none;
      return AndroidForegroundServiceType.none;
    }

    final typesToTry = preferredType != null
        ? [preferredType]
        : [
            AndroidForegroundServiceType.connectedDevice,
            AndroidForegroundServiceType.dataSync,
          ];

    for (final type in typesToTry) {
      try {
        final ok = await _channel.invokeMethod<bool>('startService', {
          'type': type.wireName,
          'title': notificationTitle,
          'body': notificationBody,
        });

        if (ok == true) {
          _activeType = type;
          return type;
        }
      } on PlatformException catch (_) {
        // Fall back to next type in ladder
      } on MissingPluginException catch (_) {
        _activeType = AndroidForegroundServiceType.none;
        return AndroidForegroundServiceType.none;
      }
    }

    _activeType = AndroidForegroundServiceType.none;
    return AndroidForegroundServiceType.none;
  }

  @override
  Future<void> stopForegroundService() async {
    _activeType = AndroidForegroundServiceType.none;
    try {
      await _channel.invokeMethod('stopService');
    } on PlatformException catch (_) {
      // Ignored
    } on MissingPluginException catch (_) {
      // Ignored
    }
  }

  @override
  Future<bool> isServiceRunning() async {
    try {
      final running = await _channel.invokeMethod<bool>('isServiceRunning');
      return running ?? false;
    } on PlatformException catch (_) {
      return false;
    } on MissingPluginException catch (_) {
      return false;
    }
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method == 'onTimeout') {
      final args = call.arguments as Map<dynamic, dynamic>? ?? {};
      final startId = args['startId'] as int? ?? 0;
      final fgsType = args['fgsType'] as int? ?? 0;
      final type = AndroidForegroundServiceType.fromFlag(fgsType);

      _activeType = AndroidForegroundServiceType.none;
      _onTimeoutListener?.call(startId, fgsType);

      if (!_timeoutController.isClosed) {
        _timeoutController.add(
          ServiceTimeoutEvent(
            startId: startId,
            fgsType: fgsType,
            serviceType: type,
          ),
        );
      }
    }
    return null;
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    _timeoutController.close();
  }
}

/// No-op implementation of [ReceiveHost] for non-Android platforms or testing.
class NoopReceiveHost implements ReceiveHost {
  const NoopReceiveHost();

  @override
  AndroidForegroundServiceType get activeType =>
      AndroidForegroundServiceType.none;

  @override
  Stream<ServiceTimeoutEvent> get timeoutEvents =>
      const Stream<ServiceTimeoutEvent>.empty();

  @override
  Future<AndroidForegroundServiceType> startForegroundService({
    required String notificationTitle,
    required String notificationBody,
    AndroidForegroundServiceType? preferredType,
  }) async {
    return AndroidForegroundServiceType.none;
  }

  @override
  Future<void> stopForegroundService() async {}

  @override
  Future<bool> isServiceRunning() async => false;

  @override
  void setOnTimeoutListener(
    void Function(int startId, int fgsType)? listener,
  ) {}

  @override
  void dispose() {}
}
