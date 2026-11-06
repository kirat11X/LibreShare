import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/platform/bonsoir_mdns_backend.dart';
import 'package:libreshare_app/platform/platform_log.dart';
import 'package:libreshare_core/libreshare_core.dart';

class FakeBroadcast implements MdnsBroadcastHandle {
  FakeBroadcast({
    required this.name,
    required this.type,
    required this.port,
    required this.txt,
  });

  final String name;
  final String type;
  final int port;
  final Map<String, String> txt;
  Object? startFailure;
  Completer<void>? startGate;
  bool started = false;
  int stopCalls = 0;
  final StreamController<Object> errorController =
      StreamController<Object>.broadcast();

  @override
  Future<void> start() async {
    final gate = startGate;
    if (gate != null) await gate.future;
    final failure = startFailure;
    if (failure != null) throw failure;
    started = true;
  }

  @override
  Stream<Object> get errors => errorController.stream;

  @override
  Future<void> stop() async {
    stopCalls++;
    started = false;
  }
}

class FakeDiscovery implements MdnsDiscoveryHandle {
  FakeDiscovery(this.type);

  final String type;
  Object? startFailure;
  bool started = false;
  int stopCalls = 0;
  final List<String> resolved = [];
  Object? resolveFailure;
  final StreamController<MdnsDiscoveryNotice> controller =
      StreamController<MdnsDiscoveryNotice>.broadcast();

  @override
  Future<void> start() async {
    final failure = startFailure;
    if (failure != null) throw failure;
    started = true;
  }

  @override
  Stream<MdnsDiscoveryNotice> get notices => controller.stream;

  @override
  Future<void> resolve(String instanceName) async {
    resolved.add(instanceName);
    final failure = resolveFailure;
    if (failure != null) throw failure;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    started = false;
  }
}

class FakeGateway implements MdnsGateway {
  /// Applied to every handle created from now on.
  Object? broadcastFailure;
  Object? discoveryFailure;
  Completer<void>? broadcastGate;
  final List<FakeBroadcast> broadcasts = [];
  final List<FakeDiscovery> discoveries = [];

  @override
  MdnsBroadcastHandle createBroadcast({
    required String name,
    required String type,
    required int port,
    required Map<String, String> txt,
  }) {
    final handle = FakeBroadcast(name: name, type: type, port: port, txt: txt)
      ..startFailure = broadcastFailure
      ..startGate = broadcastGate;
    broadcasts.add(handle);
    return handle;
  }

  @override
  MdnsDiscoveryHandle createDiscovery(String type) {
    final handle = FakeDiscovery(type)..startFailure = discoveryFailure;
    discoveries.add(handle);
    return handle;
  }
}

const MdnsService kService = MdnsService(
  name: 'Ann Laptop',
  port: 53318,
  txt: {'id': 'dev-1234', 'fp': '0123456789abcdef', 'v': '1', 'pf': 'linux'},
);

void main() {
  late FakeGateway gateway;
  late BonsoirMdnsBackend backend;
  late List<(PlatformLogLevel, String)> logs;

  setUp(() {
    gateway = FakeGateway();
    // No retry timer, short start timeout: tests drive retries by hand.
    backend = BonsoirMdnsBackend(
      gateway: gateway,
      retryInterval: null,
      startTimeout: const Duration(milliseconds: 200),
    );
    logs = [];
    PlatformLog.sink = (logger, level, message, error) =>
        logs.add((level, message));
  });

  tearDown(() async {
    await backend.dispose();
    PlatformLog.sink = null;
  });

  group('advertise', () {
    test('registers _libreshare._tcp with the engine TXT unchanged', () async {
      await backend.advertise(kService);

      final handle = gateway.broadcasts.single;
      expect(handle.type, '_libreshare._tcp');
      expect(handle.type, kMdnsServiceType);
      expect(handle.name, 'Ann Laptop');
      expect(handle.port, 53318);
      expect(handle.txt, {
        'id': 'dev-1234',
        'fp': '0123456789abcdef',
        'v': '1',
        'pf': 'linux',
      });
      expect(handle.started, isTrue);
      expect(backend.availability, MdnsAvailability.available);
      expect(backend.isAvailable, isTrue);
    });

    test('advertising again replaces the previous registration', () async {
      await backend.advertise(kService);
      await backend.advertise(
        const MdnsService(name: 'Ann Laptop', port: 53319, txt: {'id': 'x'}),
      );
      expect(gateway.broadcasts, hasLength(2));
      expect(gateway.broadcasts.first.stopCalls, 1);
      expect(gateway.broadcasts.last.started, isTrue);
      expect(gateway.broadcasts.last.port, 53319);
    });

    test(
      'stopAdvertising unregisters and is safe to repeat or to call first',
      () async {
        await backend.stopAdvertising(); // never advertised
        await backend.advertise(kService);
        await backend.stopAdvertising();
        await backend.stopAdvertising();
        expect(gateway.broadcasts.single.stopCalls, 1);
        expect(backend.availability, MdnsAvailability.unknown);
      },
    );

    test('fails soft when the OS daemon is missing', () async {
      gateway.broadcastFailure = StateError('org.freedesktop.Avahi not found');
      final changes = <bool>[];
      final sub = backend.availabilityChanges.listen(changes.add);

      await backend.advertise(kService); // must not throw

      await pumpEventQueue();
      expect(backend.isAvailable, isFalse);
      expect(backend.availability, MdnsAvailability.unavailable);
      expect(backend.unavailableReason, isNotNull);
      expect(backend.unavailableReason, contains('StateError'));
      expect(changes, [false]);
      expect(
        logs.where(
          (l) =>
              l.$1 == PlatformLogLevel.warning &&
              l.$2.contains('advertise failed'),
        ),
        hasLength(1),
      );
      // The half-created handle was cleaned up.
      expect(gateway.broadcasts.single.stopCalls, 1);
      await sub.cancel();
    });

    test('a retry after the daemon appears recovers', () async {
      gateway.broadcastFailure = StateError('no avahi');
      await backend.advertise(kService);
      expect(backend.isAvailable, isFalse);

      gateway.broadcastFailure = null;
      final changes = <bool>[];
      final sub = backend.availabilityChanges.listen(changes.add);
      await backend.retryNow();
      await pumpEventQueue();

      expect(backend.isAvailable, isTrue);
      expect(backend.availability, MdnsAvailability.available);
      expect(backend.unavailableReason, isNull);
      expect(gateway.broadcasts.last.started, isTrue);
      expect(changes, [true]);
      await sub.cancel();
    });

    test('retry does nothing when nothing failed', () async {
      await backend.advertise(kService);
      await backend.retryNow();
      expect(gateway.broadcasts, hasLength(1));
    });

    test(
      'the retry timer re-attempts a failed registration by itself',
      () async {
        final timed = BonsoirMdnsBackend(
          gateway: gateway,
          retryInterval: const Duration(milliseconds: 30),
          startTimeout: const Duration(milliseconds: 200),
        );
        gateway.broadcastFailure = StateError('no avahi');
        await timed.advertise(kService);
        expect(timed.isAvailable, isFalse);

        gateway.broadcastFailure = null;
        await timed.availabilityChanges
            .firstWhere((available) => available)
            .timeout(const Duration(seconds: 3));
        expect(timed.availability, MdnsAvailability.available);
        await timed.dispose();
      },
    );

    test(
      'a hung start (D-Bus never answers) times out and fails soft',
      () async {
        gateway.broadcastGate = Completer<void>(); // never completed
        await backend.advertise(kService);
        expect(backend.isAvailable, isFalse);
        expect(backend.unavailableReason, contains('TimeoutException'));
      },
    );

    test(
      'a failure reported after start (daemon died) flips to unavailable',
      () async {
        await backend.advertise(kService);
        gateway.broadcasts.single.errorController.add(
          StateError('daemon died'),
        );
        await pumpEventQueue();
        await backend.retryNow(); // flush the queue; next attempt succeeds
        expect(gateway.broadcasts, hasLength(2));
        expect(gateway.broadcasts.first.stopCalls, 1);
        expect(backend.isAvailable, isTrue);
      },
    );
  });

  group('browse', () {
    test(
      'starts on listen, resolves found services, emits resolved peers',
      () async {
        final peers = <MdnsPeer>[];
        final sub = backend.browse().listen(peers.add);
        await pumpEventQueue();

        final discovery = gateway.discoveries.single;
        expect(discovery.type, '_libreshare._tcp');
        expect(discovery.started, isTrue);
        expect(backend.availability, MdnsAvailability.available);

        discovery.controller.add(const MdnsServiceFound('Bob Phone'));
        await pumpEventQueue();
        expect(discovery.resolved, ['Bob Phone']);

        discovery.controller.add(
          const MdnsServiceResolved(
            MdnsPeer(
              name: 'Bob Phone',
              addresses: ['192.168.1.30'],
              port: 53318,
              txt: {
                'id': 'dev-b',
                'fp': 'fedcba9876543210',
                'v': '1',
                'pf': 'android',
              },
            ),
          ),
        );
        discovery.controller.add(const MdnsServiceLost('Bob Phone'));
        discovery.controller.add(const MdnsServiceResolveFailed());
        await pumpEventQueue();

        expect(peers, hasLength(1));
        expect(peers.single.name, 'Bob Phone');
        expect(peers.single.addresses, ['192.168.1.30']);
        expect(peers.single.port, 53318);
        expect(peers.single.txt['id'], 'dev-b');
        await sub.cancel();
      },
    );

    test('a resolve error is swallowed', () async {
      final sub = backend.browse().listen((_) {});
      await pumpEventQueue();
      final discovery = gateway.discoveries.single;
      discovery.resolveFailure = StateError('resolver gone');
      discovery.controller.add(const MdnsServiceFound('Bob Phone'));
      await pumpEventQueue();
      expect(backend.isAvailable, isTrue);
      await sub.cancel();
    });

    test(
      'fails soft: the stream stays open and silent without a daemon',
      () async {
        gateway.discoveryFailure = StateError('no avahi');
        final peers = <MdnsPeer>[];
        var done = false;
        final errors = <Object>[];
        final sub = backend.browse().listen(
          peers.add,
          onError: errors.add,
          onDone: () => done = true,
        );
        await pumpEventQueue();

        expect(backend.isAvailable, isFalse);
        expect(peers, isEmpty);
        expect(errors, isEmpty);
        expect(done, isFalse);

        // The daemon shows up later: a retry starts delivering peers.
        gateway.discoveryFailure = null;
        await backend.retryNow();
        gateway.discoveries.last.controller.add(
          const MdnsServiceResolved(
            MdnsPeer(
              name: 'Bob',
              addresses: ['10.0.0.2'],
              port: 53318,
              txt: {'id': 'b'},
            ),
          ),
        );
        await pumpEventQueue();
        expect(backend.isAvailable, isTrue);
        expect(peers, hasLength(1));
        await sub.cancel();
      },
    );

    test('a browse that dies at runtime is restarted by the retry', () async {
      final sub = backend.browse().listen((_) {});
      await pumpEventQueue();
      gateway.discoveries.single.controller.addError(StateError('boom'));
      await pumpEventQueue();
      expect(backend.isAvailable, isFalse);
      expect(gateway.discoveries.single.stopCalls, 1);

      await backend.retryNow();
      expect(backend.isAvailable, isTrue);
      expect(gateway.discoveries, hasLength(2));
      await sub.cancel();
    });

    test('cancelling the subscription stops the discovery', () async {
      final sub = backend.browse().listen((_) {});
      await pumpEventQueue();
      await sub.cancel();
      await pumpEventQueue();
      expect(gateway.discoveries.single.stopCalls, 1);
      expect(backend.availability, MdnsAvailability.unknown);
    });

    test(
      'stopBrowsing stops the discovery, closes the stream, and is repeatable',
      () async {
        var done = false;
        final sub = backend.browse().listen((_) {}, onDone: () => done = true);
        await pumpEventQueue();
        await backend.stopBrowsing();
        await backend.stopBrowsing();
        await pumpEventQueue();
        expect(done, isTrue);
        expect(gateway.discoveries.single.stopCalls, 1);
        await sub.cancel();
      },
    );

    test('a second browse() replaces the first', () async {
      var firstDone = false;
      final first = backend.browse().listen(
        (_) {},
        onDone: () => firstDone = true,
      );
      await pumpEventQueue();
      final peers = <MdnsPeer>[];
      final second = backend.browse().listen(peers.add);
      await pumpEventQueue();

      expect(firstDone, isTrue);
      expect(gateway.discoveries, hasLength(2));
      expect(gateway.discoveries.first.stopCalls, 1);
      gateway.discoveries.last.controller.add(
        const MdnsServiceResolved(
          MdnsPeer(
            name: 'Bob',
            addresses: ['10.0.0.2'],
            port: 1,
            txt: {'id': 'b'},
          ),
        ),
      );
      await pumpEventQueue();
      expect(peers, hasLength(1));
      await first.cancel();
      await second.cancel();
    });
  });

  group('lifecycle', () {
    test(
      'advertise and browse together; availability needs both healthy',
      () async {
        gateway.discoveryFailure = StateError('browse down');
        await backend.advertise(kService);
        final sub = backend.browse().listen((_) {});
        await pumpEventQueue();
        expect(gateway.broadcasts.single.started, isTrue);
        expect(backend.isAvailable, isFalse, reason: 'one of the two failed');
        await sub.cancel();
      },
    );

    test('dispose stops everything, closes the change stream and ignores later calls', () async {
      await backend.advertise(kService);
      final sub = backend.browse().listen((_) {});
      await pumpEventQueue();
      var closed = false;
      backend.availabilityChanges.listen((_) {}, onDone: () => closed = true);

      await backend.dispose();
      await backend.dispose();
      await pumpEventQueue();

      expect(gateway.broadcasts.single.stopCalls, 1);
      expect(gateway.discoveries.single.stopCalls, 1);
      expect(closed, isTrue);
      await backend.advertise(kService); // no-op, no throw
      expect(gateway.broadcasts, hasLength(1));
      await sub.cancel();
    });
  });

  group('helpers', () {
    test('sanitizeInstanceName: control chars, trailing dots, 63 bytes', () {
      expect(
        BonsoirMdnsBackend.sanitizeInstanceName('Ann\u0000\n Laptop'),
        'Ann Laptop',
      );
      expect(BonsoirMdnsBackend.sanitizeInstanceName('  Ann. . '), 'Ann');
      expect(BonsoirMdnsBackend.sanitizeInstanceName(''), 'LibreShare');
      expect(BonsoirMdnsBackend.sanitizeInstanceName('\u0007'), 'LibreShare');

      final long = BonsoirMdnsBackend.sanitizeInstanceName('a' * 100);
      expect(utf8.encode(long), hasLength(63));

      // Multi-byte characters are never split: 21 x 3-byte runes = 63 bytes.
      final cjk = BonsoirMdnsBackend.sanitizeInstanceName('中' * 30);
      expect(utf8.encode(cjk), hasLength(63));
      expect(cjk, '中' * 21);
    });

    test(
      'cleanTxt keeps the engine keys and never returns an empty record',
      () {
        expect(BonsoirMdnsBackend.cleanTxt(kService.txt), kService.txt);
        expect(BonsoirMdnsBackend.cleanTxt(const {}), isNotEmpty);
        expect(BonsoirMdnsBackend.cleanTxt({'': 'x', 'id': 'y'}), {'id': 'y'});
      },
    );

    test(
      'peerFrom: IPv4 first, deduplicated; unusable answers are dropped',
      () {
        final peer = BonsoirMdnsBackend.peerFrom(
          name: 'Bob',
          addresses: ['fe80::1', '192.168.1.5', '192.168.1.5', ' ', '10.0.0.9'],
          port: 53318,
          txt: const {'id': 'b'},
        )!;
        expect(peer.addresses, ['192.168.1.5', '10.0.0.9', 'fe80::1']);
        expect(peer.port, 53318);

        expect(
          BonsoirMdnsBackend.peerFrom(
            name: 'x',
            addresses: const [],
            port: 1,
            txt: const {},
          ),
          isNull,
        );
        expect(
          BonsoirMdnsBackend.peerFrom(
            name: 'x',
            addresses: const ['10.0.0.1'],
            port: 0,
            txt: const {},
          ),
          isNull,
        );
        expect(
          BonsoirMdnsBackend.peerFrom(
            name: 'x',
            addresses: const ['10.0.0.1'],
            port: 70000,
            txt: const {},
          ),
          isNull,
        );
      },
    );
  });

  group('real bonsoir adapter without a registered plugin', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    test('advertise and browse fail soft instead of throwing', () async {
      final real = BonsoirMdnsBackend(
        retryInterval: null,
        startTimeout: const Duration(seconds: 2),
      );
      await real.advertise(kService);
      expect(real.isAvailable, isFalse);

      final peers = <MdnsPeer>[];
      final sub = real.browse().listen(peers.add);
      await pumpEventQueue(times: 50);
      expect(peers, isEmpty);
      expect(real.isAvailable, isFalse);
      await sub.cancel();
      await real.dispose();
    });
  });
}
