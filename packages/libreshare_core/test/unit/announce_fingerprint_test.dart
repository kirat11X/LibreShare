// P6b - announces carry the fingerprint; an empty or different fingerprint
// never overrides a pinned device.
//
// Spec: LSP-1 4.2 (announce example, "[I3] In the secure profile ... fingerprint
// is the 64-hex fingerprint"), rule 7, 4.7 (LSP/1.0 device announces, secure
// device listens: listed as legacy, never overrides a pinned device),
// docs/plans/inc3.md D10 and the section 4.1 row `security/downgrade_test`
// `empty_fingerprint_announce_cannot_replace_pinned_device`.
//
// New symbols under test: PeerRegistry(trust:), MulticastDiscovery(security:).
import 'package:libreshare_core/libreshare_core.dart';
import 'package:libreshare_core/src/discovery/testing/in_memory_multicast.dart';
import 'package:test/test.dart';

import '../helpers/manual_clock.dart';
import '../helpers/p6b_support.dart';

void main() {
  late P6bPeer alice; // the pinned device
  late P6bPeer impostor;
  late P6bPeer me;

  setUpAll(() {
    alice = P6bPeer('alice-0000');
    impostor = P6bPeer('impostor-0000');
    me = P6bPeer('me-0000');
  });

  // LSP-1 4.2: the datagram is a DeviceInfo plus `announce`; in the secure
  // profile v is 1.1 and fingerprint the 64-hex hash of the certificate.
  group('codec', () {
    test('a secure announce carries v 1.1 and the 64-hex fingerprint', () {
      final bytes = encodeAnnounce(alice.info(), announce: true);
      final m = decodeAnnounce(bytes)!;
      expect(m.info.fingerprint, alice.fp);
      expect(m.info.version, '1.1');
      expect(m.info.fingerprint, matches(RegExp(r'^[0-9A-F]{64}$')));
      expect(bytes.length, lessThanOrEqualTo(kMaxAnnounceBytes));
    });

    test('a send-only probe carries the fingerprint too (the Contacts-only '
        'reply filter reads it)', () {
      final bytes = encodeAnnounce(alice.info(), announce: true, probe: true);
      final m = decodeAnnounce(bytes, allowProbe: true)!;
      expect(m.isProbe, isTrue);
      expect(m.info.fingerprint, alice.fp);
    });

    test('the unicast reply carries it as well', () {
      final m = decodeAnnounce(encodeAnnounce(alice.info(), announce: false))!;
      expect(m.announce, isFalse);
      expect(m.info.fingerprint, alice.fp);
    });

    test('lower-case hex on the wire is normalised, junk is dropped', () {
      final lower = alice.info(fingerprint: alice.fp.toLowerCase());
      expect(
        decodeAnnounce(encodeAnnounce(lower, announce: true))!.info.fingerprint,
        alice.fp,
      );
      for (final bad in [
        alice.fp.substring(1),
        '${alice.fp}0',
        'Z' * 64,
        ' ' * 64,
      ]) {
        final raw = encodeAnnounce(alice.info(), announce: true);
        final text = String.fromCharCodes(raw).replaceFirst(alice.fp, bad);
        expect(
          decodeAnnounce(text.codeUnits),
          isNull,
          reason: 'fingerprint "${bad.length} chars"',
        );
      }
    });

    test('plaintext profile: empty fingerprint and v 1.0 stay valid', () {
      final plain = DeviceInfo(
        deviceId: 'legacy',
        alias: 'Old',
        platform: 'linux',
      );
      final m = decodeAnnounce(encodeAnnounce(plain, announce: true))!;
      expect(m.info.fingerprint, isEmpty);
      expect(m.info.version, '1.0');
    });
  });

  group('MulticastDiscovery', () {
    late InMemoryMulticastBus bus;
    late ManualClock clock;

    setUp(() {
      bus = InMemoryMulticastBus();
      clock = ManualClock();
    });

    test(
      'announces and probes sent by a secure device carry its fingerprint',
      () async {
        final listener = P6bBare(bus, address: '10.0.0.60');
        await listener.start();
        final a = P6bNode(bus, me, probes: true);
        await a.discovery.start();
        addTearDown(a.dispose);
        await settle();
        listener.received.clear();

        a.discovery.announceNow();
        a.info = me.info(port: 0); // Receive Off: a send-only probe
        a.discovery.announceNow();
        await settle();

        final sent = listener.announces;
        expect(sent, hasLength(2));
        for (final m in sent) {
          expect(m.info.deviceId, me.id);
          expect(m.info.fingerprint, me.fp);
          expect(m.info.version, '1.1');
        }
        expect(sent.map((m) => m.isProbe), [false, true]);
      },
    );

    /// A receiver whose trust store pins [alice]; a bare participant plays the
    /// announcing device.
    Future<(P6bNode, P6bBare)> pinnedReceiver() async {
      final rx = P6bNode(bus, me, clock: clock);
      await rx.trust.pin(
        deviceId: alice.id,
        fingerprint: alice.fp,
        alias: 'Alice',
        trust: PeerTrust.known,
      );
      await rx.discovery.start();
      addTearDown(rx.dispose);
      final other = P6bBare(bus);
      await other.start();
      await settle();
      return (rx, other);
    }

    test('announce_with_other_fingerprint_does_not_override_pin', () async {
      final (rx, other) = await pinnedReceiver();

      other.announce(alice.info());
      await settle();
      expect(rx.registry.byId(alice.id), isNotNull);
      expect(
        rx.registry.fingerprintChanged(alice.id),
        isFalse,
        reason: 'genuine',
      );

      // Somebody else claims Alice's deviceId with another certificate.
      other.announce(alice.info(fingerprint: impostor.fp));
      await settle();
      expect(rx.registry.knownFingerprint(alice.id), alice.fp);
      expect(
        rx.registry.fingerprintChanged(alice.id),
        isTrue,
        reason: 'the UI must be able to warn',
      );

      // The genuine device clears the alarm (the pin never moved).
      other.announce(alice.info());
      await settle();
      expect(rx.registry.fingerprintChanged(alice.id), isFalse);
      expect(rx.registry.knownFingerprint(alice.id), alice.fp);
    });

    test('empty_fingerprint_announce_cannot_replace_pinned_device', () async {
      final (rx, other) = await pinnedReceiver();

      other.announce(alice.info(fingerprint: '', version: '1.0'));
      await settle();

      expect(rx.registry.knownFingerprint(alice.id), alice.fp);
      expect(rx.registry.fingerprintChanged(alice.id), isFalse);
      final listed = rx.registry.byId(alice.id)?.info.fingerprint;
      expect(
        listed,
        anyOf(isNull, isEmpty, alice.fp),
        reason:
            'listed as legacy or as the pinned device, never as another key',
      );
    });

    test('a device that is not pinned is listed with whatever it announces '
        '(legacy peers stay visible, rule 7 / 4.7)', () async {
      final (rx, other) = await pinnedReceiver();
      final legacy = DeviceInfo(
        deviceId: 'legacy-1',
        alias: 'Old phone',
        platform: 'android',
      );
      other.announce(legacy);
      other.announce(impostor.info());
      await settle();
      expect(rx.registry.byId('legacy-1')?.info.fingerprint, isEmpty);
      expect(rx.registry.byId(impostor.id)?.info.fingerprint, impostor.fp);
      expect(rx.registry.fingerprintChanged('legacy-1'), isFalse);
      expect(rx.registry.fingerprintChanged(impostor.id), isFalse);
    });

    test('the pin set at run time (after the SAS) is honoured by the next announce', () async {
      final rx = P6bNode(bus, me, clock: clock);
      await rx.discovery.start();
      addTearDown(rx.dispose);
      final other = P6bBare(bus);
      await other.start();

      other.announce(impostor.info(fingerprint: alice.fp)); // before any pin
      await settle();
      await rx.trust.pin(
        deviceId: impostor.id,
        fingerprint: impostor.fp,
        alias: 'Real',
        trust: PeerTrust.known,
      );
      rx.registry.remove(impostor.id);
      other.announce(impostor.info(fingerprint: alice.fp));
      await settle();
      expect(rx.registry.knownFingerprint(impostor.id), impostor.fp);
      expect(rx.registry.fingerprintChanged(impostor.id), isTrue);
    });
  });
}
