// ignore_for_file: avoid_print, uri_does_not_exist, undefined_function, cast_to_non_type, undefined_identifier
// VERIFIER round 2 for E5 / R4d (written by the verifier). Probes the fix "a fingerprint claimed by
// more than one deviceId goes to the shared unknown bucket" of PeerRegistry._sourceOf:
//   A  residual: attacker alone claims the victim fingerprint before the victim is heard
//   B  forged second claimants push a victim cert into the shared 64-slot unknown bucket
//   C  registry churn: claimants removed later, stale attribution
// Private maps are read with dart:mirrors (lib/ is not touched). Lines with prefix "VERIFIER R2"
// carry the measured outcome. Tests assert only hard invariants (bounded, consistent maps; clean
// contacts untouched) and the closed attack; the residual outcomes are printed.
@Timeout(Duration(minutes: 10))
library;

import 'dart:mirrors';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/manual_clock.dart';
import '../helpers/p6b_support.dart';

const _atk = '10.66.6.6';

void main() {
  late List<P6bPeer> pool; // attacker's own identities
  late List<P6bPeer> contacts;
  late P6bPeer victim;
  late PeerRegistry reg;

  setUpAll(() {
    pool = [for (var i = 0; i < 80; i++) P6bPeer('r4d-v2-att-$i')];
    contacts = [for (var i = 0; i < 6; i++) P6bPeer('r4d-v2-contact-$i')];
    victim = P6bPeer('r4d-v2-victim');
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

  void floodSingle(int from, int to) {
    for (var i = from; i < to; i++) {
      establish(pool[i], _atk);
    }
  }

  test('R2-A1 residual: attacker alone claims the victim fp first, victim cert learned BEFORE the victim is listed: 70-cert flood from the attacker address', () {
    for (var i = 0; i < contacts.length; i++) {
      establish(contacts[i], '10.1.0.${i + 1}');
    }
    reg.seen(
      claim('evil-claimant', victim.fp),
      _atk,
      DiscoverySource.multicast,
    );
    expect(
      reg.learnCertificate(victim.certDer),
      isTrue,
    ); // victim not listed yet
    final l = label(victim);
    floodSingle(0, 70);
    print(
      'VERIFIER R2-A1 victim label="$l" victim alive after 70 attacker certs=${has(victim)}; '
      'contacts alive=${contacts.where(has).length}/6',
    );
    expect(
      contacts.where(has).length,
      6,
      reason: 'loss is bounded to what the attacker names',
    );
    consistent();
  });

  test('R2-A2 the victim is listed afterwards (second claimant) and its cert relearned: attribution is the victim own address and the attacker flood no longer touches it', () {
    reg.seen(
      claim('evil-claimant', victim.fp),
      _atk,
      DiscoverySource.multicast,
    );
    expect(reg.learnCertificate(victim.certDer), isTrue);
    reg.seen(victim.info(), '10.1.0.1', DiscoverySource.multicast);
    expect(reg.learnCertificate(victim.certDer), isTrue); // relearn: the entry deviceId == cert CN owns it, the claimant does not count
    expect(label(victim), '10.1.0.1');
    floodSingle(0, 70);
    print(
      'VERIFIER R2-A2 label after relearn="${label(victim)}" alive after flood=${has(victim)}',
    );
    expect(has(victim), isTrue);
    consistent();
  });

  test('R2-A3 loss is bounded to certs the attacker names: 3 of 6 contacts claimed alone before they were heard, the other 3 are untouched', () {
    for (var i = 0; i < 3; i++) {
      reg.seen(
        claim('evil-$i', contacts[i].fp),
        _atk,
        DiscoverySource.multicast,
      );
    }
    for (final c in contacts) {
      expect(reg.learnCertificate(c.certDer), isTrue);
    }
    floodSingle(0, 70);
    final lost = [
      for (var i = 0; i < 6; i++)
        if (!has(contacts[i])) i,
    ];
    print('VERIFIER R2-A3 lost contacts (indices)=$lost');
    expect(lost.where((i) => i >= 3), isEmpty);
    consistent();
  });

  test('R2-B1 no relearn: a forged second claimant alone does not move or evict an existing victim cert', () {
    establish(victim, '10.1.0.1');
    reg.seen(
      claim('evil-claimant', victim.fp),
      _atk,
      DiscoverySource.multicast,
    );
    // attacker floods ambiguous certs (two deviceIds per own fingerprint)
    for (var i = 0; i < 70; i++) {
      reg.seen(claim('a-$i', pool[i].fp), _atk, DiscoverySource.multicast);
      reg.seen(claim('b-$i', pool[i].fp), _atk, DiscoverySource.multicast);
      reg.learnCertificate(pool[i].certDer);
    }
    print(
      'VERIFIER R2-B1 victim label="${label(victim)}" alive=${has(victim)} unknown bucket='
      '${field('_certSourceCount')['']}',
    );
    expect(has(victim), isTrue);
    consistent();
  });

  test('R2-B2 attack: 1 forged claimant + victim cert relearned + 65 double-claimed attacker certs flush the victim cert from the shared unknown bucket', () {
    establish(victim, '10.1.0.1');
    reg.seen(
      claim('evil-claimant', victim.fp),
      _atk,
      DiscoverySource.multicast,
    );
    expect(
      reg.learnCertificate(victim.certDer),
      isTrue,
    ); // relearn (scanner / greet)
    final l = label(victim);
    var n = 0;
    for (var i = 0; i < 70; i++) {
      reg.seen(claim('a-$i', pool[i].fp), _atk, DiscoverySource.multicast);
      reg.seen(claim('b-$i', pool[i].fp), _atk, DiscoverySource.multicast);
      reg.learnCertificate(pool[i].certDer);
      n++;
      if (!has(victim)) break;
    }
    print(
      'VERIFIER R2-B2 label after relearn="$l"; victim evicted after $n ambiguous attacker certs '
      '(${2 * n} listings + 1 forged claimant); alive=${has(victim)}',
    );
    consistent();
  });

  test('R2-B3 compare: same flood but single-claimed attacker certs (no ambiguity) does not reach the victim in the unknown bucket', () {
    establish(victim, '10.1.0.1');
    reg.seen(
      claim('evil-claimant', victim.fp),
      _atk,
      DiscoverySource.multicast,
    );
    expect(reg.learnCertificate(victim.certDer), isTrue);
    floodSingle(0, 70);
    print(
      'VERIFIER R2-B3 victim alive=${has(victim)} label="${label(victim)}"',
    );
    expect(has(victim), isTrue);
    consistent();
  });

  test('R2-B4 many forged claimants (50 deviceIds for one fp) cost no extra bookkeeping', () {
    establish(victim, '10.1.0.1');
    for (var i = 0; i < 50; i++) {
      reg.seen(claim('forged-$i', victim.fp), _atk, DiscoverySource.multicast);
    }
    expect(reg.learnCertificate(victim.certDer), isTrue);
    print(
      'VERIFIER R2-B4 label="${label(victim)}" certs=${field('_certs').length}',
    );
    expect(label(victim), '10.1.0.1');
    consistent();
  });

  test('R2-C1 claimant removed later: the unknown label is stale until the cert is relearned', () {
    establish(victim, '10.1.0.1');
    reg.seen(
      claim('evil-claimant', victim.fp),
      _atk,
      DiscoverySource.multicast,
    );
    expect(reg.learnCertificate(victim.certDer), isTrue);
    expect(reg.remove('evil-claimant'), isTrue);
    final stale = label(victim);
    expect(reg.learnCertificate(victim.certDer), isTrue);
    print(
      'VERIFIER R2-C1 label after claimant removal="$stale", after relearn="${label(victim)}"',
    );
    expect(label(victim), '10.1.0.1');
    consistent();
  });

  test('R2-C2 attacker (sole claimant) removed later: attribution to the attacker address is stale until relearn', () {
    reg.seen(
      claim('evil-claimant', victim.fp),
      _atk,
      DiscoverySource.multicast,
    );
    expect(reg.learnCertificate(victim.certDer), isTrue);
    reg.remove('evil-claimant');
    reg.seen(victim.info(), '10.1.0.1', DiscoverySource.multicast);
    final stale = label(victim);
    floodSingle(0, 70);
    final aliveAfterFlood = has(victim);
    consistent();
    print(
      'VERIFIER R2-C2 label before relearn="$stale", victim alive after attacker flood=$aliveAfterFlood',
    );
  });

  test('R2-C3 victim removed and re-listed behind the attacker claimant (P6 order, round 1): relearn is attributed to the victim own address', () {
    reg.seen(
      claim('evil-claimant', victim.fp),
      _atk,
      DiscoverySource.multicast,
    );
    establish(victim, '10.1.0.1');
    expect(label(victim), '10.1.0.1');
    reg.remove(victim.id);
    establish(
      victim,
      '10.1.0.1',
    ); // re-listed after the claimant; the claimant still does not count
    floodSingle(0, 70);
    expect(has(victim), isTrue);
    consistent();
  });
}
