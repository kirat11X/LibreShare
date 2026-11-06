import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/platform/environment/polling_network_environment.dart';
import 'package:libreshare_core/libreshare_core.dart';

class FakeInterfaces implements NetworkInterfaceProvider {
  FakeInterfaces(this.interfaces);
  List<LocalInterface> interfaces;
  Object? failWith;

  @override
  Future<List<LocalInterface>> list() async {
    final failure = failWith;
    if (failure != null) throw failure;
    return interfaces;
  }
}

LocalInterface iface(String name, String address) => LocalInterface(
  name: name,
  address: InternetAddress(address),
  kind: 'unknown',
);

void main() {
  group('events', () {
    late bool up;
    late bool failing;
    late PollingNetworkEnvironment env;
    late List<EnvEvent> seen;
    late StreamSubscription<EnvEvent> sub;

    // Broadcast streams deliver on a later microtask: let it happen.
    Future<void> poll() async {
      await env.pollOnce();
      await pumpEventQueue();
    }

    setUp(() async {
      up = true;
      failing = false;
      env = PollingNetworkEnvironment(
        interval: null, // polled by hand
        probe: () async {
          if (failing) throw const SocketException('enumeration failed');
          return up;
        },
      );
      seen = [];
      sub = env.events.listen(seen.add);
      await pumpEventQueue();
    });

    tearDown(() async {
      await sub.cancel();
      await env.dispose();
    });

    test('reports the initial state to the first listener', () {
      expect(seen, hasLength(1));
      expect(seen.single, isA<NetworkUp>());
      expect(env.isUp, isTrue);
    });

    test('emits only on transitions', () async {
      await poll();
      await poll();
      expect(seen, hasLength(1));

      up = false;
      await poll();
      await poll();
      expect(seen.map((e) => e.runtimeType), [NetworkUp, NetworkDown]);

      up = true;
      await poll();
      expect(seen.map((e) => e.runtimeType), [
        NetworkUp,
        NetworkDown,
        NetworkUp,
      ]);
    });

    test(
      'an enumeration error keeps the previous state and never throws',
      () async {
        failing = true;
        await poll();
        await poll();
        expect(seen, hasLength(1));
        expect(env.isUp, isTrue);

        failing = false;
        up = false;
        await poll();
        expect(seen.last, isA<NetworkDown>());
      },
    );

    test('dispose closes the stream and stops polling', () async {
      final done = Completer<void>();
      final done2 = env.events.listen((_) {}, onDone: done.complete);
      await env.dispose();
      await done.future.timeout(const Duration(seconds: 2));
      await done2.cancel();
      await poll(); // after dispose: no-op, no throw
      await env.dispose(); // idempotent
    });
  });

  test('a device that boots offline reports NetworkDown first', () async {
    final env = PollingNetworkEnvironment(
      interval: null,
      probe: () async => false,
    );
    final first = env.events.first;
    expect(
      (await first.timeout(const Duration(seconds: 2))),
      isA<NetworkDown>(),
    );
    await env.dispose();
  });

  test('polls on its own timer when an interval is given', () async {
    var up = true;
    final env = PollingNetworkEnvironment(
      interval: const Duration(milliseconds: 20),
      probe: () async => up,
    );
    final events = <EnvEvent>[];
    final sub = env.events.listen(events.add);
    await pumpEventQueue();
    expect(events.single, isA<NetworkUp>());

    up = false;
    await env.events
        .firstWhere((e) => e is NetworkDown)
        .timeout(const Duration(seconds: 2));
    await sub.cancel();
    await env.dispose();
  });

  test('a new listener after cancel gets a fresh initial state', () async {
    final env = PollingNetworkEnvironment(
      interval: null,
      probe: () async => true,
    );
    final first = await env.events.first.timeout(const Duration(seconds: 2));
    expect(first, isA<NetworkUp>());
    final again = await env.events.first.timeout(const Duration(seconds: 2));
    expect(again, isA<NetworkUp>());
    await env.dispose();
  });

  group('interface heuristics', () {
    test('virtual and loopback interface names are recognised', () {
      for (final name in [
        'lo',
        'lo0',
        'docker0',
        'br-3f2a9c',
        'veth12ab',
        'virbr0',
        'vmnet8',
        'vboxnet0',
        'vEthernet (WSL)',
      ]) {
        expect(
          PollingNetworkEnvironment.isVirtualInterface(name),
          isTrue,
          reason: name,
        );
      }
      for (final name in [
        'wlan0',
        'wlp2s0',
        'eth0',
        'enp3s0',
        'Wi-Fi',
        'Ethernet',
        'longname',
      ]) {
        expect(
          PollingNetworkEnvironment.isVirtualInterface(name),
          isFalse,
          reason: name,
        );
      }
    });

    Future<EnvEvent> firstEvent(List<LocalInterface> interfaces) async {
      final env = PollingNetworkEnvironment(
        interval: null,
        provider: FakeInterfaces(interfaces),
      );
      final e = await env.events.first.timeout(const Duration(seconds: 2));
      await env.dispose();
      return e;
    }

    test('only a Docker bridge means no usable network', () async {
      expect(
        await firstEvent([iface('docker0', '172.17.0.1')]),
        isA<NetworkDown>(),
      );
      expect(await firstEvent(const []), isA<NetworkDown>());
    });

    test('link-local (failed DHCP) does not count', () async {
      expect(
        await firstEvent([iface('wlan0', '169.254.12.7')]),
        isA<NetworkDown>(),
      );
    });

    test('a real interface next to a bridge counts', () async {
      expect(
        await firstEvent([
          iface('docker0', '172.17.0.1'),
          iface('wlan0', '192.168.1.20'),
        ]),
        isA<NetworkUp>(),
      );
    });

    test(
      'the system provider works on this machine without throwing',
      () async {
        final env = PollingNetworkEnvironment(interval: null);
        final e = await env.events.first.timeout(const Duration(seconds: 5));
        expect(e, anyOf(isA<NetworkUp>(), isA<NetworkDown>()));
        await env.dispose();
      },
    );
  });
}
