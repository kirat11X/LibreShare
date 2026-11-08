import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:libreshare_core/src/ble/beacon_types.dart';
import 'package:libreshare_core/src/ble/ble_backend.dart';
import 'package:libreshare_core/src/ble/ble_crypto.dart';
import 'package:libreshare_core/src/ble/ble_messages.dart';
import 'package:libreshare_core/src/ble/ble_session.dart';
import 'package:libreshare_core/src/ble/gatt_frame_codec.dart';
import 'package:libreshare_core/src/ble/testing/fake_ble_bus.dart';
import 'package:test/test.dart';

void main() {
  group('BleAeadCipher & Ephemeral Key Agreement', () {
    test('X25519/ECDH key agreement derives identical shared secrets', () {
      final alice = BleEphemeralKeyPair.generate();
      final bob = BleEphemeralKeyPair.generate();

      final ssAlice = alice.calculateSharedSecret(bob.publicKeyBase64);
      final ssBob = bob.calculateSharedSecret(alice.publicKeyBase64);

      expect(ssAlice.length, 32);
      expect(ssAlice, equals(ssBob));
    });

    test(
      'BleAeadCipher encrypts, decrypts, and enforces replay protection',
      () {
        final key = Uint8List.fromList(List.generate(32, (i) => i));
        final th = Uint8List.fromList(List.generate(32, (i) => 255 - i));

        final sender = BleAeadCipher(
          key: key,
          direction: 1,
          transcriptHash: th,
        );
        final receiver = BleAeadCipher(
          key: key,
          direction: 1,
          transcriptHash: th,
        );

        final msg1 = utf8.encode('Message one');
        final msg2 = utf8.encode('Message two');

        final sealed1 = sender.seal(msg1);
        final sealed2 = sender.seal(msg2);

        // In-order delivery succeeds
        expect(receiver.open(sealed1), equals(msg1));
        expect(receiver.open(sealed2), equals(msg2));

        // Replay of msg1 must be rejected
        expect(() => receiver.open(sealed1), throwsA(isA<FormatException>()));
      },
    );

    test('BleAeadCipher rejects tampered ciphertext and modified tag', () {
      final key = Uint8List.fromList(List.generate(32, (i) => i));
      final th = Uint8List.fromList(List.generate(32, (i) => 255 - i));

      final sender = BleAeadCipher(key: key, direction: 1, transcriptHash: th);
      final receiver = BleAeadCipher(
        key: key,
        direction: 1,
        transcriptHash: th,
      );

      final sealed = sender.seal(utf8.encode('Sensitive payload'));
      // Flip a bit in the ciphertext payload
      sealed[sealed.length - 1] ^= 0x01;

      expect(() => receiver.open(sealed), throwsA(isA<FormatException>()));
    });

    test('Redaction check: secret material is not exposed in toString()', () {
      final keyPair = BleEphemeralKeyPair.generate();
      final cipher = BleAeadCipher(
        key: Uint8List(32),
        direction: 1,
        transcriptHash: Uint8List(32),
      );

      final kpString = keyPair.toString();
      expect(kpString, contains('BleEphemeralKeyPair'));
      expect(kpString, isNot(contains('privateKey')));

      final cipherString = cipher.toString();
      expect(cipherString, contains('BleAeadCipher'));
      expect(cipherString, isNot(contains('key:')));
    });
  });

  group('BleSession Handshake & End-to-End Security', () {
    late FakeBleBus bus;
    late KeyIdentity idCentral;
    late KeyIdentity idPeripheral;

    setUp(() {
      bus = FakeBleBus();
      idCentral = KeyIdentity.fromGenerated(
        generateIdentityFor('central-dev-1'),
      );
      idPeripheral = KeyIdentity.fromGenerated(
        generateIdentityFor('peripheral-dev-2'),
      );
    });

    test('Successful mutual authentication and SAS code equality', () async {
      final backendCentral = bus.createBackend(
        deviceId: 'dev_c',
        address: 'AA:01',
      );
      final backendPeripheral = bus.createBackend(
        deviceId: 'dev_p',
        address: 'AA:02',
      );

      final incomingCompleter = Completer<BleGattSession>();
      final sub = backendPeripheral.gattServer.incomingSessions.listen(
        incomingCompleter.complete,
      );
      addTearDown(sub.cancel);

      await backendPeripheral.startAdvertising(
        BleBeacon(
          flags: const BeaconFlags(recv: true, gatt: true),
          cap: const BeaconCap(canHost: true),
          eid: [1, 2, 3, 4, 5, 6, 7, 8],
          seq: 1,
        ),
        connectable: true,
      );

      final centralGatt = await backendCentral.connectGatt('dev_p');
      final peripheralGatt = await incomingCompleter.future;

      final sessionCentral = BleSession(
        gatt: centralGatt,
        role: BleSessionRole.central,
        identity: idCentral,
      );
      final sessionPeripheral = BleSession(
        gatt: peripheralGatt,
        role: BleSessionRole.peripheral,
        identity: idPeripheral,
      );

      final centralFuture = sessionCentral.performHandshake(
        localAlias: 'Alice Central',
        localPlatform: 'linux',
      );
      final peripheralFuture = sessionPeripheral.performHandshake(
        localAlias: 'Bob Peripheral',
        localPlatform: 'android',
      );

      final (resCentral, resPeripheral) = await (
        centralFuture,
        peripheralFuture,
      ).wait;

      expect(resCentral.peerAlias, 'Bob Peripheral');
      expect(resCentral.peerPlatform, 'android');
      expect(resCentral.peerFingerprint, idPeripheral.identity.fingerprint);

      expect(resPeripheral.peerAlias, 'Alice Central');
      expect(resPeripheral.peerPlatform, 'linux');
      expect(resPeripheral.peerFingerprint, idCentral.identity.fingerprint);

      // Both peers MUST calculate the exact same SAS code
      expect(resCentral.sasCode, isNotEmpty);
      expect(resCentral.sasCode, equals(resPeripheral.sasCode));

      expect(sessionCentral.state, BleSessionState.authenticated);
      expect(sessionPeripheral.state, BleSessionState.authenticated);

      // Exchange application messages over the encrypted GATT channel
      final peripheralMessages = <BleMessage>[];
      final centralMessages = <BleMessage>[];

      final subP = sessionPeripheral.incomingMessages.listen(
        peripheralMessages.add,
      );
      final subC = sessionCentral.incomingMessages.listen(centralMessages.add);
      addTearDown(subP.cancel);
      addTearDown(subC.cancel);

      const offer = BleOffer(
        offerId: 'offer_test_1234',
        fileCount: 1,
        totalSize: 5000,
        firstName: 'test.dat',
      );
      await sessionCentral.send(offer);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(peripheralMessages, hasLength(1));
      final receivedOffer = peripheralMessages.first as BleOffer;
      expect(receivedOffer.offerId, 'offer_test_1234');
      expect(receivedOffer.totalSize, 5000);

      const decision = BleDecision(offerId: 'offer_test_1234', accept: true);
      await sessionPeripheral.send(decision);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(centralMessages, hasLength(1));
      final receivedDecision = centralMessages.first as BleDecision;
      expect(receivedDecision.offerId, 'offer_test_1234');
      expect(receivedDecision.accept, isTrue);

      await sessionCentral.close();
      await sessionPeripheral.close();
      expect(sessionCentral.state, BleSessionState.closed);
      expect(sessionPeripheral.state, BleSessionState.closed);
    });

    test(
      'Fingerprint mismatch aborts handshake with BleSecurityException',
      () async {
        final backendCentral = bus.createBackend(
          deviceId: 'dev_c',
          address: 'AA:01',
        );
        final backendPeripheral = bus.createBackend(
          deviceId: 'dev_p',
          address: 'AA:02',
        );

        final incomingCompleter = Completer<BleGattSession>();
        final sub = backendPeripheral.gattServer.incomingSessions.listen(
          incomingCompleter.complete,
        );
        addTearDown(sub.cancel);

        await backendPeripheral.startAdvertising(
          BleBeacon(
            flags: const BeaconFlags(recv: true, gatt: true),
            cap: const BeaconCap(canHost: true),
            eid: [1, 2, 3, 4, 5, 6, 7, 8],
            seq: 1,
          ),
          connectable: true,
        );

        final centralGatt = await backendCentral.connectGatt('dev_p');
        final peripheralGatt = await incomingCompleter.future;

        // Central expects a specific trusted fingerprint, but Peripheral has a different one
        final sessionCentral = BleSession(
          gatt: centralGatt,
          role: BleSessionRole.central,
          identity: idCentral,
          expectedPeerFingerprint: '00' * 32, // wrong expected fingerprint
        );
        final sessionPeripheral = BleSession(
          gatt: peripheralGatt,
          role: BleSessionRole.peripheral,
          identity: idPeripheral,
        );

        final centralFuture = sessionCentral.performHandshake(
          localAlias: 'Alice',
          localPlatform: 'linux',
        );
        final peripheralFuture = sessionPeripheral.performHandshake(
          localAlias: 'Bob',
          localPlatform: 'android',
        );

        expect(centralFuture, throwsA(isA<BleSecurityException>()));
        try {
          await peripheralFuture;
        } on Object {
          // Expected closure
        }
      },
    );

    test('Tampered M1 causes peripheral handshake failure', () async {
      final backendCentral = bus.createBackend(
        deviceId: 'dev_c',
        address: 'AA:01',
      );
      final backendPeripheral = bus.createBackend(
        deviceId: 'dev_p',
        address: 'AA:02',
      );

      final incomingCompleter = Completer<BleGattSession>();
      final sub = backendPeripheral.gattServer.incomingSessions.listen(
        incomingCompleter.complete,
      );
      addTearDown(sub.cancel);

      await backendPeripheral.startAdvertising(
        BleBeacon(
          flags: const BeaconFlags(recv: true, gatt: true),
          cap: const BeaconCap(canHost: true),
          eid: [1, 2, 3, 4, 5, 6, 7, 8],
          seq: 1,
        ),
        connectable: true,
      );

      final centralGatt = await backendCentral.connectGatt('dev_p');
      final peripheralGatt = await incomingCompleter.future;

      final sessionPeripheral = BleSession(
        gatt: peripheralGatt,
        role: BleSessionRole.peripheral,
        identity: idPeripheral,
      );

      final peripheralFuture = sessionPeripheral.performHandshake(
        localAlias: 'Bob',
        localPlatform: 'android',
      );

      // Central sends malformed/tampered M1 JSON
      final badM1 = utf8.encode(
        '{"type":"m1","v":1,"epk":"not_valid_base64_point!@#"}',
      );
      final frames = fragmentMessage(badM1);
      for (final f in frames) {
        await centralGatt.send(f);
      }

      expect(peripheralFuture, throwsA(isA<BleSecurityException>()));
    });

    test('Tampered M2 causes central handshake failure', () async {
      final backendCentral = bus.createBackend(
        deviceId: 'dev_c',
        address: 'AA:01',
      );
      final backendPeripheral = bus.createBackend(
        deviceId: 'dev_p',
        address: 'AA:02',
      );

      final incomingCompleter = Completer<BleGattSession>();
      final sub = backendPeripheral.gattServer.incomingSessions.listen(
        incomingCompleter.complete,
      );
      addTearDown(sub.cancel);

      await backendPeripheral.startAdvertising(
        BleBeacon(
          flags: const BeaconFlags(recv: true, gatt: true),
          cap: const BeaconCap(canHost: true),
          eid: [1, 2, 3, 4, 5, 6, 7, 8],
          seq: 1,
        ),
        connectable: true,
      );

      final centralGatt = await backendCentral.connectGatt('dev_p');
      final peripheralGatt = await incomingCompleter.future;

      final sessionCentral = BleSession(
        gatt: centralGatt,
        role: BleSessionRole.central,
        identity: idCentral,
      );

      final centralFuture = sessionCentral.performHandshake(
        localAlias: 'Alice',
        localPlatform: 'linux',
      );

      // Read M1 from Central
      final reassembler = GattFrameReassembler();
      final iterator = StreamIterator(peripheralGatt.received);
      while (await iterator.moveNext()) {
        final complete = reassembler.processFrame(iterator.current);
        if (complete != null) break;
      }

      // Peripheral responds with corrupted M2
      final badM2 = utf8.encode(
        '{"type":"m2","v":1,"epk":"invalid_m2_key","n":"n2"}',
      );
      for (final f in fragmentMessage(badM2)) {
        await peripheralGatt.send(f);
      }

      expect(centralFuture, throwsA(isA<BleSecurityException>()));
    });

    test('Tampered AUTH signature aborts handshake', () async {
      final backendCentral = bus.createBackend(
        deviceId: 'dev_c',
        address: 'AA:01',
      );
      final backendPeripheral = bus.createBackend(
        deviceId: 'dev_p',
        address: 'AA:02',
      );

      final incomingCompleter = Completer<BleGattSession>();
      final sub = backendPeripheral.gattServer.incomingSessions.listen(
        incomingCompleter.complete,
      );
      addTearDown(sub.cancel);

      await backendPeripheral.startAdvertising(
        BleBeacon(
          flags: const BeaconFlags(recv: true, gatt: true),
          cap: const BeaconCap(canHost: true),
          eid: [1, 2, 3, 4, 5, 6, 7, 8],
          seq: 1,
        ),
        connectable: true,
      );

      final centralGatt = await backendCentral.connectGatt('dev_p');
      final peripheralGatt = await incomingCompleter.future;

      final sessionCentral = BleSession(
        gatt: centralGatt,
        role: BleSessionRole.central,
        identity: idCentral,
      );

      final centralFuture = sessionCentral.performHandshake(
        localAlias: 'Alice',
        localPlatform: 'linux',
      );

      // Peripheral manually does M1/M2 then sends corrupted signature in AUTH
      final iterator = StreamIterator(peripheralGatt.received);
      final reassembler = GattFrameReassembler();
      Uint8List? m1Bytes;
      while (await iterator.moveNext()) {
        final c = reassembler.processFrame(iterator.current);
        if (c != null) {
          m1Bytes = c;
          break;
        }
      }
      final m1 = BleM1.fromJson(
        jsonDecode(utf8.decode(m1Bytes!)) as Map<String, Object?>,
      );
      final pEpk = BleEphemeralKeyPair.generate();
      final pNonce = generateBleNonce();
      final m2 = BleM2(epk: pEpk.publicKeyBase64, n: pNonce, capEcho: 0);
      for (final f in fragmentMessage(utf8.encode(m2.encode()))) {
        await peripheralGatt.send(f);
      }

      final ss = pEpk.calculateSharedSecret(m1.epk);
      final th = computeTranscriptHash(m1, m2);
      final (kC2P, kP2C) = deriveChannelKeys(
        sharedSecret: ss,
        transcriptHash: th,
      );
      final pCipher = BleAeadCipher(
        key: kP2C,
        direction: 2,
        transcriptHash: th,
      );

      // Read Central's AUTH
      reassembler.dispose();
      final reassembler2 = GattFrameReassembler();
      while (await iterator.moveNext()) {
        final c = reassembler2.processFrame(iterator.current);
        if (c != null) break;
      }

      // Peripheral sends bad AUTH with forged/tampered signature
      final badAuth = BleAuth(
        certDerB64: base64Encode(idPeripheral.identity.certDer),
        sigB64: base64Encode(Uint8List(64)), // Zeroed invalid signature
        alias: 'Forged Peripheral',
        platform: 'android',
      );
      final sealed = pCipher.seal(utf8.encode(badAuth.encode()));
      for (final f in fragmentMessage(sealed)) {
        await peripheralGatt.send(f);
      }

      expect(centralFuture, throwsA(isA<BleSecurityException>()));
    });

    test('Replayed encrypted message causes session failure', () async {
      final backendCentral = bus.createBackend(
        deviceId: 'dev_c',
        address: 'AA:01',
      );
      final backendPeripheral = bus.createBackend(
        deviceId: 'dev_p',
        address: 'AA:02',
      );

      final incomingCompleter = Completer<BleGattSession>();
      final sub = backendPeripheral.gattServer.incomingSessions.listen(
        incomingCompleter.complete,
      );
      addTearDown(sub.cancel);

      await backendPeripheral.startAdvertising(
        BleBeacon(
          flags: const BeaconFlags(recv: true, gatt: true),
          cap: const BeaconCap(canHost: true),
          eid: [1, 2, 3, 4, 5, 6, 7, 8],
          seq: 1,
        ),
        connectable: true,
      );

      final rawCentralGatt = await backendCentral.connectGatt('dev_p');
      final centralGatt = _RecordingGattSession(rawCentralGatt);
      final peripheralGatt = await incomingCompleter.future;

      final sessionCentral = BleSession(
        gatt: centralGatt,
        role: BleSessionRole.central,
        identity: idCentral,
      );
      final sessionPeripheral = BleSession(
        gatt: peripheralGatt,
        role: BleSessionRole.peripheral,
        identity: idPeripheral,
      );

      final centralFuture = sessionCentral.performHandshake(
        localAlias: 'Alice',
        localPlatform: 'linux',
      );
      final peripheralFuture = sessionPeripheral.performHandshake(
        localAlias: 'Bob',
        localPlatform: 'android',
      );

      await (centralFuture, peripheralFuture).wait;

      final initialFrameCount = centralGatt.recordedFrames.length;

      const offer = BleOffer(
        offerId: 'offer_replay_1',
        fileCount: 1,
        totalSize: 100,
        firstName: 'f.txt',
      );
      await sessionCentral.send(offer);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final appFrames = centralGatt.recordedFrames.sublist(initialFrameCount);
      expect(appFrames, isNotEmpty);

      // Replay the exact same frame(s) to peripheral
      for (final f in appFrames) {
        await rawCentralGatt.send(f);
      }

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(sessionPeripheral.state, BleSessionState.closed);
    });
  });
}

class _RecordingGattSession implements BleGattSession {
  _RecordingGattSession(this._inner);
  final BleGattSession _inner;
  final List<List<int>> recordedFrames = [];

  @override
  bool get isClosed => _inner.isClosed;

  @override
  Stream<List<int>> get received => _inner.received;

  @override
  Future<void> send(List<int> data) {
    recordedFrames.add(List.from(data));
    return _inner.send(data);
  }

  @override
  Future<void> close() => _inner.close();
}
