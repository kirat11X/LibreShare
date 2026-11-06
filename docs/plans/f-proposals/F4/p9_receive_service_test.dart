import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/platform/android/receive_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(kReceiveServiceChannel);

  late List<MethodCall> calls;
  late AndroidReceiveHost host;

  void handle(Future<Object?>? Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return handler(call);
        });
  }

  setUp(() {
    calls = [];
    host = AndroidReceiveHost();
    handle((call) async {
      switch (call.method) {
        case 'startService':
          return true;
        case 'stopService':
          return null;
        case 'isServiceRunning':
          return true;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    host.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('uses the documented channel name', () {
    expect(kReceiveServiceChannel, 'dev.libreshare/receive_service');
  });

  group('startForegroundService', () {
    test('starts with F0 connectedDevice by default', () async {
      final result = await host.startForegroundService(
        notificationTitle: 'LibreShare',
        notificationBody: 'Ready to receive files',
      );

      expect(result, AndroidForegroundServiceType.connectedDevice);
      expect(host.activeType, AndroidForegroundServiceType.connectedDevice);
      expect(calls.length, 1);
      expect(calls.first.method, 'startService');
      expect(calls.first.arguments, {
        'type': 'connectedDevice',
        'title': 'LibreShare',
        'body': 'Ready to receive files',
      });
    });

    test('fallback ladder: F0 fails -> F1 dataSync succeeds', () async {
      handle((call) async {
        if (call.method == 'startService') {
          final args = call.arguments as Map<dynamic, dynamic>;
          if (args['type'] == 'connectedDevice') {
            throw PlatformException(
              code: 'fgs_not_allowed',
              message: 'connectedDevice rejected by OS policy',
            );
          }
          if (args['type'] == 'dataSync') {
            return true;
          }
        }
        return null;
      });

      final result = await host.startForegroundService(
        notificationTitle: 'LibreShare',
        notificationBody: 'Ready to receive files',
      );

      expect(result, AndroidForegroundServiceType.dataSync);
      expect(host.activeType, AndroidForegroundServiceType.dataSync);
      expect(calls.length, 2);
      expect(calls[0].arguments['type'], 'connectedDevice');
      expect(calls[1].arguments['type'], 'dataSync');
    });

    test('fallback ladder: F0 and F1 fail -> F2 none (foreground-only) without throwing', () async {
      handle((call) async {
        if (call.method == 'startService') {
          throw PlatformException(
            code: 'security_exception',
            message: 'Permission denied',
          );
        }
        return null;
      });

      final result = await host.startForegroundService(
        notificationTitle: 'LibreShare',
        notificationBody: 'Ready to receive files',
      );

      expect(result, AndroidForegroundServiceType.none);
      expect(host.activeType, AndroidForegroundServiceType.none);
      expect(calls.length, 2);
    });

    test('explicit preferredType dataSync skips connectedDevice', () async {
      final result = await host.startForegroundService(
        notificationTitle: 'LibreShare',
        notificationBody: 'Syncing',
        preferredType: AndroidForegroundServiceType.dataSync,
      );

      expect(result, AndroidForegroundServiceType.dataSync);
      expect(calls.length, 1);
      expect(calls.first.arguments['type'], 'dataSync');
    });

    test(
      'explicit preferredType none does not invoke platform channel',
      () async {
        final result = await host.startForegroundService(
          notificationTitle: 'LibreShare',
          notificationBody: 'Visible only',
          preferredType: AndroidForegroundServiceType.none,
        );

        expect(result, AndroidForegroundServiceType.none);
        expect(calls, isEmpty);
      },
    );
  });

  group('stopForegroundService & isServiceRunning', () {
    test(
      'stopForegroundService invokes stopService and clears active type',
      () async {
        await host.startForegroundService(
          notificationTitle: 'LibreShare',
          notificationBody: 'Receiving',
        );
        expect(host.activeType, AndroidForegroundServiceType.connectedDevice);

        await host.stopForegroundService();

        expect(host.activeType, AndroidForegroundServiceType.none);
        expect(calls.last.method, 'stopService');
      },
    );

    test('isServiceRunning queries native platform', () async {
      handle((call) async => true);
      final running1 = await host.isServiceRunning();
      expect(running1, isTrue);

      handle((call) async => false);
      final running2 = await host.isServiceRunning();
      expect(running2, isFalse);
    });

    test(
      'restores state after process restart if service still running',
      () async {
        handle((call) async => true);
        final freshHost = AndroidReceiveHost();
        expect(await freshHost.isServiceRunning(), isTrue);
        freshHost.dispose();
      },
    );
  });

  group('timeout handling', () {
    test(
      'notifies onTimeout listener and emits timeoutEvents stream',
      () async {
        int? timeoutStartId;
        int? timeoutFgsType;

        host.setOnTimeoutListener((startId, fgsType) {
          timeoutStartId = startId;
          timeoutFgsType = fgsType;
        });

        final streamCompleter = Completer<ServiceTimeoutEvent>();
        final sub = host.timeoutEvents.listen(streamCompleter.complete);

        // Simulate native platform invoking 'onTimeout' via binary messenger
        final byteData = const StandardMethodCodec().encodeMethodCall(
          const MethodCall('onTimeout', {'startId': 42, 'fgsType': 1}),
        );

        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              kReceiveServiceChannel,
              byteData,
              (ByteData? reply) {},
            );

        expect(timeoutStartId, 42);
        expect(timeoutFgsType, 1);

        final event = await streamCompleter.future;
        expect(event.startId, 42);
        expect(event.fgsType, 1);
        expect(event.serviceType, AndroidForegroundServiceType.dataSync);
        expect(host.activeType, AndroidForegroundServiceType.none);

        await sub.cancel();
      },
    );

    test('handles onTimeout with connectedDevice flag', () async {
      final streamCompleter = Completer<ServiceTimeoutEvent>();
      final sub = host.timeoutEvents.listen(streamCompleter.complete);

      final byteData = const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onTimeout', {'startId': 99, 'fgsType': 16}),
      );

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            kReceiveServiceChannel,
            byteData,
            (ByteData? reply) {},
          );

      final event = await streamCompleter.future;
      expect(event.startId, 99);
      expect(event.fgsType, 16);
      expect(event.serviceType, AndroidForegroundServiceType.connectedDevice);

      await sub.cancel();
    });
  });

  group(
    'security invariants: zero secrets in notifications or channel args',
    () {
      test('throws ArgumentError on pairing secret parameter s=', () async {
        expect(
          () => host.startForegroundService(
            notificationTitle: 'LibreShare',
            notificationBody: 'Incoming invite: s=f0e1d2c3b4a5',
          ),
          throwsArgumentError,
        );
        expect(calls, isEmpty);
      });

      test('throws ArgumentError on privateKey token', () async {
        expect(
          () => host.startForegroundService(
            notificationTitle: 'privateKey: 998877',
            notificationBody: 'Receiving file',
          ),
          throwsArgumentError,
        );
        expect(calls, isEmpty);
      });

      test('throws ArgumentError on full 64-hex fingerprint', () async {
        expect(
          () => host.startForegroundService(
            notificationTitle: 'LibreShare',
            notificationBody: 'From e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
          ),
          throwsArgumentError,
        );
        expect(calls, isEmpty);
      });

      test('throws ArgumentError on PIN leak in notification text', () async {
        expect(
          () => host.startForegroundService(
            notificationTitle: 'PIN required: 123456',
            notificationBody: 'Receiving transfer',
          ),
          throwsArgumentError,
        );
        expect(calls, isEmpty);
      });

      test('asserts all channel arguments contain zero secrets during normal execution', () async {
        await host.startForegroundService(
          notificationTitle: 'LibreShare Receive',
          notificationBody: 'Ready to receive files on local Wi-Fi',
        );

        for (final call in calls) {
          final raw = call.arguments.toString();
          expect(raw.contains('s='), isFalse);
          expect(raw.toLowerCase().contains('secret'), isFalse);
          expect(raw.toLowerCase().contains('pin'), isFalse);
          expect(raw.toLowerCase().contains('privatekey'), isFalse);
          expect(RegExp(r'[0-9a-fA-F]{17,}').hasMatch(raw), isFalse);
        }
      });
    },
  );

  group('graceful degradation', () {
    test('degrades gracefully without native plugin registered', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);

      final unattachedHost = AndroidReceiveHost();
      final result = await unattachedHost.startForegroundService(
        notificationTitle: 'LibreShare',
        notificationBody: 'Offline',
      );

      expect(result, AndroidForegroundServiceType.none);
      expect(await unattachedHost.isServiceRunning(), isFalse);
      await unattachedHost.stopForegroundService(); // must not throw
      unattachedHost.dispose();
    });

    test('NoopReceiveHost functions as safe stub', () async {
      const noop = NoopReceiveHost();
      expect(await noop.isServiceRunning(), isFalse);
      final result = await noop.startForegroundService(
        notificationTitle: 'Title',
        notificationBody: 'Body',
      );
      expect(result, AndroidForegroundServiceType.none);
      await noop.stopForegroundService();
      expect(noop.timeoutEvents, emitsDone);
      noop.dispose();
    });
  });
}
