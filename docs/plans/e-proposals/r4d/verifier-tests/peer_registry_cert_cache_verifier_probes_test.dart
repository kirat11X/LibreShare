// VERIFIER probes for E5 / R4d (written by the verifier, not by the tester or the coder).
// P1..P6 exercise the per-source certificate cap of PeerRegistry from outside. Bookkeeping map sizes
// are read with dart:mirrors (private fields `_certs`, `_certSource`, `_certSourceCount`), so lib/ is
// not touched. Numbers are printed with the prefix "VERIFIER" and also asserted where a hard
// invariant exists. Pool of 5000 real self-signed certificates is generated once (several minutes).
@Timeout(Duration(minutes: 40))
library;

import 'dart:mirrors';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/manual_clock.dart';
import '../helpers/p6b_support.dart';

const _poolSize = 5000;
const _legit = 10;

void main() {
  late List<P6bPeer> pool;
  late List<P6bPeer> legit;
  late PeerRegistry reg;

  setUpAll(() {
    final sw = Stopwatch()..start();
    pool = [for (var i = 0; i < _poolSize; i++) P6bPeer('r4d-v-pool-$i')];
    legit = [for (var i = 0; i < _legit; i++) P6bPeer('r4d-v-legit-$i')];
    print('VERIFIER pool generation ${sw.elapsedMilliseconds} ms');
  });

  setUp(() {
    reg = PeerRegistry(
      selfDeviceId: 'self',
      clock: ManualClock(),
      maxPeers: 6000,
    );
  });
  tearDown(() => reg.dispose());

  bool has(P6bPeer p) => reg.certificateFor(p.fp) != null;
  void establish(P6bPeer p, String ip) {
    reg.seen(p.info(), ip, DiscoverySource.multicast);
    expect(reg.learnCertificate(p.certDer), isTrue);
  }

  void establishLegit() {
    for (var i = 0; i < legit.length; i++) {
      establish(legit[i], '10.1.0.${i + 1}');
    }
  }

  final lib = (reflectClass(PeerRegistry)).owner! as LibraryMirror;
  Map<dynamic, dynamic> field(String name) =>
      reflect(reg).getField(MirrorSystem.getSymbol(name, lib)).reflectee
          as Map<dynamic, dynamic>;
  int legitAlive() => legit.where(has).length;

  test('P1 unknown-bucket flood of 5000 certs: legit certs from 10 listed addresses all survive', () {
    establishLegit();
    var learned = 0;
    for (final p in pool) {
      if (reg.learnCertificate(p.certDer))
        learned++; // never listed: unknown bucket
    }
    print(
      'VERIFIER P1 learned=$learned legit alive=${legitAlive()}/10 '
      'certs=${field('_certs').length}',
    );
    expect(legitAlive(), _legit);
  });

  test('P1b legit certs learned BEFORE their peer is listed sit in the unknown bucket (honest residual)', () {
    for (final p in legit) {
      expect(reg.learnCertificate(p.certDer), isTrue);
    }
    for (final p in pool) {
      reg.learnCertificate(p.certDer);
    }
    print(
      'VERIFIER P1b unknown-bucket legit alive=${legitAlive()}/10 (bucket cap 64)',
    );
  });

  test('P2 flood from 5000 distinct (spoofed) addresses: how many legit certs survive', () {
    establishLegit();
    final sizes = <int, int>{};
    for (var i = 0; i < pool.length; i++) {
      establish(
        pool[i],
        '172.${16 + i ~/ 65000}.${(i ~/ 250) % 250}.${i % 250 + 1}',
      );
      if (i + 1 == 16 ||
          i + 1 == 500 ||
          i + 1 == 1000 ||
          i + 1 == 1014 ||
          i + 1 == 1015 ||
          i + 1 == 5000) {
        sizes[i + 1] = legitAlive();
      }
    }
    print('VERIFIER P2 legit alive after N distinct-address certs: $sizes');
    expect(field('_certs').length, lessThanOrEqualTo(1024));
  });

  test('P2b 17 hostile addresses x 64 certs fill the global memory (source cap is not a global guarantee)', () {
    establishLegit();
    for (var s = 0; s < 17; s++) {
      for (var j = 0; j < 64; j++) {
        establish(pool[s * 64 + j], '10.66.0.${s + 1}');
      }
    }
    print(
      'VERIFIER P2b legit alive=${legitAlive()}/10 after 17 sources x 64 certs (1088)',
    );
  });

  test('P3 memory: after 20000 learns (mixed single and distinct addresses) bookkeeping <= 1024 and consistent', () {
    establishLegit();
    for (var k = 0; k < 20000; k++) {
      final p = pool[k % _poolSize];
      final ip = k.isEven
          ? '10.9.9.9'
          : '172.20.${(k ~/ 2) % 250}.${(k ~/ 500) % 250 + 1}';
      reg.seen(p.info(), ip, DiscoverySource.multicast);
      reg.learnCertificate(p.certDer);
    }
    final certs = field('_certs');
    final src = field('_certSource');
    final cnt = field('_certSourceCount');
    final total = cnt.values.fold<int>(0, (a, b) => a + (b as int));
    print(
      'VERIFIER P3 certs=${certs.length} certSource=${src.length} '
      'certSourceCount=${cnt.length} sumCounts=$total max=${cnt.values.fold<int>(0, (a, b) => (b as int) > a ? b : a)}',
    );
    expect(certs.length, lessThanOrEqualTo(1024));
    expect(src.length, certs.length);
    expect(Set.of(src.keys), Set.of(certs.keys));
    expect(cnt.length, lessThanOrEqualTo(1024));
    expect(total, certs.length);
    expect(
      cnt.values.every(
        (v) => (v as int) >= 1 && v <= PeerRegistry.maxCertsPerSource,
      ),
      isTrue,
    );
  });

  test('P3b unknown-bucket flood: after 20000 learns the unknown bucket holds <= 64 and maps are consistent', () {
    for (var k = 0; k < 20000; k++) {
      reg.learnCertificate(pool[k % _poolSize].certDer);
    }
    final cnt = field('_certSourceCount');
    print(
      'VERIFIER P3b certs=${field('_certs').length} src=${field('_certSource').length} buckets=${cnt.length} unknown=${cnt['']}',
    );
    expect(
      field('_certs').length,
      lessThanOrEqualTo(PeerRegistry.maxCertsPerSource),
    );
    expect(cnt.length, 1);
  });

  test('P3c peer removal and expiry: bookkeeping stays bounded and certs outlive presence', () {
    for (var i = 0; i < 300; i++) {
      establish(pool[i], '10.5.${i ~/ 100}.1');
    }
    for (var i = 0; i < 300; i++) {
      reg.remove(pool[i].id);
    }
    print(
      'VERIFIER P3c after removal: certs=${field('_certs').length} src=${field('_certSource').length} '
      'buckets=${field('_certSourceCount').length}',
    );
    expect(field('_certSource').length, field('_certs').length);
  });

  test('P4 key rotation: the peer re-announces with a new certificate; new one stored and attributed, old one accounting', () {
    final newKey = P6bPeer('r4d-v-legit-0'); // same deviceId, new key
    establish(legit[0], '10.1.0.1');
    reg.seen(newKey.info(), '10.1.0.1', DiscoverySource.multicast);
    expect(reg.learnCertificate(newKey.certDer), isTrue);
    expect(has(newKey) || reg.certificateFor(newKey.fp) != null, isTrue);
    final cnt = field('_certSourceCount');
    final oldStillThere = reg.certificateFor(legit[0].fp) != null;
    print(
      'VERIFIER P4 new stored=${reg.certificateFor(newKey.fp) != null} old still stored=$oldStillThere '
      'count[10.1.0.1]=${cnt['10.1.0.1']} fpChanged=${reg.fingerprintChanged('r4d-v-legit-0')}',
    );
    expect(cnt['10.1.0.1'], oldStillThere ? 2 : 1);
    expect(field('_certSource')[newKey.fp.toUpperCase()], '10.1.0.1');
    // Re-learning the same cert twice does not double count.
    expect(reg.learnCertificate(newKey.certDer), isTrue);
    expect(field('_certSourceCount')['10.1.0.1'], oldStillThere ? 2 : 1);
  });

  test('P6 fingerprint-borrowing: an attacker listed first with the victim fingerprint steals the victim cert attribution and evicts it with 65 learns', () {
    final victim = legit[0];
    final attacker = pool[0];
    // attacker announces under another deviceId but with the victim's (public) fingerprint
    reg.seen(
      attacker.info(fingerprint: victim.fp),
      '10.66.6.6',
      DiscoverySource.multicast,
    );
    establish(victim, '10.1.0.1'); // genuine handshake of the victim
    final source = field('_certSource')[victim.fp.toUpperCase()];
    for (var i = 1; i <= 65; i++) {
      establish(pool[i], '10.66.6.6');
    }
    print(
      'VERIFIER P6 victim cert attributed to "$source"; victim cert alive after 65 attacker certs: ${has(victim)}',
    );
  });

  test('P5 cost: 20000 learns with 1024 listed peers vs 0 listed peers (scan cost)', () {
    final noPeers = PeerRegistry(selfDeviceId: 'self', clock: ManualClock());
    final sw0 = Stopwatch()..start();
    for (var k = 0; k < 20000; k++) {
      noPeers.learnCertificate(pool[k % _poolSize].certDer);
    }
    sw0.stop();
    noPeers.dispose();
    // 1024 listed peers whose certs are NOT the ones learned below (scan never matches => full scan).
    final full = PeerRegistry(selfDeviceId: 'self', clock: ManualClock());
    // Make exactly 1024 distinct listed peers: use distinct ids
    for (var i = 0; i < 1024; i++) {
      full.seen(
        DeviceInfo(
          deviceId: 'fill-$i',
          alias: 'a',
          platform: 'linux',
          fingerprint: pool[4000 + i % 900].fp,
          port: kDefaultPort,
          addrs: const [],
          caps: const [],
          version: kProtocolVersionSecure,
        ),
        '10.8.${i ~/ 250}.${i % 250 + 1}',
        DiscoverySource.multicast,
      );
    }
    final sw1 = Stopwatch()..start();
    for (var k = 0; k < 20000; k++) {
      full.learnCertificate(pool[k % 3000].certDer);
    }
    sw1.stop();
    print(
      'VERIFIER P5 20000 learns: ${sw0.elapsedMilliseconds} ms with 0 peers, ${sw1.elapsedMilliseconds} ms with ${full.current.length} listed peers '
      '(delta per learn ${((sw1.elapsedMicroseconds - sw0.elapsedMicroseconds) / 20000).toStringAsFixed(1)} us)',
    );
    full.dispose();
    expect(sw1.elapsedMilliseconds, lessThan(600000));
  });
}
