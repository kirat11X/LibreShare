// P6b - PeerRegistry.remove, TOFU baseline seeded from the trust store, the
// certificate memory used to verify byes, and AE defect 4 (manually added
// peers vanish from Nearby after 90 s).
//
// Spec: docs/plans/inc3.md section 10 item 1 (acceptance: a Receive-Off device
// is gone from the other list at once), D10 and LSP-1 4.2 rule 7 (a pinned
// device is never overridden by an empty or different fingerprint),
// docs/test-reports/android-emulator.md defect 4, LSP-1 4.2 rule 1 (90 s).
//
// New symbols under test:
//   bool PeerRegistry.remove(String deviceId);
//   PeerRegistry(trust: TrustStore?)             // dynamic baseline lookup
//   bool PeerRegistry.learnCertificate(Uint8List certDer);
import 'dart:async';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/manual_clock.dart';
import '../helpers/p6b_support.dart';

const _fpA = 'AA00000000000000000000000000000000000000000000000000000000000001';
const _fpB = 'BB00000000000000000000000000000000000000000000000000000000000002';

DeviceInfo _dev(String id, {String fp = '', int port = 53318}) => DeviceInfo(
  deviceId: id,
  alias: 'Peer $id',
  platform: 'linux',
  fingerprint: fp,
  port: port,
);

void main() {
  late ManualClock clock;
  late InMemoryTrustStore trust;
  late PeerRegistry reg;
  late List<DiscoveryEvent> events;
  late List<List<DiscoveredDevice>> snapshots;

  PeerRegistry make({TrustStore? trust}) =>
      PeerRegistry(selfDeviceId: 'self', clock: clock, trust: trust);

  setUp(() {
    clock = ManualClock();
    trust = InMemoryTrustStore();
    reg = make(trust: trust);
    events = [];
    snapshots = [];
    reg.events.listen(events.add);
    reg.devices.listen(snapshots.add);
  });

  tearDown(() => reg.dispose());

  group('remove', () {
    test(
      'removes a listed peer, reports DeviceLost and a fresh snapshot',
      () async {
        reg.seen(_dev('a'), '10.0.0.2', DiscoverySource.multicast);
        reg.seen(_dev('b'), '10.0.0.3', DiscoverySource.multicast);
        await settle();
        events.clear();
        snapshots.clear();

        expect(reg.remove('a'), isTrue);
        await settle();

        expect(reg.byId('a'), isNull);
        expect(reg.current.map((d) => d.id), ['b'], reason: 'others stay');
        expect(events, hasLength(1));
        expect(events.single, isA<DeviceLost>());
        expect(events.single.device.id, 'a');
        expect(events.single.device.address, '10.0.0.2');
        expect(snapshots.last.map((d) => d.id), ['b']);
      },
    );

    test(
      'unknown, empty, self and repeated removals return false and say nothing',
      () async {
        reg.seen(_dev('a'), '10.0.0.2', DiscoverySource.multicast);
        await settle();
        events.clear();
        snapshots.clear();

        expect(reg.remove('nobody'), isFalse);
        expect(reg.remove(''), isFalse);
        expect(reg.remove('self'), isFalse);
        expect(reg.remove('a'), isTrue);
        expect(reg.remove('a'), isFalse, reason: 'second call');
        await settle();
        expect(events.whereType<DeviceLost>(), hasLength(1));
        expect(snapshots, hasLength(1));
      },
    );

    test('a removed peer that is heard again is a new find', () async {
      reg.seen(_dev('a'), '10.0.0.2', DiscoverySource.multicast);
      reg.remove('a');
      await settle();
      events.clear();
      reg.seen(_dev('a'), '10.0.0.2', DiscoverySource.multicast);
      await settle();
      expect(events.single, isA<DeviceFound>());
      expect(reg.byId('a'), isNotNull);
    });

    test('removal keeps the TOFU baseline: a returning peer with another '
        'fingerprint is still flagged', () async {
      final noTrust = make();
      addTearDown(noTrust.dispose);
      noTrust.seen(_dev('a', fp: _fpA), '10.0.0.2', DiscoverySource.multicast);
      expect(noTrust.remove('a'), isTrue);
      expect(noTrust.knownFingerprint('a'), _fpA);
      noTrust.seen(_dev('a', fp: _fpB), '10.0.0.2', DiscoverySource.multicast);
      expect(noTrust.fingerprintChanged('a'), isTrue);
    });

    test('remove after dispose is harmless', () {
      reg.seen(_dev('a'), '10.0.0.2', DiscoverySource.multicast);
      reg.dispose();
      expect(reg.remove('a'), isFalse);
    });

    test('works for every source, including manual and QR peers', () async {
      var i = 0;
      for (final s in DiscoverySource.values) {
        final id = 'p${i++}';
        reg.seen(_dev(id), '10.0.0.${i + 1}', s);
        expect(reg.remove(id), isTrue, reason: '$s');
      }
      expect(reg.current, isEmpty);
    });
  });

  // LSP-1 4.2 rule 7: "an announcement whose fingerprint is empty, or differs
  // from the one pinned for the same deviceId, never replaces or overrides the
  // pinned device". The pin lives in the trust store; contacts are pinned at
  // run time (after the SAS), so the lookup must be dynamic.
  group('baseline seeded from the trust store', () {
    Future<void> pin(String id, String fp) => trust.pin(
      deviceId: id,
      fingerprint: fp,
      alias: 'Pinned $id',
      trust: PeerTrust.known,
    );

    test('a contact pinned before the registry existed', () async {
      await pin('d', _fpA);
      final afterwards = make(trust: trust);
      addTearDown(afterwards.dispose);
      afterwards.seen(
        _dev('d', fp: _fpB),
        '10.0.0.9',
        DiscoverySource.multicast,
      );
      expect(afterwards.knownFingerprint('d'), _fpA);
      expect(
        afterwards.fingerprintChanged('d'),
        isTrue,
        reason: 'first sight is not TOFU',
      );
    });

    test('a contact pinned after the registry was created', () async {
      await pin('d', _fpA);
      reg.seen(_dev('d', fp: _fpB), '10.0.0.9', DiscoverySource.multicast);
      expect(reg.knownFingerprint('d'), _fpA);
      expect(reg.fingerprintChanged('d'), isTrue);
    });

    test('the pinned fingerprint is accepted and a changed one heals once the pin matches again', () async {
      await pin('d', _fpA);
      reg.seen(_dev('d', fp: _fpA), '10.0.0.9', DiscoverySource.multicast);
      expect(reg.fingerprintChanged('d'), isFalse);
      reg.seen(_dev('d', fp: _fpB), '10.0.0.9', DiscoverySource.multicast);
      expect(reg.fingerprintChanged('d'), isTrue);
      reg.seen(_dev('d', fp: _fpA), '10.0.0.9', DiscoverySource.multicast);
      expect(reg.fingerprintChanged('d'), isFalse);
      expect(reg.knownFingerprint('d'), _fpA);
    });

    test(
      'an empty fingerprint never overrides the pin and raises no flag',
      () async {
        await pin('d', _fpA);
        reg.seen(_dev('d'), '10.0.0.9', DiscoverySource.multicast);
        expect(reg.knownFingerprint('d'), _fpA);
        expect(reg.fingerprintChanged('d'), isFalse);
        final listed = reg.byId('d')!.info.fingerprint;
        expect(listed, anyOf(isEmpty, _fpA), reason: 'never a different value');
      },
    );

    test(
      'a different fingerprint cannot rewrite the baseline, in any order',
      () async {
        await pin('d', _fpA);
        for (final fp in [_fpB, '', _fpB, _fpB.replaceFirst('BB', 'CC')]) {
          reg.seen(_dev('d', fp: fp), '10.0.0.9', DiscoverySource.multicast);
          expect(reg.knownFingerprint('d'), _fpA, reason: 'after "$fp"');
        }
      },
    );

    test(
      'a removed (listed-nowhere) pinned peer still carries the pin',
      () async {
        await pin('d', _fpA);
        reg.seen(_dev('d', fp: _fpA), '10.0.0.9', DiscoverySource.multicast);
        reg.remove('d');
        reg.seen(_dev('d', fp: _fpB), '10.0.0.9', DiscoverySource.multicast);
        expect(reg.fingerprintChanged('d'), isTrue);
      },
    );

    test(
      'devices that are not contacts keep the Inc 2 TOFU behaviour',
      () async {
        reg.seen(_dev('x', fp: _fpA), '10.0.0.4', DiscoverySource.multicast);
        expect(reg.knownFingerprint('x'), _fpA);
        expect(reg.fingerprintChanged('x'), isFalse);
        reg.seen(_dev('x', fp: _fpB), '10.0.0.4', DiscoverySource.multicast);
        expect(reg.fingerprintChanged('x'), isTrue);
        // Positive twin for the seeded case above: another pinned id is unaffected.
        await pin('y', _fpB);
        reg.seen(_dev('y', fp: _fpB), '10.0.0.5', DiscoverySource.multicast);
        expect(reg.fingerprintChanged('y'), isFalse);
      },
    );

    test('without a trust store the registry behaves exactly like Inc 2', () {
      final plain = make();
      addTearDown(plain.dispose);
      plain.seen(_dev('d', fp: _fpB), '10.0.0.9', DiscoverySource.multicast);
      expect(plain.knownFingerprint('d'), _fpB);
      expect(plain.fingerprintChanged('d'), isFalse);
    });
  });

  group('learnCertificate', () {
    test('accepts a real certificate, rejects garbage without throwing', () {
      final p = P6bPeer('cert-holder');
      expect(reg.learnCertificate(p.certDer), isTrue);
      expect(reg.learnCertificate(p.certDer), isTrue, reason: 'idempotent');
      expect(reg.learnCertificate(Uint8List(0)), isFalse);
      expect(
        reg.learnCertificate(Uint8List.fromList(List.filled(300, 7))),
        isFalse,
      );
      final truncated = Uint8List.fromList(
        p.certDer.sublist(0, p.certDer.length - 9),
      );
      expect(reg.learnCertificate(truncated), isFalse);
      final flipped = Uint8List.fromList(p.certDer)
        ..[p.certDer.length - 3] ^= 0xff;
      expect(
        reg.learnCertificate(flipped),
        isFalse,
        reason: 'bad self-signature',
      );
    });
  });

  // AE defect 4: peers added by IP / link / QR vanished after 90 s without
  // contact. Choice: peers whose latest source is manual or qr are exempt from
  // the 90 s sweep; they leave only by remove(), a valid bye, or when a
  // sweepable source (multicast, ...) has been the latest sighting and goes
  // silent. SPEC-GAP: "latest source wins" (existing rule for `source`)
  // decides whether the exemption applies.
  for (final secure in [false, true]) {
    group(
      'manual peers are exempt from the sweep (${secure ? 'secure' : 'plaintext'} profile)',
      () {
        late PeerRegistry r;
        late List<DiscoveryEvent> ev;
        setUp(() {
          r = make(trust: secure ? InMemoryTrustStore() : null);
          ev = [];
          r.events.listen(ev.add);
        });
        tearDown(() => r.dispose());

        test('manual and qr peers survive any silence', () async {
          r.seen(_dev('m'), '10.0.0.2', DiscoverySource.manual);
          r.seen(_dev('q'), '10.0.0.3', DiscoverySource.qr);
          await clock.advance(const Duration(hours: 2));
          expect(r.sweep(), 0);
          expect(r.current.map((d) => d.id), ['m', 'q']);
          await settle();
          expect(ev.whereType<DeviceLost>(), isEmpty);
        });

        test('every other source still expires at exactly 90 s', () async {
          final sources = [
            DiscoverySource.multicast,
            DiscoverySource.mdns,
            DiscoverySource.subnetScan,
            DiscoverySource.register,
          ];
          for (final (i, s) in sources.indexed) {
            r.seen(_dev('s$i'), '10.0.1.$i', s);
          }
          r.seen(_dev('m'), '10.0.0.2', DiscoverySource.manual);
          await clock.advance(const Duration(seconds: 89, milliseconds: 999));
          expect(r.sweep(), 0);
          await clock.advance(const Duration(milliseconds: 1));
          expect(r.sweep(), sources.length);
          expect(r.current.map((d) => d.id), ['m']);
        });

        test('latest source wins: a manual peer heard by multicast expires '
            'again, a multicast peer added by hand does not', () async {
          r.seen(_dev('a'), '10.0.0.2', DiscoverySource.manual);
          r.seen(_dev('a'), '10.0.0.2', DiscoverySource.multicast);
          r.seen(_dev('b'), '10.0.0.3', DiscoverySource.multicast);
          r.seen(_dev('b'), '10.0.0.3', DiscoverySource.manual);
          await clock.advance(const Duration(seconds: 90));
          expect(r.sweep(), 1);
          expect(r.current.map((d) => d.id), ['b']);
        });

        test('still removable explicitly', () async {
          r.seen(_dev('m'), '10.0.0.2', DiscoverySource.manual);
          await clock.advance(const Duration(hours: 1));
          expect(r.sweep(), 0);
          expect(r.remove('m'), isTrue);
          expect(r.current, isEmpty);
        });

        test('the periodic sweep timer honours the exemption too', () async {
          r.seen(_dev('m'), '10.0.0.2', DiscoverySource.manual);
          r.seen(_dev('x'), '10.0.0.3', DiscoverySource.multicast);
          await clock.advance(const Duration(minutes: 10));
          r.start(sweepInterval: const Duration(milliseconds: 5));
          await eventually(
            () => r.byId('x') == null,
            what: 'sweepable peer gone',
          );
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(r.byId('m'), isNotNull);
        });

        test(
          'the TOFU baseline of a swept peer is still kept (no regression)',
          () async {
            r.seen(_dev('x', fp: _fpA), '10.0.0.3', DiscoverySource.multicast);
            await clock.advance(const Duration(seconds: 100));
            expect(r.sweep(), 1);
            r.seen(_dev('x', fp: _fpB), '10.0.0.3', DiscoverySource.multicast);
            expect(r.fingerprintChanged('x'), isTrue);
          },
        );
      },
    );
  }
}
