// P6b - signed goodbye (`bye`) datagram. Spec: LSP-1 4.2 rule 9 and rule 3,
// docs/protocol/test-vectors-inc3.md section 6, docs/plans/inc3.md D12 and the
// section 4.1 row `unit/goodbye_test`.
//
// New symbols under test (expected minimal signatures, see
// docs/plans/inc3-p6b-tests.md):
//   Uint8List encodeBye(IdentityProvider identity, {required DateTime now});
//   ByeMessage? decodeBye(List<int> bytes);   // never throws
//   class ByeMessage { String deviceId; String fingerprint; int ts; Uint8List signature; }
//   bool PeerRegistry.learnCertificate(Uint8List certDer);
//   PeerRegistry(trust: TrustStore?)
//   MulticastDiscovery(security: SecurityConfig, contactsOnly: bool Function()?)
//   Future<void> MulticastDiscovery.sendGoodbye();
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:libreshare_core/src/discovery/testing/in_memory_multicast.dart';
import 'package:libreshare_core/src/security/cert_factory.dart'
    show identityFromScalar;
import 'package:test/test.dart';

import '../helpers/manual_clock.dart';
import '../helpers/p6b_support.dart';

const _vectorD =
    'c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721';
const _vectorFp =
    '8279AFD34ED7AA162D8B04101F577788BC4EE216C7816129125E4ECB0D6D0438';
const _vectorSig =
    'qBDIUMVd24a-it6PAO-fHi7GaNk6Uns95_dHSz2Z0YuENkMq2aCHwulOY8LzK34o3W_GLOQ4MdilC4WmHBKWnQ';
const _vectorTs = 1793793600000;

Map<String, Object?> _decodeMap(List<int> bytes) =>
    (jsonDecode(utf8.decode(bytes)) as Map).cast<String, Object?>();

Uint8List _encodeMap(Map<String, Object?> m) =>
    Uint8List.fromList(utf8.encode(jsonEncode(m)));

void main() {
  late P6bPeer victim;
  late P6bPeer attacker;
  late P6bPeer bystander;
  late P6bPeer receiver;
  late P6bPeer receiver2;

  setUpAll(() {
    victim = P6bPeer('victim-0000');
    attacker = P6bPeer('attacker-0000');
    bystander = P6bPeer('bystander-0000');
    receiver = P6bPeer('receiver-0000');
    receiver2 = P6bPeer('receiver-0002');
  });

  // LSP-1 4.2 rule 9 (datagram shape), schema discovery-announce `bye`
  // branch, test vector section 6, rule 3 (LSP/1.0 decoders drop it).
  group('codec', () {
    late KeyIdentity vector;
    setUpAll(() {
      vector = KeyIdentity.fromGenerated(
        identityFromScalar(
          deviceId: 'ls-vector-client',
          privateScalar: BigInt.parse(_vectorD, radix: 16),
          now: DateTime.utc(2026, 11, 4, 12),
          serial: BigInt.parse('0102030405060708090a0b0c0d0e0f', radix: 16),
        ),
      );
    });

    test('encodeBye reproduces the published vector byte for byte', () {
      final bytes = encodeBye(
        vector,
        now: DateTime.fromMillisecondsSinceEpoch(_vectorTs, isUtc: true),
      );
      expect(vector.identity.fingerprint, _vectorFp);
      expect(_decodeMap(bytes), {
        'proto': 'libreshare',
        'v': '1.1',
        't': 'bye',
        'deviceId': 'ls-vector-client',
        'fingerprint': _vectorFp,
        'ts': _vectorTs,
        'sig': _vectorSig,
      });
      expect(bytes.length, lessThan(kMaxAnnounceBytes));
    });

    test('decodeBye round trips encodeBye and the signature verifies', () {
      final bytes = encodeBye(
        victim.key,
        now: DateTime.fromMillisecondsSinceEpoch(1793793600123, isUtc: true),
      );
      final m = decodeBye(bytes);
      expect(m, isNotNull);
      expect(m!.deviceId, victim.id);
      expect(m.fingerprint, victim.fp);
      expect(m.ts, 1793793600123);
      expect(m.signature, hasLength(64));
      expect(
        verifySignature(
          certDer: victim.certDer,
          domain: SigDomain.bye,
          message: byeText(m.deviceId, m.fingerprint, m.ts),
          signature: m.signature,
        ),
        isTrue,
      );
    });

    test('encodeBye uses the clock it is given (ts = now in epoch ms)', () {
      final t = DateTime.utc(2030, 1, 2, 3, 4, 5, 678);
      expect(decodeBye(encodeBye(victim.key, now: t))!.ts, tsOf(t));
      // A local (non-UTC) DateTime denotes the same instant.
      expect(decodeBye(encodeBye(victim.key, now: t.toLocal()))!.ts, tsOf(t));
    });

    test('the schema fixture bye_datagram.json decodes', () {
      final bytes = File('test/conformance/fixtures/lsp11/bye_datagram.json')
          .readAsBytesSync();
      final m = decodeBye(bytes);
      expect(m, isNotNull);
      expect(m!.ts, 1793793600000);
      expect(m.fingerprint, hasLength(64));
      expect(m.signature, hasLength(64));
    });

    test('an LSP/1.0 decoder drops a bye; an announce is not a bye', () {
      final bye = encodeBye(victim.key, now: DateTime.utc(2026, 11, 4, 12));
      expect(decodeAnnounce(bye), isNull);
      expect(decodeAnnounce(bye, allowProbe: true), isNull);
      // Positive twin: the same decoder does accept a real announce, and
      // decodeBye refuses it.
      final announce = encodeAnnounce(victim.info(), announce: true);
      expect(decodeAnnounce(announce), isNotNull);
      expect(decodeBye(announce), isNull);
    });

    test('malformed byes are dropped (each member, type and range)', () {
      Map<String, Object?> good() => _decodeMap(rawBye(victim, ts: _vectorTs));
      expect(decodeBye(_encodeMap(good())), isNotNull, reason: 'baseline');

      final invalid = <String, void Function(Map<String, Object?>)>{
        for (final k in [
          'proto',
          'v',
          't',
          'deviceId',
          'fingerprint',
          'ts',
          'sig',
        ])
          'without $k': (m) => m.remove(k),
        'proto other': (m) => m['proto'] = 'other',
        't hello': (m) => m['t'] = 'hello',
        't BYE': (m) => m['t'] = 'BYE',
        't null': (m) => m['t'] = null,
        'v 1.0 (bye exists from 1.1)': (m) => m['v'] = '1.0',
        'v 2.1 (unknown major)': (m) => m['v'] = '2.1',
        'v 1': (m) => m['v'] = '1',
        'v number': (m) => m['v'] = 1.1,
        'deviceId empty': (m) => m['deviceId'] = '',
        'deviceId number': (m) => m['deviceId'] = 7,
        'deviceId control char': (m) => m['deviceId'] = 'a\u0000b',
        'deviceId 129 chars': (m) => m['deviceId'] = 'a' * 129,
        'fingerprint empty': (m) => m['fingerprint'] = '',
        'fingerprint lowercase (schema: ^[0-9A-F]{64}\$)': (m) =>
            m['fingerprint'] = (m['fingerprint']! as String).toLowerCase(),
        'fingerprint 63 hex': (m) =>
            m['fingerprint'] = (m['fingerprint']! as String).substring(1),
        'fingerprint 65 hex': (m) => m['fingerprint'] = '${m['fingerprint']}A',
        'fingerprint not hex': (m) => m['fingerprint'] = 'G' * 64,
        'ts string': (m) => m['ts'] = '$_vectorTs',
        'ts fraction': (m) => m['ts'] = 1.5,
        'ts negative': (m) => m['ts'] = -1,
        'ts null': (m) => m['ts'] = null,
        'sig 85 chars': (m) => m['sig'] = 'A' * 85,
        'sig 87 chars': (m) => m['sig'] = 'A' * 87,
        'sig bad alphabet': (m) => m['sig'] = '+' * 86,
        'sig padded': (m) => m['sig'] = '${'A' * 84}==',
        'sig not a string': (m) => m['sig'] = List.filled(64, 1),
        'both shapes at once (carries announce)': (m) => m['announce'] = true,
      };
      invalid.forEach((name, mutate) {
        final m = good();
        mutate(m);
        expect(decodeBye(_encodeMap(m)), isNull, reason: name);
      });

      // Positive twins: what the schema allows stays accepted.
      expect(decodeBye(_encodeMap(good()..['v'] = '1.2')), isNotNull);
      expect(decodeBye(_encodeMap(good()..['v'] = '1.10')), isNotNull);
      expect(
        decodeBye(_encodeMap(good()..['unknown'] = {'x': 1})),
        isNotNull,
        reason: 'unknown members are ignored',
      );
    });

    test('non-JSON, empty, oversize and nested garbage never throw', () {
      expect(decodeBye(const []), isNull);
      expect(decodeBye(utf8.encode('not json')), isNull);
      expect(decodeBye(utf8.encode('[1,2,3]')), isNull);
      expect(decodeBye(utf8.encode('{"t":"bye"}')), isNull);
      expect(decodeBye(Uint8List.fromList([0xff, 0xfe, 0xfd])), isNull);
      final big = _decodeMap(rawBye(victim, ts: _vectorTs))
        ..['pad'] = 'x' * 1200;
      final bytes = _encodeMap(big);
      expect(bytes.length, greaterThan(kMaxAnnounceBytes));
      expect(decodeBye(bytes), isNull, reason: 'datagram larger than 1200 B');
      expect(decodeBye(utf8.encode('[' * 5000)), isNull);
    });

    test('seeded fuzz: mutated and random datagrams never throw', () {
      final r = Random(6);
      final seed = rawBye(victim, ts: _vectorTs);
      for (var i = 0; i < 400; i++) {
        final b = Uint8List.fromList(seed);
        for (var k = 0; k < 1 + r.nextInt(4); k++) {
          b[r.nextInt(b.length)] = r.nextInt(256);
        }
        decodeBye(b); // must not throw; the result is irrelevant
        decodeBye(
          Uint8List.fromList(
            List.generate(r.nextInt(400), (_) => r.nextInt(256)),
          ),
        );
      }
    });
  });

  // LSP-1 4.2 rule 9: removal conditions. Each test builds a receiving
  // discovery in the secure profile with a fake clock.
  group('receiving a bye', () {
    late InMemoryMulticastBus bus;
    late ManualClock clock;
    late P6bNode rx;
    late List<DiscoveryEvent> events;
    late int registrarCalls;

    setUp(() async {
      bus = InMemoryMulticastBus();
      clock = ManualClock();
      registrarCalls = 0;
      rx = P6bNode(
        bus,
        receiver,
        clock: clock,
        registrar: (peer, address) async {
          registrarCalls++;
          return true;
        },
      );
      events = [];
      rx.registry.events.listen(events.add);
      await rx.discovery.start();
      await settle();
      bus.sent.clear();
    });

    tearDown(() => rx.dispose());

    int now() => tsOf(clock.now());
    bool listed(P6bPeer p) => rx.registry.byId(p.id) != null;
    int lost() => events.whereType<DeviceLost>().length;

    /// Lists [p] and (by default) hands the registry its certificate, as a
    /// TLS handshake or a verified X-LS-Auth proof would.
    void prep(P6bPeer p, {bool cert = true}) {
      rx.listPeer(p);
      if (cert) expect(rx.registry.learnCertificate(p.certDer), isTrue);
    }

    Future<void> deliver(Uint8List bytes, {String from = '10.0.0.77'}) async {
      rx.hear(bytes, from: from);
      await settle();
    }

    /// One second passes: the global verification budget refills.
    Future<void> tick() => clock.advance(const Duration(seconds: 1));

    test('valid_bye_removes_peer', () async {
      prep(victim);
      prep(bystander);
      await settle();
      events.clear();

      await deliver(rawBye(victim, ts: now()));

      expect(listed(victim), isFalse);
      expect(listed(bystander), isTrue, reason: 'only the sender goes');
      expect(events.whereType<DeviceLost>().map((e) => e.device.id), [
        victim.id,
      ]);
      expect(bus.unicasts, isEmpty, reason: 'a bye is never answered');
      expect(registrarCalls, 0, reason: 'a bye never registers anything');
    });

    test('a bye made by encodeBye is accepted end to end', () async {
      prep(victim);
      await deliver(encodeBye(victim.key, now: clock.now()));
      expect(listed(victim), isFalse);
    });

    test('plaintext profile: the same bye is dropped like malformed input '
        '(LSP/1.0 behaviour), the secure receiver removes the peer', () async {
      final plain = P6bNode(bus, receiver2, secure: false, clock: clock);
      await plain.discovery.start();
      addTearDown(plain.dispose);
      plain.listPeer(victim);
      plain.registry.learnCertificate(victim.certDer);
      prep(victim);
      await settle();

      final bye = rawBye(victim, ts: now());
      plain.hear(bye);
      rx.hear(bye);
      await settle();

      expect(
        plain.registry.byId(victim.id),
        isNotNull,
        reason: 'plaintext profile ignores byes',
      );
      expect(listed(victim), isFalse, reason: 'harness can see a removal');
    });

    test('forged_signature_ignored', () async {
      final t = now();
      prep(victim);
      prep(attacker); // the attacker is a known peer with a valid certificate
      Uint8List sigFor(String text, [String domain = SigDomain.bye]) =>
          victim.key.sign(domain, utf8.encode(text));
      final flipped = sigFor('${victim.id}${victim.fp}$t')..[10] ^= 0x01;
      final forged = <String, Uint8List>{
        'signed with the attacker key': rawBye(victim, ts: t, signer: attacker),
        'one bit flipped': rawBye(victim, ts: t, sig: flipped),
        'ts changed after signing': rawBye(
          victim,
          ts: t + 5000,
          sig: sigFor('${victim.id}${victim.fp}$t'),
        ),
        'signed for another deviceId': rawBye(
          victim,
          ts: t,
          sig: sigFor('someone-else${victim.fp}$t'),
        ),
        'text in the wrong order': rawBye(
          victim,
          ts: t,
          sig: sigFor('${victim.fp}${victim.id}$t'),
        ),
        'text with separators': rawBye(
          victim,
          ts: t,
          sig: sigFor('${victim.id}|${victim.fp}|$t'),
        ),
        'all-zero signature': rawBye(victim, ts: t, sig: Uint8List(64)),
        'attacker signature with a future ts': rawBye(
          victim,
          ts: t + 30000,
          signer: attacker,
        ),
      };
      for (final e in forged.entries) {
        await deliver(e.value);
        expect(listed(victim), isTrue, reason: 'accepted: ${e.key}');
        await tick();
      }
      expect(lost(), 0);
      // The failed attempts must not poison replay state: the genuine bye
      // (older than the forged future-dated one) is still honoured.
      await deliver(rawBye(victim, ts: t));
      expect(listed(victim), isFalse, reason: 'valid twin');
    });

    test('bye signed for another signature domain is rejected', () async {
      final t = now();
      prep(victim);
      final others = [
        SigDomain.auth,
        SigDomain.sasCommit,
        SigDomain.sasValue,
        SigDomain.pairRequest,
        SigDomain.pairAck,
        SigDomain.pairInfo,
      ];
      for (final domain in others) {
        await deliver(rawBye(victim, ts: t, domain: domain));
        expect(listed(victim), isTrue, reason: 'domain $domain');
        await tick();
      }
      await deliver(rawBye(victim, ts: t));
      expect(listed(victim), isFalse, reason: 'LSP1-BYE twin');
    });

    test('stale_or_replayed_bye_ignored: +-60 s window', () async {
      final peers = [for (var i = 0; i < 4; i++) P6bPeer('window-$i')];
      peers.forEach(prep);
      final t = now();
      await deliver(rawBye(peers[0], ts: t - 60001));
      await deliver(rawBye(peers[1], ts: t + 60001));
      expect(listed(peers[0]), isTrue, reason: '61 s in the past');
      expect(listed(peers[1]), isTrue, reason: '61 s in the future');
      await deliver(rawBye(peers[2], ts: t - 60000));
      await deliver(rawBye(peers[3], ts: t + 60000));
      expect(listed(peers[2]), isFalse, reason: '60 s old is inside');
      expect(listed(peers[3]), isFalse, reason: '60 s ahead is inside');
    });

    test('a stale bye does not become valid because time passes, and the '
        'window moves with the receiver clock', () async {
      prep(victim);
      final bye = rawBye(victim, ts: now());
      await clock.advance(const Duration(seconds: 61));
      await deliver(bye);
      expect(listed(victim), isTrue, reason: 'now 61 s after ts');
      await deliver(rawBye(victim, ts: now()));
      expect(listed(victim), isFalse, reason: 'fresh bye twin');
    });

    test(
      'stale_or_replayed_bye_ignored: replay after the peer returned',
      () async {
        prep(victim);
        final t = now();
        final bye = rawBye(victim, ts: t);

        await deliver(bye);
        expect(listed(victim), isFalse);
        await deliver(bye); // the same datagram again (bye is sent twice)
        expect(lost(), 1, reason: 'a duplicate is harmless');
        await tick();

        // The victim comes back (Receive On again): announce + handshake.
        prep(victim);
        expect(listed(victim), isTrue);
        await deliver(bye); // an attacker replays the captured bye
        expect(
          listed(victim),
          isTrue,
          reason: 'replay must not remove it again',
        );
        await tick();

        await deliver(rawBye(victim, ts: t - 1000)); // older, inside the window
        expect(listed(victim), isTrue, reason: 'ts must grow');
        await tick();

        await deliver(rawBye(victim, ts: t + 1)); // genuinely newer
        expect(listed(victim), isFalse, reason: 'newer bye is honoured');
      },
    );

    test('bye_for_unknown_peer_ignored: no certificate held', () async {
      prep(victim, cert: false);
      final bye = rawBye(victim, ts: now());

      await deliver(bye);
      expect(
        listed(victim),
        isTrue,
        reason: 'peer expires after 90 s as before',
      );
      expect(lost(), 0);
      expect(bus.unicasts, isEmpty);
      await tick();

      // Twin + replay-state check: once the certificate is known the very same
      // datagram is honoured (an unverifiable bye must not burn its ts).
      expect(rx.registry.learnCertificate(victim.certDer), isTrue);
      await deliver(bye);
      expect(listed(victim), isFalse);
    });

    test('bye_for_unknown_peer_ignored: certificate held but peer not listed, '
        'or never heard of', () async {
      expect(rx.registry.learnCertificate(bystander.certDer), isTrue);
      await deliver(rawBye(bystander, ts: now()));
      await deliver(rawBye(attacker, ts: now())); // not even a certificate
      expect(rx.registry.current, isEmpty, reason: 'a bye registers nothing');
      expect(events, isEmpty);
      expect(bus.unicasts, isEmpty);
      expect(registrarCalls, 0);
    });

    test('a known peer cannot remove another device, even with a valid '
        'signature of its own', () async {
      prep(victim);
      prep(attacker);
      // attacker signs, with its real key and fingerprint, a bye that names
      // the victim's deviceId.
      await deliver(rawBye(attacker, ts: now(), deviceId: victim.id));
      expect(listed(victim), isTrue);
      expect(listed(attacker), isTrue, reason: 'it did not say bye as itself');
      await tick();
      // Victim's deviceId + fingerprint but signed by the attacker is a
      // forgery (covered above); the attacker's own genuine bye works.
      await deliver(rawBye(attacker, ts: now()));
      expect(listed(attacker), isFalse, reason: 'twin');
      expect(listed(victim), isTrue);
    });

    test('bye datagram versions: 1.0 is not a bye, 1.2 is', () async {
      final a = P6bPeer('version-a');
      final b = P6bPeer('version-b');
      prep(a);
      prep(b);
      await deliver(rawBye(a, ts: now(), version: '1.0'));
      expect(listed(a), isTrue);
      await deliver(rawBye(b, ts: now(), version: '1.2'));
      expect(listed(b), isFalse);
    });

    test('verification_budget_5_per_second', () async {
      final peers = [for (var i = 0; i < 7; i++) P6bPeer('budget-$i')];
      peers.forEach(prep);
      final t = now();
      for (final p in peers) {
        rx.hear(rawBye(p, ts: t), from: '10.0.0.77');
      }
      await settle();
      expect(
        [for (final p in peers) listed(p)],
        [false, false, false, false, false, true, true],
        reason: 'exactly 5 verifications in one second, the rest dropped',
      );

      // Excess datagrams were dropped unverified, so they did not burn their
      // ts: after the budget refills the same bytes are honoured.
      await tick();
      for (final p in peers.skip(5)) {
        rx.hear(rawBye(p, ts: t), from: '10.0.0.77');
      }
      await settle();
      expect(rx.registry.current, isEmpty);
    });

    test('verification_budget: the budget is global, not per source', () async {
      final peers = [for (var i = 0; i < 7; i++) P6bPeer('global-$i')];
      peers.forEach(prep);
      final t = now();
      for (var i = 0; i < peers.length; i++) {
        rx.hear(rawBye(peers[i], ts: t), from: '10.0.1.$i');
      }
      await settle();
      expect(peers.where((p) => !listed(p)), hasLength(5));
    });

    test('byes rejected before the signature check do not use the budget '
        '(SPEC-GAP: "verifications" read literally)', () async {
      prep(
        attacker,
      ); // certificate held, so its stale byes reach the window check
      final t = now();
      for (var i = 0; i < 12; i++) {
        // No certificate held for `bystander`: cheap rejection.
        rx.hear(rawBye(bystander, ts: t + i), from: '10.0.2.$i');
        // Outside the +-60 s window: cheap rejection.
        rx.hear(rawBye(attacker, ts: t - 120000 - i), from: '10.0.3.$i');
      }
      await settle();
      expect(listed(attacker), isTrue);
      final peers = [for (var i = 0; i < 5; i++) P6bPeer('after-$i')];
      peers.forEach(prep);
      for (final p in peers) {
        rx.hear(rawBye(p, ts: t), from: '10.0.4.1');
      }
      await settle();
      expect(
        peers.where(listed),
        isEmpty,
        reason: 'all five got a verification',
      );
    });

    test('a manually added peer is removed by a valid bye', () async {
      rx.registry.seen(victim.info(), '10.0.0.9', DiscoverySource.manual);
      expect(rx.registry.learnCertificate(victim.certDer), isTrue);
      await deliver(rawBye(victim, ts: now()));
      expect(listed(victim), isFalse);
    });
  });

  // LSP-1 4.2 rule 9: sending. The engine calls this when the listener closes
  // or Receive goes Off; stop() itself stays silent (existing contract).
  group('sendGoodbye', () {
    late InMemoryMulticastBus bus;
    late P6bBare listener;

    setUp(() async {
      bus = InMemoryMulticastBus();
      listener = P6bBare(bus, address: '10.0.0.60');
      await listener.start();
    });

    test('multicasts two verifiable byes, 50 ms apart, nothing else', () async {
      final a = P6bNode(bus, victim);
      await a.discovery.start();
      addTearDown(a.dispose);
      await settle();
      bus.sent.clear();
      listener.received.clear();

      final sw = Stopwatch()..start();
      await a.discovery.sendGoodbye();
      sw.stop();
      await settle();

      expect(
        sw.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 45)),
      );
      expect(sw.elapsed, lessThan(const Duration(seconds: 1)));
      expect(bus.multicasts, hasLength(2));
      expect(bus.unicasts, isEmpty);
      final byes = [for (final p in listener.received) ?decodeBye(p.data)];
      expect(byes, hasLength(2));
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      for (final b in byes) {
        expect(b.deviceId, victim.id);
        expect(b.fingerprint, victim.fp);
        expect((b.ts - nowMs).abs(), lessThan(5000));
        expect(
          verifySignature(
            certDer: victim.certDer,
            domain: SigDomain.bye,
            message: byeText(b.deviceId, b.fingerprint, b.ts),
            signature: b.signature,
          ),
          isTrue,
        );
      }
      expect(listener.announces, isEmpty, reason: 'LSP/1.0 sees nothing');
    });

    test('plaintext profile and a stopped discovery send no bye', () async {
      final plain = P6bNode(bus, bystander, secure: false);
      await plain.discovery.start();
      addTearDown(plain.dispose);
      bus.sent.clear();
      await plain.discovery.sendGoodbye();
      expect(bus.sent, isEmpty, reason: 'plaintext profile has no identity');

      final secure = P6bNode(bus, attacker);
      await secure.discovery.sendGoodbye(); // never started
      expect(bus.sent, isEmpty, reason: 'not running');

      await secure.discovery.start();
      await secure.discovery.stop();
      bus.sent.clear();
      await secure.discovery.sendGoodbye();
      expect(bus.sent, isEmpty, reason: 'stopped');
    });
  });
}
