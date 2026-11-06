import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/platform/android/multicast_lock_android.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(kMulticastLockChannel);
  late List<String> calls;
  late AndroidMulticastLock lock;

  void handle(Future<Object?>? Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return handler(call);
        });
  }

  setUp(() {
    calls = [];
    lock = AndroidMulticastLock();
    handle((call) async => 1);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('uses the documented channel name', () {
    expect(kMulticastLockChannel, 'dev.libreshare/multicast_lock');
  });

  test('acquire and release call the native side', () async {
    await lock.acquire();
    expect(lock.holders, 1);
    await lock.release();
    expect(lock.holders, 0);
    expect(calls, ['acquire', 'release']);
  });

  test('reference counting: two acquires need two releases', () async {
    await lock.acquire();
    await lock.acquire();
    expect(lock.holders, 2);
    await lock.release();
    expect(lock.holders, 1);
    await lock.release();
    expect(lock.holders, 0);
    expect(calls, ['acquire', 'acquire', 'release', 'release']);
  });

  test(
    'an unbalanced release is ignored and never reaches the platform',
    () async {
      await lock.release();
      expect(calls, isEmpty);
      expect(lock.holders, 0);
    },
  );

  test(
    'a native failure (missing permission) is swallowed and not counted',
    () async {
      handle((call) async => throw PlatformException(code: 'permission'));
      await lock.acquire(); // must not throw
      expect(lock.holders, 0);
    },
  );

  test('a native failure on release is swallowed', () async {
    await lock.acquire();
    handle((call) async => throw PlatformException(code: 'release_failed'));
    await lock.release(); // must not throw
    expect(lock.holders, 0);
  });

  test(
    'without the Kotlin side (other platforms, tests) it degrades quietly',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await lock.acquire();
      await lock.release();
      expect(lock.holders, 0);
    },
  );

  test('NoopMulticastLock does nothing', () async {
    const noop = NoopMulticastLock();
    await noop.acquire();
    await noop.release();
    expect(calls, isEmpty);
  });
}
