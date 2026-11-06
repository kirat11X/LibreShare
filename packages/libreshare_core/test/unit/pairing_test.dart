// QR pairing (`lib/src/security/pairing_service.dart`, Increment 3, work package P4).
//
// Sources: LSP-1 5.3 (flow, MACs, K_pair), 4.3.4 `POST /pair` (check order, 125 s hold, one held
// request, wrong mac does not consume the invite, either outcome spends it), 4.3.5, 5 signature
// domains, docs/protocol/test-vectors-inc3.md section 5 (K_pair and MAC vectors shared with
// Increment 6), docs/plans/inc3.md D13 and section 4.1 `unit/pairing_test`
// (`K_pair_vector`, `wrong_mac_rejected`, `second_use_of_S_rejected`, `expired_S_rejected`,
// `inviter_decline`, `S_erased_after_success`, `contacts_pinned_both_ways`).
//
// The expected API of the new symbols is listed in docs/plans/inc3-p4-tests.md. Naming (A is the
// inviter that shows the QR, B the scanner): fpA/fpB fingerprints, nA/nB nonces, S the secret.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/manual_clock.dart';
import '../helpers/p4_fake_time.dart';
import '../helpers/p4_support.dart';

class _Party {
  _Party(
    this.deviceId,
    this.alias,
    this.clock, {
    Uint8List Function(int)? randomBytes,
  }) : id = p4Identity('pair-$deviceId', deviceId: deviceId),
       trust = InMemoryTrustStore(clock: clock),
       secrets = InMemorySecretStore() {
    service = PairingService(
      identity: id,
      trust: trust,
      secrets: secrets,
      self: () => DeviceInfo(
        deviceId: deviceId,
        alias: alias,
        platform: 'linux',
        fingerprint: id.identity.fingerprint,
        version: kProtocolVersionSecure,
      ),
      clock: clock,
      onEvent: events.add,
      randomBytes: randomBytes,
    );
  }

  final String deviceId;
  final String alias;
  final ManualClock clock;
  final KeyIdentity id;
  final InMemoryTrustStore trust;
  final InMemorySecretStore secrets;
  final List<LsEvent> events = [];
  late final PairingService service;

  String get fp => id.identity.fingerprint;
  AuthenticatedPeer get peer => peerOf(id);
  DeviceInfo get card => DeviceInfo(
    deviceId: deviceId,
    alias: alias,
    platform: 'linux',
    fingerprint: fp,
  );
}

Uint8List _bytes(int n, int start) =>
    Uint8List.fromList(List<int>.generate(n, (i) => (start + i) & 0xff));

Uint8List _hmac(Uint8List key, String domain, List<int> message) =>
    hmacSha256(key, domainSeparate(domain, message));

void main() {
  late ManualClock clock;
  late _Party a; // inviter, shows the QR
  late _Party b; // scanner

  setUp(() {
    clock = ManualClock();
    a = _Party('a-id', 'Alice laptop', clock);
    b = _Party('b-id', 'Bob phone', clock);
  });

  /// B scans A's invite.
  PairScan scan(PairInvite invite, {_Party? scanner, _Party? inviter}) {
    final s = scanner ?? b;
    final i = inviter ?? a;
    return s.service.startScan(
      inviteSecretB64: invite.secretB64,
      inviter: i.card,
    );
  }

  /// The inviter's user taps [accept] after the request is held.
  Future<PairResponse> run(
    PairScan sc, {
    bool accept = true,
    _Party? from,
    PairRequest? request,
  }) async {
    final sender = from ?? b;
    final fut = a.service.handlePair(request ?? sc.request, peer: sender.peer);
    await pumpEventQueue();
    expect(a.service.pendingPrompt, isNotNull, reason: 'request is held');
    a.service.decide(accept: accept);
    return fut;
  }

  // docs/protocol/test-vectors-inc3.md section 5: fpA = the receiver vector, fpB = the sender
  // vector of section 4. These are the same values Increment 6 must reproduce.
  group('known-answer vectors (K_pair_vector)', () {
    const fpA =
        'F257EE87F7B71A1A495B40699CF5AAD04B668A2A5C684062C5B58D5EFB9642DD';
    const fpB =
        'AE91A910C4E3D642640BD9CCFCBD18A6BB2ACF0091BEFFF1D7BD56C437F99EFF';
    final s = _bytes(32, 0x40);
    final nA = _bytes(16, 0x60);
    final nB = _bytes(16, 0x70);

    test('PairRequest.mac', () {
      final mac = pairRequestMac(
        secret: s,
        scannerFingerprint: fpB,
        inviterFingerprint: fpA,
        scannerNonce: nB,
      );
      expect(
        hexOf(mac),
        'a4af9b3626dec060bc129302b38429c5e2a95278529ea944b9a710503fe18b67',
      );
      expect(b64urlEncode(mac), 'pK-bNibewGC8EpMCs4QpxeKpUnhSnqlEuacQUD_hi2c');
    });

    test('PairResponse.mac', () {
      final mac = pairAckMac(
        secret: s,
        inviterFingerprint: fpA,
        scannerFingerprint: fpB,
        inviterNonce: nA,
        scannerNonce: nB,
      );
      expect(
        hexOf(mac),
        'da859a48862641fdf686a481a241f055d1bfa7cf419db45ad1a111a16b6134af',
      );
      expect(b64urlEncode(mac), '2oWaSIYmQf32hqSBokHwVdG_p89BnbRa0aERoWthNK8');
    });

    test('K_pair', () {
      final k = derivePairKey(
        secret: s,
        inviterNonce: nA,
        scannerNonce: nB,
        fingerprintA: fpA,
        fingerprintB: fpB,
      );
      expect(
        hexOf(k),
        '03e8c2507e0048b521fad8c05766fb7a5d218c723f91f161d1c4ec58d52af0ff',
      );
      expect(b64urlEncode(k), 'A-jCUH4ASLUh-tjAV2b7el0hjHI_kfFh0cTsWNUq8P8');
      expect(k, hasLength(32));
    });

    test(
      'K_pair is symmetric in the fingerprints (min/max) but not in the nonces',
      () {
        final k1 = derivePairKey(
          secret: s,
          inviterNonce: nA,
          scannerNonce: nB,
          fingerprintA: fpA,
          fingerprintB: fpB,
        );
        final swappedFps = derivePairKey(
          secret: s,
          inviterNonce: nA,
          scannerNonce: nB,
          fingerprintA: fpB,
          fingerprintB: fpA,
        );
        final swappedNonces = derivePairKey(
          secret: s,
          inviterNonce: nB,
          scannerNonce: nA,
          fingerprintA: fpA,
          fingerprintB: fpB,
        );
        expect(swappedFps, k1);
        expect(swappedNonces, isNot(k1));
      },
    );

    test('every input changes K_pair and both MACs', () {
      Uint8List flip(Uint8List x) => Uint8List.fromList(x)..[0] ^= 1;
      final base = hexOf(
        derivePairKey(
          secret: s,
          inviterNonce: nA,
          scannerNonce: nB,
          fingerprintA: fpA,
          fingerprintB: fpB,
        ),
      );
      final variants = [
        derivePairKey(
          secret: flip(s),
          inviterNonce: nA,
          scannerNonce: nB,
          fingerprintA: fpA,
          fingerprintB: fpB,
        ),
        derivePairKey(
          secret: s,
          inviterNonce: flip(nA),
          scannerNonce: nB,
          fingerprintA: fpA,
          fingerprintB: fpB,
        ),
        derivePairKey(
          secret: s,
          inviterNonce: nA,
          scannerNonce: flip(nB),
          fingerprintA: fpA,
          fingerprintB: fpB,
        ),
        derivePairKey(
          secret: s,
          inviterNonce: nA,
          scannerNonce: nB,
          fingerprintA: fpA,
          fingerprintB: fpM,
        ),
      ];
      expect(variants.map(hexOf).toSet(), hasLength(4));
      expect(variants.map(hexOf), isNot(contains(base)));
      final req = hexOf(
        pairRequestMac(
          secret: s,
          scannerFingerprint: fpB,
          inviterFingerprint: fpA,
          scannerNonce: nB,
        ),
      );
      expect(
        hexOf(
          pairRequestMac(
            secret: s,
            scannerFingerprint: fpA,
            inviterFingerprint: fpB,
            scannerNonce: nB,
          ),
        ),
        isNot(req),
        reason: 'the order of the fingerprints is part of the MAC',
      );
      expect(
        hexOf(
          pairRequestMac(
            secret: flip(s),
            scannerFingerprint: fpB,
            inviterFingerprint: fpA,
            scannerNonce: nB,
          ),
        ),
        isNot(req),
      );
      expect(
        hexOf(
          pairRequestMac(
            secret: s,
            scannerFingerprint: fpB,
            inviterFingerprint: fpA,
            scannerNonce: flip(nB),
          ),
        ),
        isNot(req),
      );
    });

    test('request and ack MACs are domain separated', () {
      // The same fields under the other label would collide without domain separation.
      final fields = [...ascii.encode(fpB), ...ascii.encode(fpA), ...nB];
      expect(
        hexOf(_hmac(s, SigDomain.pairRequest, fields)),
        hexOf(
          pairRequestMac(
            secret: s,
            scannerFingerprint: fpB,
            inviterFingerprint: fpA,
            scannerNonce: nB,
          ),
        ),
      );
      expect(
        hexOf(_hmac(s, SigDomain.pairAck, fields)),
        isNot(hexOf(_hmac(s, SigDomain.pairRequest, fields))),
      );
    });
  });

  group('invite (LSP-1 5.3 step 1)', () {
    test('S is 32 random bytes, valid 10 minutes, in memory only', () async {
      final invite = a.service.createInvite();
      expect(invite.secret, hasLength(32));
      expect(invite.secretB64, hasLength(43));
      expect(b64urlDecode(invite.secretB64), invite.secret);
      expect(invite.expiresAt, clock.now().add(const Duration(minutes: 10)));
      expect(a.service.hasActiveInvite, isTrue);
      expect(a.secrets.names, isEmpty, reason: 'S must never be persisted');
    });

    test('invites differ', () {
      final one = a.service.createInvite();
      final two = a.service.createInvite();
      expect(one.secretB64, isNot(two.secretB64));
    });

    test('S comes from the injected random source (32 bytes requested)', () {
      final lengths = <int>[];
      final x = _Party(
        'x-id',
        'X',
        clock,
        randomBytes: (n) {
          lengths.add(n);
          return _bytes(n, 0x40);
        },
      );
      final invite = x.service.createInvite();
      expect(lengths, contains(32));
      expect(invite.secretB64, 'QEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaW1xdXl8');
    });

    test('no invite yet: hasActiveInvite is false and /pair is 404', () async {
      expect(a.service.hasActiveInvite, isFalse);
      final other = _Party('c-id', 'C', clock);
      final fake = other.service.createInvite();
      final sc = scan(fake, scanner: b, inviter: other);
      await expectLs(
        a.service.handlePair(sc.request, peer: b.peer),
        LsErrorCode.notFound,
      );
      expect(a.service.pendingPrompt, isNull);
    });

    test('a malformed invite secret is refused by the scanner', () {
      expect(
        () => b.service.startScan(inviteSecretB64: 'short', inviter: a.card),
        throwsA(anyOf(isA<ArgumentError>(), isA<FormatException>())),
      );
    });
  });

  group('happy path', () {
    test('request and response carry the specified fields and MACs', () async {
      final invite = a.service.createInvite();
      final sc = scan(invite);
      final req = sc.request;
      expect(req.sender.deviceId, 'b-id');
      expect(req.sender.fingerprint, b.fp);
      expect(req.nonce, hasLength(22));
      final nB = b64urlDecode(req.nonce);
      expect(nB, hasLength(16));
      expect(req.mac, hasLength(43));
      expect(
        b64urlDecode(req.mac),
        _hmac(invite.secret, SigDomain.pairRequest, [
          ...ascii.encode(b.fp),
          ...ascii.encode(a.fp),
          ...nB,
        ]),
      );

      final resp = await run(sc);
      expect(resp.accepted, isTrue);
      expect(resp.responder.deviceId, 'a-id');
      expect(resp.responder.fingerprint, a.fp);
      expect(resp.nonce, hasLength(22));
      final nA = b64urlDecode(resp.nonce!);
      expect(nA, hasLength(16));
      expect(resp.nonce, isNot(req.nonce));
      expect(
        b64urlDecode(resp.mac!),
        _hmac(invite.secret, SigDomain.pairAck, [
          ...ascii.encode(a.fp),
          ...ascii.encode(b.fp),
          ...nA,
          ...nB,
        ]),
      );
      expect(await sc.complete(resp), isTrue);
    });

    test(
      'K_pair: both sides store the same HKDF value under kpair/<deviceId>',
      () async {
        final invite = a.service.createInvite();
        final sc = scan(invite);
        final nB = b64urlDecode(sc.request.nonce);
        final resp = await run(sc);
        await sc.complete(resp);
        final nA = b64urlDecode(resp.nonce!);
        final lo = a.fp.compareTo(b.fp) <= 0 ? a.fp : b.fp;
        final hi = a.fp.compareTo(b.fp) <= 0 ? b.fp : a.fp;
        final expected = hkdfSha256(
          ikm: invite.secret,
          salt: [...nA, ...nB],
          info: [
            ...ascii.encode(SigDomain.pairInfo),
            ...ascii.encode(lo),
            ...ascii.encode(hi),
          ],
          length: 32,
        );
        expect(await a.secrets.get('kpair/b-id'), expected);
        expect(await b.secrets.get('kpair/a-id'), expected);
        expect(a.trust.contacts.single.hasPairKey, isTrue);
        expect(b.trust.contacts.single.hasPairKey, isTrue);
      },
    );

    test('contacts_pinned_both_ways: trusted, with deviceId, fingerprint and alias', () async {
      final sc = scan(a.service.createInvite());
      final resp = await run(sc);
      await sc.complete(resp);
      final atA = a.trust.contacts.single;
      expect(atA.deviceId, 'b-id');
      expect(atA.fingerprint, b.fp);
      expect(atA.alias, 'Bob phone');
      expect(atA.trust, PeerTrust.trusted);
      final atB = b.trust.contacts.single;
      expect(atB.deviceId, 'a-id');
      expect(atB.fingerprint, a.fp);
      expect(atB.alias, 'Alice laptop');
      expect(atB.trust, PeerTrust.trusted);
      expect(
        a.events.whereType<ContactChanged>().map((e) => e.deviceId),
        contains('b-id'),
      );
      expect(
        b.events.whereType<ContactChanged>().map((e) => e.deviceId),
        contains('a-id'),
      );
      // classification as the receiver will do it for the next session
      expect(a.trust.classify('b-id', b.fp).trust, PeerTrust.trusted);
    });

    test(
      'S_erased_after_success: the invite is spent and S is nowhere',
      () async {
        final invite = a.service.createInvite();
        final sc = scan(invite);
        final resp = await run(sc);
        await sc.complete(resp);
        expect(a.service.hasActiveInvite, isFalse);
        expect(a.service.pendingPrompt, isNull);
        expect(a.secrets.names, ['kpair/b-id']);
        expect(b.secrets.names, ['kpair/a-id']);
        for (final p in [a, b]) {
          for (final n in p.secrets.names) {
            expect(await p.secrets.get(n), isNot(invite.secret));
          }
        }
      },
    );

    test(
      'second_use_of_S_rejected: the very same request again is 404',
      () async {
        final invite = a.service.createInvite();
        final sc = scan(invite);
        await sc.complete(await run(sc));
        await expectLs(
          a.service.handlePair(sc.request, peer: b.peer),
          LsErrorCode.notFound,
        );
        // a fresh scan with the old secret fares no better
        final again = scan(invite);
        await expectLs(
          a.service.handlePair(again.request, peer: b.peer),
          LsErrorCode.notFound,
        );
        expect(a.service.pendingPrompt, isNull);
        expect(a.trust.contacts, hasLength(1));
      },
    );

    test('a SAS-known contact is upgraded to trusted by pairing', () async {
      await a.trust.pin(
        deviceId: 'b-id',
        fingerprint: b.fp,
        alias: 'Bob',
        trust: PeerTrust.known,
      );
      final sc = scan(a.service.createInvite());
      await sc.complete(await run(sc));
      expect(a.trust.contacts.single.trust, PeerTrust.trusted);
    });
  });

  // LSP-1 4.3.4 /pair: "mac verifies against the invite secret S in constant time (401
  // AUTH_INVALID; a wrong mac does not consume the invite)".
  group('wrong_mac_rejected', () {
    PairRequest withMac(PairRequest r, String mac) =>
        PairRequest(sender: r.sender, nonce: r.nonce, mac: mac);

    test(
      'a flipped bit: 401, nothing held, nothing pinned, invite still usable',
      () async {
        final invite = a.service.createInvite();
        final sc = scan(invite);
        final mac = Uint8List.fromList(b64urlDecode(sc.request.mac))..[5] ^= 1;
        await expectLs(
          a.service.handlePair(
            withMac(sc.request, b64urlEncode(mac)),
            peer: b.peer,
          ),
          LsErrorCode.authInvalid,
        );
        expect(a.service.pendingPrompt, isNull);
        expect(a.trust.contacts, isEmpty);
        expect(a.secrets.names, isEmpty);
        expect(a.service.hasActiveInvite, isTrue);
        // positive twin: the genuine request still works afterwards
        final resp = await run(sc);
        expect(resp.accepted, isTrue);
      },
    );

    test('a MAC made with another secret', () async {
      a.service.createInvite();
      final stranger = _Party('c-id', 'C', clock).service.createInvite();
      final sc = scan(stranger); // B was shown the wrong QR
      await expectLs(
        a.service.handlePair(sc.request, peer: b.peer),
        LsErrorCode.authInvalid,
      );
      expect(a.service.hasActiveInvite, isTrue);
    });

    test('a MAC with the two fingerprints swapped', () async {
      final invite = a.service.createInvite();
      final sc = scan(invite);
      final nB = b64urlDecode(sc.request.nonce);
      final mac = _hmac(invite.secret, SigDomain.pairRequest, [
        ...ascii.encode(a.fp),
        ...ascii.encode(b.fp),
        ...nB,
      ]);
      await expectLs(
        a.service.handlePair(
          withMac(sc.request, b64urlEncode(mac)),
          peer: b.peer,
        ),
        LsErrorCode.authInvalid,
      );
    });

    test(
      'the ack-domain MAC does not pass as a request MAC (domain separation)',
      () async {
        final invite = a.service.createInvite();
        final sc = scan(invite);
        final nB = b64urlDecode(sc.request.nonce);
        final mac = _hmac(invite.secret, SigDomain.pairAck, [
          ...ascii.encode(b.fp),
          ...ascii.encode(a.fp),
          ...nB,
        ]);
        await expectLs(
          a.service.handlePair(
            withMac(sc.request, b64urlEncode(mac)),
            peer: b.peer,
          ),
          LsErrorCode.authInvalid,
        );
      },
    );

    test('a MAC over a different nonce', () async {
      final invite = a.service.createInvite();
      final sc = scan(invite);
      final other = PairRequest(
        sender: sc.request.sender,
        nonce: b64urlEncode(_bytes(16, 0x10)),
        mac: sc.request.mac,
      );
      await expectLs(
        a.service.handlePair(other, peer: b.peer),
        LsErrorCode.authInvalid,
      );
    });

    test('200 wrong MACs in a row do not spend the invite', () async {
      final invite = a.service.createInvite();
      final sc = scan(invite);
      for (var i = 0; i < 200; i++) {
        final bad = _bytes(32, i);
        await expectLs(
          a.service.handlePair(
            withMac(sc.request, b64urlEncode(bad)),
            peer: b.peer,
          ),
          LsErrorCode.authInvalid,
        );
      }
      expect((await run(sc)).accepted, isTrue);
    });
  });

  group('request must come from the proven device', () {
    test('B\'s request replayed under C\'s proof is 401 (sender.fingerprint != proof)', () async {
      final c = _Party('c-id', 'Mallory', clock);
      final sc = scan(a.service.createInvite());
      await expectLs(
        a.service.handlePair(sc.request, peer: c.peer),
        LsErrorCode.authInvalid,
      );
      expect(a.service.pendingPrompt, isNull);
      expect(a.service.hasActiveInvite, isTrue);
    });

    test('C copies B\'s MAC but names its own fingerprint: the MAC binds fpB, so 401', () async {
      final c = _Party('c-id', 'Mallory', clock);
      final sc = scan(a.service.createInvite());
      final forged = PairRequest(
        sender: c.card,
        nonce: sc.request.nonce,
        mac: sc.request.mac,
      );
      await expectLs(
        a.service.handlePair(forged, peer: c.peer),
        LsErrorCode.authInvalid,
      );
      expect(a.trust.contacts, isEmpty);
    });

    test('empty sender.fingerprint is 401', () async {
      final sc = scan(a.service.createInvite());
      final r = PairRequest(
        sender: DeviceInfo(deviceId: 'b-id', alias: 'Bob', platform: 'linux'),
        nonce: sc.request.nonce,
        mac: sc.request.mac,
      );
      await expectLs(
        a.service.handlePair(r, peer: b.peer),
        LsErrorCode.authInvalid,
      );
    });
  });

  group('shape and version (before the MAC)', () {
    test(
      'malformed nonce or mac is 400 and does not spend the invite',
      () async {
        final sc = scan(a.service.createInvite());
        for (final (nonce, mac) in [
          ('AAAA', sc.request.mac),
          ('A' * 23, sc.request.mac),
          (sc.request.nonce, 'short'),
          (sc.request.nonce, '!' * 43),
          ('', ''),
        ]) {
          await expectLs(
            a.service.handlePair(
              PairRequest(sender: sc.request.sender, nonce: nonce, mac: mac),
              peer: b.peer,
            ),
            LsErrorCode.badRequest,
          );
        }
        expect(a.service.hasActiveInvite, isTrue);
        expect((await run(sc)).accepted, isTrue);
      },
    );

    test('a protocol major other than 1 is 426', () async {
      final sc = scan(a.service.createInvite());
      final r = PairRequest(
        sender: DeviceInfo(
          deviceId: 'b-id',
          alias: 'Bob',
          platform: 'linux',
          fingerprint: b.fp,
          version: '2.0',
        ),
        nonce: sc.request.nonce,
        mac: sc.request.mac,
      );
      await expectLs(
        a.service.handlePair(r, peer: b.peer),
        LsErrorCode.upgradeRequired,
      );
      expect(a.service.hasActiveInvite, isTrue);
    });
  });

  group('inviter_decline', () {
    test('accepted:false without nonce and mac; nothing pinned or stored on either side', () async {
      final invite = a.service.createInvite();
      final sc = scan(invite);
      final resp = await run(sc, accept: false);
      expect(resp.accepted, isFalse);
      expect(resp.nonce, isNull);
      expect(resp.mac, isNull);
      expect(resp.responder.deviceId, 'a-id');
      expect(await sc.complete(resp), isFalse);
      expect(a.trust.contacts, isEmpty);
      expect(b.trust.contacts, isEmpty);
      expect(a.secrets.names, isEmpty);
      expect(b.secrets.names, isEmpty);
      expect(a.events.whereType<ContactChanged>(), isEmpty);
      expect(b.events.whereType<ContactChanged>(), isEmpty);
    });

    test('a decline spends the invite', () async {
      final invite = a.service.createInvite();
      final sc = scan(invite);
      await run(sc, accept: false);
      expect(a.service.hasActiveInvite, isFalse);
      await expectLs(
        a.service.handlePair(scan(invite).request, peer: b.peer),
        LsErrorCode.notFound,
      );
    });

    test('the prompt shows who asks: alias, platform, deviceId, proven fingerprint', () async {
      final sc = scan(a.service.createInvite());
      final fut = a.service.handlePair(sc.request, peer: b.peer);
      await pumpEventQueue();
      final p = a.service.pendingPrompt!;
      expect(p.sender.alias, 'Bob phone');
      expect(p.sender.deviceId, 'b-id');
      expect(p.fingerprint, b.fp);
      a.service.decide(accept: false);
      await fut;
      expect(a.service.pendingPrompt, isNull);
    });
  });

  group('scanner verifies the ack (LSP-1 5.3 step 4)', () {
    Future<(PairScan, PairResponse, PairInvite)> accepted() async {
      final invite = a.service.createInvite();
      final sc = scan(invite);
      final resp = await run(sc);
      return (sc, resp, invite);
    }

    PairResponse tweak(
      PairResponse r, {
      String? nonce,
      String? mac,
      DeviceInfo? responder,
      bool dropMac = false,
      bool dropNonce = false,
    }) => PairResponse(
      accepted: true,
      responder: responder ?? r.responder,
      nonce: dropNonce ? null : (nonce ?? r.nonce),
      mac: dropMac ? null : (mac ?? r.mac),
    );

    Future<void> nothingStoredAtB() async {
      expect(b.trust.contacts, isEmpty);
      expect(b.secrets.names, isEmpty);
      expect(b.events.whereType<ContactChanged>(), isEmpty);
    }

    test('a tampered ack MAC is 401 and B pins nothing', () async {
      final (sc, resp, _) = await accepted();
      final mac = Uint8List.fromList(b64urlDecode(resp.mac!))..[0] ^= 1;
      await expectLs(
        sc.complete(tweak(resp, mac: b64urlEncode(mac))),
        LsErrorCode.authInvalid,
      );
      await nothingStoredAtB();
    });

    test('accepted:true without nonce or mac is 401', () async {
      final (sc, resp, _) = await accepted();
      await expectLs(
        sc.complete(tweak(resp, dropMac: true)),
        LsErrorCode.authInvalid,
      );
      await expectLs(
        sc.complete(tweak(resp, dropNonce: true)),
        LsErrorCode.authInvalid,
      );
      await nothingStoredAtB();
    });

    test(
      'an ack made with another secret (an impostor inviter) is 401',
      () async {
        final (sc, resp, _) = await accepted();
        final nB = b64urlDecode(sc.request.nonce);
        final nA = b64urlDecode(resp.nonce!);
        final forged = _hmac(_bytes(32, 0x99), SigDomain.pairAck, [
          ...ascii.encode(a.fp),
          ...ascii.encode(b.fp),
          ...nA,
          ...nB,
        ]);
        await expectLs(
          sc.complete(tweak(resp, mac: b64urlEncode(forged))),
          LsErrorCode.authInvalid,
        );
        await nothingStoredAtB();
      },
    );

    test(
      'a responder that is not the device of the QR (other fingerprint) is 401',
      () async {
        final (sc, resp, _) = await accepted();
        final c = _Party('c-id', 'Mallory', clock);
        await expectLs(
          sc.complete(tweak(resp, responder: c.card)),
          LsErrorCode.authInvalid,
        );
        await nothingStoredAtB();
      },
    );

    test('a different nonce nA invalidates the MAC (it covers nA)', () async {
      final (sc, resp, _) = await accepted();
      await expectLs(
        sc.complete(tweak(resp, nonce: b64urlEncode(_bytes(16, 0x01)))),
        LsErrorCode.authInvalid,
      );
      await nothingStoredAtB();
    });
  });

  // LSP-1 5.3 step 1 (valid 10 min) and 4.3.4 (125 s hold, one held request).
  group('expired_S_rejected', () {
    test(
      '9:59 still works; 10:01 is 404 and hasActiveInvite is false',
      () async {
        final invite = a.service.createInvite();
        clock.jumpWallClock(const Duration(minutes: 9, seconds: 59));
        expect(a.service.hasActiveInvite, isTrue);
        final sc = scan(invite);
        expect((await run(sc)).accepted, isTrue);

        final a2 = _Party('a2-id', 'A2', clock);
        final invite2 = a2.service.createInvite();
        clock.jumpWallClock(const Duration(minutes: 10, seconds: 1));
        expect(a2.service.hasActiveInvite, isFalse);
        final sc2 = b.service.startScan(
          inviteSecretB64: invite2.secretB64,
          inviter: a2.card,
        );
        await expectLs(
          a2.service.handlePair(sc2.request, peer: b.peer),
          LsErrorCode.notFound,
        );
        expect(a2.service.pendingPrompt, isNull);
        expect(a2.trust.contacts, isEmpty);
      },
    );
  });

  group('hold time (virtual time)', () {
    test('125 s without a decision -> accepted:false; before that the request is still held', () async {
      await withFakeTime(clock, (t) async {
        final fa = _Party('fa-id', 'Alice', clock);
        final fb = _Party('fb-id', 'Bob', clock);
        final invite = fa.service.createInvite();
        final sc = fb.service.startScan(
          inviteSecretB64: invite.secretB64,
          inviter: fa.card,
        );
        PairResponse? answer;
        final fut = fa.service
            .handlePair(sc.request, peer: fb.peer)
            .then<void>((r) => answer = r);
        await t.advance(const Duration(seconds: 124));
        expect(answer, isNull, reason: 'still waiting for the inviter');
        expect(fa.service.pendingPrompt, isNotNull);
        await t.advance(const Duration(seconds: 1, milliseconds: 1));
        await fut;
        expect(answer!.accepted, isFalse);
        expect(answer!.mac, isNull);
        expect(fa.service.pendingPrompt, isNull);
        expect(fa.trust.contacts, isEmpty);
        expect(fa.secrets.names, isEmpty);
        expect(
          fa.service.hasActiveInvite,
          isFalse,
          reason: 'a timeout spends the invite',
        );
        // a late tap on Accept changes nothing
        try {
          fa.service.decide(accept: true);
        } on Object {
          // refusing a stale decision is fine too
        }
        await t.pump();
        expect(fa.trust.contacts, isEmpty);
        expect(await sc.complete(answer!), isFalse);
      });
    });

    test('a decision at 124 s still counts (positive twin)', () async {
      await withFakeTime(clock, (t) async {
        final fa = _Party('fa-id', 'Alice', clock);
        final fb = _Party('fb-id', 'Bob', clock);
        final invite = fa.service.createInvite();
        final sc = fb.service.startScan(
          inviteSecretB64: invite.secretB64,
          inviter: fa.card,
        );
        final fut = fa.service.handlePair(sc.request, peer: fb.peer);
        await t.advance(const Duration(seconds: 124));
        fa.service.decide(accept: true);
        final resp = await fut;
        expect(resp.accepted, isTrue);
        expect(await sc.complete(resp), isTrue);
      });
    });

    test('a second valid request while one is held is 409 BUSY; the first can still be decided', () async {
      final invite = a.service.createInvite();
      final first = scan(invite);
      final c = _Party('c-id', 'Carol', clock);
      final second = scan(invite, scanner: c);
      final fut = a.service.handlePair(first.request, peer: b.peer);
      await pumpEventQueue();
      await expectLs(
        a.service.handlePair(second.request, peer: c.peer),
        LsErrorCode.busy,
      );
      expect(a.service.pendingPrompt!.sender.deviceId, 'b-id');
      a.service.decide(accept: true);
      expect((await fut).accepted, isTrue);
      expect(a.trust.contacts.map((c) => c.deviceId), ['b-id']);
    });
  });

  // SPEC-GAP: LSP-1 5.3 does not say what the inviter does when the scanner's device id is
  // already pinned with another key or its fingerprint is blocked. The safer reading is that
  // pairing never overrides either (the same rule as for sessions: KEY_CHANGED is never
  // replaced by anything but an explicit removal, a block is a block).
  group('trust conflicts at the inviter (SPEC-GAP)', () {
    test('known deviceId with another key: 403 KEY_CHANGED, no prompt, pin unchanged', () async {
      final oldKey = freshIdentity('b-id');
      await a.trust.pin(
        deviceId: 'b-id',
        fingerprint: oldKey.identity.fingerprint,
        alias: 'Bob',
        trust: PeerTrust.trusted,
      );
      final sc = scan(a.service.createInvite());
      await expectLs(
        a.service.handlePair(sc.request, peer: b.peer),
        LsErrorCode.keyChanged,
      );
      expect(a.service.pendingPrompt, isNull);
      expect(a.trust.contacts.single.fingerprint, oldKey.identity.fingerprint);
    });

    test(
      'blocked fingerprint: 403 BLOCKED, no prompt, nothing pinned',
      () async {
        await a.trust.block(b.fp);
        final sc = scan(a.service.createInvite());
        await expectLs(
          a.service.handlePair(sc.request, peer: b.peer),
          LsErrorCode.blocked,
        );
        expect(a.service.pendingPrompt, isNull);
        expect(a.trust.contacts, isEmpty);
      },
    );
  });

  // FileReceiver.pair is the seam the HTTP layer calls (SecureTransferHandler.pair); it must
  // hand the request to the PairingService it was given and answer 404 without one.
  group('FileReceiver.pair delegates to the PairingService', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('ls_p4_pair_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    FileReceiver receiverWith(PairingService? pairing) => FileReceiver(
      self: a.card,
      downloadDir: Directory('${tmp.path}/dl')..createSync(),
      autoAccept: false,
      clock: clock,
      freeSpaceProbe: (_) async => null,
      security: SecurityConfig.tls(identity: a.id, trust: a.trust),
      pairing: pairing,
    );

    test('with a service and an invite: held until the user decides, then answered', () async {
      final rx = receiverWith(a.service);
      final sc = scan(a.service.createInvite());
      final fut = rx.pair(
        sc.request,
        remoteAddress: '192.0.2.10',
        peer: b.peer,
      );
      await pumpEventQueue();
      expect(a.service.pendingPrompt, isNotNull);
      a.service.decide(accept: true);
      final resp = await fut;
      expect(resp.accepted, isTrue);
      expect(a.trust.contacts.single.deviceId, 'b-id');
      rx.dispose();
    });

    test(
      'without a service (or without an invite) it is 404 NOT_FOUND',
      () async {
        final none = receiverWith(null);
        final sc = scan(a.service.createInvite());
        await expectLs(
          Future.sync(
            () => none.pair(
              sc.request,
              remoteAddress: '192.0.2.10',
              peer: b.peer,
            ),
          ),
          LsErrorCode.notFound,
        );
        final other = _Party('z-id', 'Z', clock);
        final noInvite = receiverWith(other.service);
        await expectLs(
          Future.sync(
            () => noInvite.pair(
              sc.request,
              remoteAddress: '192.0.2.10',
              peer: b.peer,
            ),
          ),
          LsErrorCode.notFound,
        );
        none.dispose();
        noInvite.dispose();
      },
    );
  });

  // CLAUDE.md / LSP-1 5 Logging: nothing secret in a log, not even at Level.ALL.
  group('log hygiene', () {
    test('S, nonces, MACs, K_pair and fingerprints never reach a log or an error envelope', () async {
      final logs = LogCapture()..start();
      addTearDown(logs.stop);
      final invite = a.service.createInvite();
      final sc = scan(invite);
      final envelopes = <String>[];
      // a wrong MAC, an unknown invite and a decline on the way
      try {
        await a.service.handlePair(
          PairRequest(
            sender: sc.request.sender,
            nonce: sc.request.nonce,
            mac: b64urlEncode(_bytes(32, 3)),
          ),
          peer: b.peer,
        );
      } on LsException catch (e) {
        envelopes.add(jsonEncode(e.toEnvelope()));
      }
      final resp = await run(sc);
      await sc.complete(resp);
      try {
        await a.service.handlePair(sc.request, peer: b.peer);
      } on LsException catch (e) {
        envelopes.add(jsonEncode(e.toEnvelope()));
      }
      final nA = b64urlDecode(resp.nonce!);
      final nB = b64urlDecode(sc.request.nonce);
      final kpair = (await a.secrets.get('kpair/b-id'))!;
      final sentinels = <String, String>{
        'S': invite.secretB64,
        'S-hex': hexOf(invite.secret),
        'nA': resp.nonce!,
        'nB': sc.request.nonce,
        'nA-hex': hexOf(nA),
        'nB-hex': hexOf(nB),
        'reqMac': sc.request.mac,
        'ackMac': resp.mac!,
        'kpair': b64urlEncode(kpair),
        'kpair-hex': hexOf(kpair),
        'fpA': a.fp,
        'fpB': b.fp,
      };
      expect(envelopes, hasLength(2));
      expect(p4Leaks(logs.text, sentinels: sentinels), isEmpty);
      for (final env in envelopes) {
        expect(p4Leaks(env, sentinels: sentinels), isEmpty);
      }
      // harness twin
      expect(
        p4Leaks('s=${invite.secretB64}', sentinels: sentinels),
        containsAll(['sentinel:S', 'base64url-run']),
      );
    });
  });
}

const String fpM =
    '0ABECAEB9C5DD717D0F2184B2B615F1D497EDACFE6A3FC459E298E4D2818FCDB';
