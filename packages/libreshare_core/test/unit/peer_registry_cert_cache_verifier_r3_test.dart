// ignore_for_file: avoid_print, uri_does_not_exist, undefined_function, cast_to_non_type, undefined_identifier
// VERIFIER round 3 for E5 / R4d (written by the verifier). Breaks the "certificate owner = listed
// entry whose deviceId equals the cert subject CN and whose fingerprint matches" rule of
// PeerRegistry._sourceOf. R3-1..3 retry the round-2 attacks A1, B2, C2 (now expected closed); the
// rest are new break attempts. Tests that document a residual print "VERIFIER R3" and assert only
// invariants (maps consistent and bounded).
@Timeout(Duration(minutes: 10))
library;

import 'dart:mirrors';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/manual_clock.dart';
import '../helpers/p6b_support.dart';

const _atk = '10.66.6.6';
const _vic = '10.1.0.1';

void main() {
  late List<P6bPeer> att; // attacker identities with their own deviceIds
  late List<P6bPeer>
  sameCn; // attacker keys whose certificate CN is the victim's deviceId
  late P6bPeer victim;
  late PeerRegistry reg;

  setUpAll(() {
    victim = P6bPeer('r4d-v3-victim');
    att = [for (var i = 0; i < 160; i++) P6bPeer('r4d-v3-att-$i')];
    sameCn = [for (var i = 0; i < 70; i++) P6bPeer('r4d-v3-victim')];
  });
  setUp(() => reg = PeerRegistry(selfDeviceId: 'self', clock: ManualClock()));
  tearDown(() => reg.dispose());

  final lib = reflectClass(PeerRegistry).owner! as LibraryMirror;
  Map<dynamic, dynamic> field(String n) =>
      reflect(reg).getField(MirrorSystem.getSymbol(n, lib)).reflectee
          as Map<dynamic, dynamic>;
  String? label(P6bPeer p) =>
      field('_certSource')[p.fp.toUpperCase()] as String?;
  bool has(P6bPeer p) => reg.certificateFor(p.fp) != null;
  void consistent() {
    final certs = field('_certs');
    final src = field('_certSource');
    final cnt = field('_certSourceCount');
    expect(Set.of(src.keys), Set.of(certs.keys));
    expect(cnt.values.fold<int>(0, (a, b) => a + (b as int)), certs.length);
    expect(certs.length, lessThanOrEqualTo(1024));
    expect(cnt.length, lessThanOrEqualTo(1024));
  }

  DeviceInfo claim(String deviceId, String fp) => DeviceInfo(
    deviceId: deviceId,
    alias: 'a',
    platform: 'linux',
    fingerprint: fp,
    port: kDefaultPort,
    addrs: const [],
    caps: const [],
    version: kProtocolVersionSecure,
  );
  void establish(P6bPeer p, String ip) {
    reg.seen(p.info(), ip, DiscoverySource.multicast);
    expect(reg.learnCertificate(p.certDer), isTrue);
  }

  void floodOwn(int n, {String ip = _atk}) {
    for (var i = 0; i < n; i++) {
      establish(att[i], ip);
    }
  }

  test('R3-1 (A1 retry) attacker alone claims the victim fingerprint, cert learned before the victim is listed: attacker flood does not evict it', () {
    reg.seen(
      claim('evil-claimant', victim.fp),
      _atk,
      DiscoverySource.multicast,
    );
    expect(reg.learnCertificate(victim.certDer), isTrue);
    expect(label(victim), '', reason: 'the claimant is not the owner');
    floodOwn(70);
    expect(has(victim), isTrue);
    // listed later: the next learn attributes it to its own address
    reg.seen(victim.info(), _vic, DiscoverySource.multicast);
    expect(reg.learnCertificate(victim.certDer), isTrue);
    expect(label(victim), _vic);
    consistent();
  });

  test('R3-2 (B2 retry) forged claimant + victim relearn + 64 double-claimed attacker certs: victim cert survives', () {
    establish(victim, _vic);
    reg.seen(
      claim('evil-claimant', victim.fp),
      _atk,
      DiscoverySource.multicast,
    );
    expect(reg.learnCertificate(victim.certDer), isTrue);
    expect(label(victim), _vic);
    for (var i = 0; i < 70; i++) {
      reg.seen(claim('a-$i', att[i].fp), _atk, DiscoverySource.multicast);
      reg.seen(claim('b-$i', att[i].fp), _atk, DiscoverySource.multicast);
      reg.learnCertificate(att[i].certDer);
    }
    print(
      'VERIFIER R3-2 victim alive=${has(victim)} label="${label(victim)}" '
      'unknown bucket=${field('_certSourceCount')['']}',
    );
    expect(has(victim), isTrue);
    consistent();
  });

  test('R3-3 (C2 retry) sole claimant removed, victim listed afterwards: attacker flood does not evict the victim cert', () {
    reg.seen(
      claim('evil-claimant', victim.fp),
      _atk,
      DiscoverySource.multicast,
    );
    expect(reg.learnCertificate(victim.certDer), isTrue);
    reg.remove('evil-claimant');
    reg.seen(victim.info(), _vic, DiscoverySource.multicast);
    expect(reg.learnCertificate(victim.certDer), isTrue);
    floodOwn(70);
    expect(has(victim), isTrue);
    consistent();
  });

  test('R3-4 certificates whose CN is not a listed deviceId land in the unknown bucket and cannot touch a listed victim', () {
    establish(victim, _vic);
    var learned = 0;
    for (var i = 0; i < 80; i++) {
      // attacker listed under ANOTHER deviceId than the cert CN
      reg.seen(claim('other-$i', att[i].fp), _atk, DiscoverySource.multicast);
      if (reg.learnCertificate(att[i].certDer)) {
        learned++;
      }
    }
    final unknown = field('_certSourceCount')[''];
    print(
      'VERIFIER R3-4 learned=$learned unknown=$unknown victim alive=${has(victim)}',
    );
    expect(unknown, 64);
    expect(has(victim), isTrue);
    expect(label(victim), _vic);
    consistent();
  });

  test('R3-5 70 attacker keys with a certificate CN equal to the victim deviceId: not attributed to any address, victim cert untouched', () {
    establish(victim, _vic);
    for (final k in sameCn) {
      reg.seen(
        claim('x-${k.fp.substring(0, 6)}', k.fp),
        _atk,
        DiscoverySource.multicast,
      );
      expect(reg.learnCertificate(k.certDer), isTrue);
      expect(
        label(k),
        '',
        reason: 'listed entry victim-id has another fingerprint',
      );
    }
    print(
      'VERIFIER R3-5 victim alive=${has(victim)} unknown=${field('_certSourceCount')['']}',
    );
    expect(has(victim), isTrue);
    consistent();
  });

  test('R3-6 attacker announces the victim deviceId itself from another address (plain discovery spoof): residual outcome', () {
    establish(victim, _vic);
    // no relearn after the spoof: the label does not move
    reg.seen(victim.info(), _atk, DiscoverySource.multicast);
    floodOwn(70);
    final aliveNoRelearn = has(victim);
    expect(aliveNoRelearn, isTrue);
    // with a relearn while the spoofed address is listed, the cert follows the listed address
    reg.seen(victim.info(), _atk, DiscoverySource.multicast);
    expect(reg.learnCertificate(victim.certDer), isTrue);
    final l = label(victim);
    for (var i = 70; i < 140; i++) {
      establish(att[i], _atk);
    }
    print(
      'VERIFIER R3-6 no relearn alive=$aliveNoRelearn; after relearn label="$l" '
      'alive after 70 more attacker certs=${has(victim)} (address spoof of the victim own deviceId)',
    );
    consistent();
  });

  test('R3-7 (F8) victim changes address: stale label; an attacker at the OLD address evicts the cert with 65 certs', () {
    establish(victim, _vic);
    reg.seen(victim.info(), '10.1.0.2', DiscoverySource.multicast);
    final stale = label(victim);
    floodOwn(70, ip: _vic);
    print(
      'VERIFIER R3-7 label after move="$stale" alive after 70 certs from the old address=${has(victim)}',
    );
    consistent();
  });

  test('R3-8 victim cert learned while the victim is NOT listed (scanner order) sits in the shared bucket: residual F3', () {
    expect(reg.learnCertificate(victim.certDer), isTrue);
    expect(label(victim), '');
    for (var i = 0; i < 70; i++) {
      expect(reg.learnCertificate(att[i].certDer), isTrue); // none listed
    }
    print(
      'VERIFIER R3-8 victim alive after 70 unlisted attacker certs=${has(victim)}',
    );
    consistent();
  });

  test('R3-9 victim listed, cert learned, victim removed (bye/sweep): cert stays, label stays, relisting keeps working', () {
    establish(victim, _vic);
    reg.remove(victim.id);
    expect(has(victim), isTrue);
    expect(label(victim), _vic);
    floodOwn(70);
    expect(has(victim), isTrue);
    consistent();
  });

  test('R3-10 listed fingerprint differs from the cert (pinned old key announced, new cert learned): not attributed to the address', () {
    final rotated = P6bPeer('r4d-v3-victim'); // same CN, new key
    reg.seen(victim.info(), _vic, DiscoverySource.multicast);
    expect(reg.learnCertificate(rotated.certDer), isTrue);
    expect(label(rotated), '', reason: 'entry fingerprint is the old one');
    consistent();
  });
}
