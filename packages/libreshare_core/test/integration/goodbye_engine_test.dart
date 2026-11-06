// P6a - the goodbye datagram through two real engines: Receive Off removes the device from the other
// engine's list in <= 1 s (it used to take up to 90 s).
//
// Spec: LSP-1 4.2 rules 8 and 9 (signed `bye`, sent twice when the listener closes or Receive goes
// Off, accepted only for a peer whose certificate the observer already learned, plaintext profile
// sends and accepts none), docs/plans/inc3.md D12 and section 10 item 1 (acceptance "gone from the
// other list in <= 1 s"). P6b proves the datagram and the registry on an in-memory bus without engines
// (integration/goodbye_registry_test); this file proves that the engine wires the identity, the
// certificate learning and the trigger.
//
// SPEC-GAP: stopping the engine (listener closes) also sends the goodbye; the bound used for that
// case is 1.5 s to leave room for the graceful stop.
@TestOn('vm')
library;

import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/p6a_support.dart';

Future<void> main() async {
  final skip = await p6aSkipReason();
  late Directory sandbox;
  late P6aRig rig;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('ls_p6a_bye_');
    rig = P6aRig(sandbox);
  });
  tearDown(() async {
    await rig.dispose();
    sandbox.deleteSync(recursive: true);
  });

  bool lists(P6aNode who, P6aNode other) =>
      who.engine.currentDevices.any((d) => d.id == other.deviceId);

  int byesOnBus() =>
      rig.bus.sent.where((d) => decodeBye(d.data) != null).length;

  Future<(P6aNode, P6aNode)> meet({required bool secure}) async {
    final a = await rig.start('Alice', secure: secure, discovery: true);
    final b = await rig.start('Bob', secure: secure, discovery: true);
    await until(() => lists(b, a) && lists(a, b), what: 'both list each other');
    // Let the registrar handshakes that teach the observer the certificate finish.
    await settle(300);
    return (a, b);
  }

  group('secure profile', () {
    test('Receive Off removes the device from the other list within 1 s; the bye is on the wire, twice', () async {
      final (a, b) = await meet(secure: true);
      expect(byesOnBus(), 0, reason: 'nothing said goodbye yet');

      final sw = Stopwatch()..start();
      await a.engine.receive.turnOff();
      await until(
        () => !lists(b, a),
        timeout: const Duration(seconds: 1),
        what: 'device removed from the other list',
      );
      sw.stop();
      expect(sw.elapsed, lessThan(const Duration(seconds: 1)));
      expect(
        byesOnBus(),
        greaterThanOrEqualTo(2),
        reason: 'sent twice, 50 ms apart',
      );
      final bye = rig.bus.sent
          .map((d) => decodeBye(d.data))
          .whereType<ByeMessage>()
          .first;
      expect(bye.deviceId, a.deviceId);
      expect(bye.fingerprint, a.fp);
    }, skip: skip);

    test(
      'the device stays gone while Off (probes are not listings) and comes back when Receive is turned on',
      () async {
        final (a, b) = await meet(secure: true);
        await a.engine.receive.turnOff();
        await until(() => !lists(b, a), timeout: const Duration(seconds: 1));
        for (var i = 0; i < 8; i++) {
          await settle(150);
          expect(lists(b, a), isFalse, reason: 'still gone at round $i');
        }
        await a.engine.receive.turnOn();
        await until(
          () => lists(b, a),
          timeout: const Duration(seconds: 6),
          what: 'listed again',
        );
      },
      skip: skip,
      timeout: const Timeout(Duration(seconds: 40)),
    );

    test(
      'stopping the engine (the listener closes) says goodbye too',
      () async {
        final (a, b) = await meet(secure: true);
        final sw = Stopwatch()..start();
        await a.engine.stop();
        await until(
          () => !lists(b, a),
          timeout: const Duration(milliseconds: 1500),
          what: 'device removed after the engine stopped',
        );
        sw.stop();
        expect(byesOnBus(), greaterThanOrEqualTo(1));
      },
      skip: skip,
    );

    test(
      'a bye that is not signed by the listed device changes nothing',
      () async {
        final (a, b) = await meet(secure: true);
        // A node with another key forges a bye that names Alice.
        final rogue = KeyIdentity.fromGenerated(
          generateIdentity(deviceId: newDeviceId()),
        );
        final real = encodeBye(rogue, now: DateTime.now().toUtc());
        expect(
          decodeBye(real)!.deviceId,
          rogue.identity.deviceId,
          reason: 'twin: the helper builds what it claims to build',
        );
        final spoof = String.fromCharCodes(real)
            .replaceAll(rogue.identity.deviceId, a.deviceId)
            .replaceAll(rogue.identity.fingerprint, a.fp);
        expect(decodeBye(spoof.codeUnits)!.deviceId, a.deviceId);
        final transport = rig.bus.createTransport(address: '127.0.0.99');
        await transport.start();
        transport.sendMulticast(spoof.codeUnits);
        await settle(300);
        expect(
          lists(b, a),
          isTrue,
          reason: 'a forged goodbye must not blank the list',
        );
        await transport.stop();
      },
      skip: skip,
    );
  });

  group('plaintext profile (control)', () {
    test('Receive Off says no goodbye; the other list keeps the device (it expires later, as in Inc 2)', () async {
      final (a, b) = await meet(secure: false);
      await a.engine.receive.turnOff();
      for (var i = 0; i < 9; i++) {
        await settle(150);
      }
      expect(
        lists(b, a),
        isTrue,
        reason: 'no bye in the plaintext profile: 90 s expiry only',
      );
      expect(byesOnBus(), 0);
    }, skip: skip);
  });
}
