// E5 / R4d: the certificate memory of the PeerRegistry (`_certs`, 1024 entries, LRU) can be flushed
// by a flood of distinct peers (inc3.md section 12 "Known limits carried forward"). Without a
// stored certificate a genuine signed `bye` of an established contact cannot be verified.
//
// Mechanism the tests demand (no signature change, no engine edit): every certificate is
// attributed to the SOURCE it came from, which the registry already knows: the address of the
// listed peer whose fingerprint equals the certificate's (`seen(info, address, ...)` was called
// for that peer before `learnCertificate`; all three engine call sites learn a certificate of a
// peer that is listed). A certificate whose fingerprint is not listed goes to one shared
// "unknown source" bucket. Each source may hold at most `maxCertsPerSource` certificates
// (suggested 64); beyond that the source evicts its OWN oldest. The global bound of 1024 stays.
//
// The tests flood with 1100 distinct, valid, self-signed certificates (more than the global
// 1024, so today they flush everything). Generating them takes about a minute (P-256 keys),
// done once in setUpAll.
//
// Every test names the guard it targets ("GUARD ...") so a verifier can remove that guard and
// expect exactly that test to go red.
@Timeout(Duration(minutes: 5))
library;

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/manual_clock.dart';
import '../helpers/p6b_support.dart';

const _attackerIp = '10.9.9.9';
const _floodSize = 1100;
const _contactCount = 20;

void main() {
  late List<P6bPeer> flood;
  late List<P6bPeer> contacts;
  late P6bPeer newcomer;

  setUpAll(() {
    flood = [for (var i = 0; i < _floodSize; i++) P6bPeer('r4d-flood-$i')];
    contacts = [
      for (var i = 0; i < _contactCount; i++) P6bPeer('r4d-contact-$i'),
    ];
    newcomer = P6bPeer('r4d-newcomer');
  });

  late PeerRegistry reg;

  setUp(() {
    // maxPeers is raised so that only the certificate memory is under test, not the peer table.
    reg = PeerRegistry(
      selfDeviceId: 'self',
      clock: ManualClock(),
      maxPeers: 5000,
    );
  });
  tearDown(() => reg.dispose());

  /// A peer heard from [ip] whose certificate was then learned (the engine's order).
  void establish(P6bPeer p, String ip) {
    reg.seen(p.info(), ip, DiscoverySource.multicast);
    expect(reg.learnCertificate(p.certDer), isTrue);
  }

  void establishContacts() {
    for (var i = 0; i < contacts.length; i++) {
      establish(contacts[i], '10.1.0.${i + 1}');
    }
  }

  bool has(P6bPeer p) => reg.certificateFor(p.fp) != null;

  test('GUARD per-source-cert-cap: a flood of 1100 distinct peers from one source does not evict the certificates of established contacts', () {
    establishContacts();
    for (final p in flood) {
      establish(p, _attackerIp);
    }
    expect(
      contacts.where((c) => !has(c)),
      isEmpty,
      reason: 'every established contact keeps its certificate',
    );
    for (final c in contacts) {
      expect(reg.byId(c.id), isNotNull, reason: 'premise: still listed');
    }
  });

  test('GUARD per-source-cert-cap-bound: the flooding source itself keeps at most a small share, but its newest certificates', () {
    for (final p in flood) {
      establish(p, _attackerIp);
    }
    final kept = flood.where(has).length;
    expect(
      kept,
      lessThanOrEqualTo(512),
      reason: 'a single source must not hold half the memory',
    );
    expect(
      kept,
      greaterThanOrEqualTo(8),
      reason: 'a source keeps a working set',
    );
    // Own LRU: the most recent ones are the ones that stay.
    for (final p in flood.skip(_floodSize - 8)) {
      expect(
        has(p),
        isTrue,
        reason: 'the newest certificates of the source survive',
      );
    }
  });

  test('GUARD other-sources-survive: entries of other sources are untouched by the flood, including a source with several certificates', () {
    // One address behind which several devices live (a router, a docking station).
    for (var i = 0; i < 5; i++) {
      establish(contacts[i], '10.2.0.1');
    }
    for (var i = 5; i < _contactCount; i++) {
      establish(contacts[i], '10.2.0.$i');
    }
    for (final p in flood) {
      establish(p, _attackerIp);
    }
    expect(contacts.where((c) => !has(c)), isEmpty);
  });

  test('GUARD new-source-still-accepted: after the flood a certificate from a new source is stored (no "refuse when full")', () {
    for (final p in flood) {
      establish(p, _attackerIp);
    }
    establish(newcomer, '10.3.0.1');
    expect(has(newcomer), isTrue);
  });

  test('GUARD global-bound-intact: 1100 certificates from 1100 different sources still end at no more than 1024 entries', () {
    for (var i = 0; i < flood.length; i++) {
      establish(flood[i], '10.${4 + i ~/ 250}.${i % 250}.1');
    }
    final kept = flood.where(has).length;
    expect(kept, lessThanOrEqualTo(1024));
    expect(
      kept,
      greaterThanOrEqualTo(1000),
      reason: 'the global LRU still works',
    );
    expect(has(flood.last), isTrue);
  });

  test('GUARD unlisted-fingerprint-bucket: a certificate whose peer is not listed is still learned (unknown-source bucket) and cannot be used to flush listed contacts', () {
    establishContacts();
    expect(
      reg.learnCertificate(newcomer.certDer),
      isTrue,
      reason: 'newcomer was never listed',
    );
    expect(has(newcomer), isTrue);
    // The same flood, but without ever listing the attacker's peers.
    for (final p in flood) {
      reg.learnCertificate(p.certDer);
    }
    expect(contacts.where((c) => !has(c)), isEmpty);
  });

  test('GUARD relearn-refreshes: learning a contact again after the flood keeps it and a bad certificate is still refused', () {
    establishContacts();
    for (final p in flood) {
      establish(p, _attackerIp);
    }
    expect(reg.learnCertificate(contacts.first.certDer), isTrue);
    expect(has(contacts.first), isTrue);
    expect(
      reg.learnCertificate(contacts.first.certDer.sublist(0, 40)),
      isFalse,
    );
  });
}
