import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:libreshare_core/src/ble/beacon_codec.dart';
import 'package:libreshare_core/src/ble/beacon_types.dart';
import 'package:libreshare_core/src/ble/ble_backend.dart';
import 'package:libreshare_core/src/ble/gatt_frame_codec.dart';
import 'package:libreshare_core/src/ble/testing/fake_ble_bus.dart';
import 'package:libreshare_core/src/ble/visibility_manager.dart';
import 'package:libreshare_core/src/clock.dart';
import 'package:test/test.dart';

class FakeClock implements Clock {
  FakeClock(this._now);
  DateTime _now;

  @override
  DateTime now() => _now;

  void advance(Duration d) => _now = _now.add(d);
}

void main() {
  group('Beacon Codec & EID Golden Vectors (Design 03 section 3.3)', () {
    // advKey = 00 01 02 ... 1f
    final advKey = Uint8List.fromList(List.generate(32, (i) => i));

    test('matches exact design 03 golden vectors for epoch 1993008', () {
      // Vector: epoch 1993008 is 2026-11-03T12:00:00Z (unix seconds 1793707200)
      final t = DateTime.fromMillisecondsSinceEpoch(
        1793707200 * 1000,
        isUtc: true,
      );
      expect(epochForTime(t), 1993008);

      final eidPrev = deriveEid(advKey, 1993007);
      final eidCurr = deriveEid(advKey, 1993008);
      final eidNext = deriveEid(advKey, 1993009);

      String toHex(Uint8List b) =>
          b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

      expect(toHex(eidPrev), '1efb0334b7b6ecb8');
      expect(toHex(eidCurr), '6fa9eb55a49a9152');
      expect(toHex(eidNext), 'a42f3d6f2c801a6b');
    });

    test('matchesEid verifies epochs +/- 1 and rejects +/- 2', () {
      final t = DateTime.fromMillisecondsSinceEpoch(
        1793707200 * 1000,
        isUtc: true,
      );
      final eidPrev = deriveEid(advKey, 1993007);
      final eidCurr = deriveEid(advKey, 1993008);
      final eidNext = deriveEid(advKey, 1993009);
      final eidFarPrev = deriveEid(advKey, 1993006);
      final eidFarNext = deriveEid(advKey, 1993010);

      expect(matchesEid(eidPrev, advKey, t), isTrue);
      expect(matchesEid(eidCurr, advKey, t), isTrue);
      expect(matchesEid(eidNext, advKey, t), isTrue);
      expect(matchesEid(eidFarPrev, advKey, t), isFalse);
      expect(matchesEid(eidFarNext, advKey, t), isFalse);
    });

    test('generateRandomEid returns 8 non-zero bytes', () {
      final r1 = generateRandomEid();
      final r2 = generateRandomEid();
      expect(r1.length, 8);
      expect(r2.length, 8);
      expect(r1, isNot(equals(r2)));
    });
  });

  group('VisibilityManager state transitions & 10-minute time-box', () {
    final advKey = Uint8List.fromList(List.generate(32, (i) => i));

    test('Hidden -> Contacts -> Everyone -> auto-revert to Contacts', () async {
      final clock = FakeClock(DateTime.utc(2026, 11, 7, 12, 0));
      final vm = VisibilityManager(
        advKey: advKey,
        clock: clock,
        everyoneDuration: const Duration(milliseconds: 100),
      );
      addTearDown(vm.dispose);

      expect(vm.currentState.mode, VisibilityMode.hidden);
      expect(vm.currentState.activeEid, isNull);

      vm.setContacts();
      expect(vm.currentState.mode, VisibilityMode.contacts);
      expect(vm.currentState.activeEid, isNotNull);
      final contactsEid = vm.currentState.activeEid!;
      expect(matchesEid(contactsEid, advKey, clock.now()), isTrue);

      vm.setEveryone(duration: const Duration(milliseconds: 100));
      expect(vm.currentState.mode, VisibilityMode.everyone);
      final everyoneEid = vm.currentState.activeEid!;
      expect(everyoneEid.length, 8);
      expect(vm.currentState.everyoneExpiresAt, isNotNull);

      // Wait for 100ms time-box expiration
      await Future<void>.delayed(const Duration(milliseconds: 120));

      // Must have automatically reverted to Contacts mode
      expect(vm.currentState.mode, VisibilityMode.contacts);
      expect(vm.currentState.everyoneExpiresAt, isNull);
    });
  });

  group('GATT Frame Codec Fragmentation & Reassembly (Fuzz & Edge cases)', () {
    test('fragment and reassemble empty message', () {
      final frames = fragmentMessage(const []);
      expect(frames.length, 1);
      final reassembler = GattFrameReassembler();
      final result = reassembler.processFrame(frames.single);
      expect(result, isNotNull);
      expect(result!, isEmpty);
    });

    test('fragment and reassemble exact 2 KiB boundary', () {
      final payload = Uint8List.fromList(List.generate(2048, (i) => i % 256));
      final frames = fragmentMessage(
        payload,
        mtu: 23,
      ); // 19 B chunks -> 108 frames
      expect(frames.length, (2048 / 19).ceil());

      final reassembler = GattFrameReassembler();
      Uint8List? complete;
      for (final f in frames) {
        complete = reassembler.processFrame(f);
      }
      expect(complete, isNotNull);
      expect(complete!, equals(payload));
    });

    test('detects sequence gaps and rejects out-of-order frames', () {
      final payload = Uint8List.fromList(List.generate(100, (i) => i));
      final frames = fragmentMessage(payload, mtu: 23);
      expect(frames.length, greaterThan(2));

      final reassembler = GattFrameReassembler();
      reassembler.processFrame(frames[0]);
      // Skip frames[1], feed frames[2]
      expect(
        () => reassembler.processFrame(frames[2]),
        throwsA(isA<FormatException>()),
      );
      // Reassembler must have reset
      expect(reassembler.inProgress, isFalse);
    });

    test(
      'fuzz fragmentation and reassembly across random MTU and payload sizes',
      () {
        final rnd = Random(42);
        for (var iter = 0; iter < 100; iter++) {
          final payloadSize = rnd.nextInt(kMaxGattMessageSize + 1);
          final payload = Uint8List.fromList(
            List.generate(payloadSize, (_) => rnd.nextInt(256)),
          );
          final mtu = rnd.nextInt(240) + 20; // MTU between 20 and 260

          final frames = fragmentMessage(payload, mtu: mtu);
          final reassembler = GattFrameReassembler();
          Uint8List? result;
          for (final f in frames) {
            result = reassembler.processFrame(f);
          }
          expect(
            result,
            isNotNull,
            reason:
                'Failed at iteration $iter with size $payloadSize, mtu $mtu',
          );
          expect(result!, equals(payload));
        }
      },
    );
  });

  group('FakeBleBus simulated medium', () {
    test('advertiser broadcast is delivered to active scanner', () async {
      final bus = FakeBleBus();
      final backendTx = bus.createBackend(
        deviceId: 'dev_tx',
        address: 'AA:BB:CC:DD:EE:01',
      );
      final backendRx = bus.createBackend(
        deviceId: 'dev_rx',
        address: 'AA:BB:CC:DD:EE:02',
      );

      final discovered = <BleDevice>[];
      final sub = backendRx.scan().listen(discovered.add);
      addTearDown(sub.cancel);

      final beacon = BleBeacon(
        flags: const BeaconFlags(recv: true, gatt: true),
        cap: const BeaconCap(canHost: true),
        eid: [1, 2, 3, 4, 5, 6, 7, 8],
        seq: 42,
      );

      await backendTx.startAdvertising(beacon, connectable: true);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(discovered.isNotEmpty, isTrue);
      final dev = discovered.first;
      expect(dev.id, 'dev_tx');
      expect(dev.beacon, isNotNull);
      expect(dev.beacon!.seq, 42);
    });

    test('bidirectional GATT session data exchange over FakeBleBus', () async {
      final bus = FakeBleBus();
      final backendTx = bus.createBackend(deviceId: 'dev_tx', address: 'AA:01');
      final backendRx = bus.createBackend(deviceId: 'dev_rx', address: 'AA:02');

      final beacon = BleBeacon(
        flags: const BeaconFlags(recv: true, gatt: true),
        cap: const BeaconCap(canHost: true),
        eid: [1, 1, 1, 1, 2, 2, 2, 2],
        seq: 10,
      );
      await backendRx.startAdvertising(beacon, connectable: true);

      final serverSessionCompleter = Completer<BleGattSession>();
      final sub = backendRx.gattServer.incomingSessions.listen(
        serverSessionCompleter.complete,
      );
      addTearDown(sub.cancel);

      // Central connects to Peripheral
      final clientSession = await backendTx.connectGatt('dev_rx');
      final serverSession = await serverSessionCompleter.future;

      final serverReceived = <List<int>>[];
      final clientReceived = <List<int>>[];

      final subServer = serverSession.received.listen(serverReceived.add);
      final subClient = clientSession.received.listen(clientReceived.add);
      addTearDown(subServer.cancel);
      addTearDown(subClient.cancel);

      // Client sends to Server
      await clientSession.send([10, 20, 30]);
      // Server sends to Client
      await serverSession.send([40, 50, 60]);

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(serverReceived, hasLength(1));
      expect(serverReceived.single, equals([10, 20, 30]));
      expect(clientReceived, hasLength(1));
      expect(clientReceived.single, equals([40, 50, 60]));

      await clientSession.close();
      await serverSession.close();
      expect(clientSession.isClosed, isTrue);
      expect(serverSession.isClosed, isTrue);
    });
  });
}
