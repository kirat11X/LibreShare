// Security tests for the X-LS-Auth proof and raw signature verification
// (docs/plans/inc3.md section 3 item 3, D1, D9; section 4.1 `unit/identity_proof_test`).
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:libreshare_core/src/security/cert_factory.dart';
import 'package:libreshare_core/src/security/contracts.dart';
import 'package:libreshare_core/src/security/crypto_primitives.dart';
import 'package:libreshare_core/src/security/der.dart';
import 'package:libreshare_core/src/security/identity_proof.dart';
import 'package:libreshare_core/src/security/key_identity.dart';
import 'package:test/test.dart';

final DateTime now = DateTime.utc(2026, 11, 4, 12, 0, 0);
const sessionsPath = '/api/v1/sessions';
final Uint8List body = Uint8List.fromList(utf8.encode('{"hello":"world"}'));

late KeyIdentity client;
late KeyIdentity other;
late KeyIdentity server;
late KeyIdentity otherServer;

NonceCache newCache([DateTime Function()? clock]) =>
    NonceCache(clock: clock ?? () => now);

String build({
  KeyIdentity? who,
  String method = 'POST',
  String path = sessionsPath,
  List<int>? bodyBytes,
  String? serverFp,
  DateTime? at,
  Uint8List? nonce,
}) => buildAuthHeader(
  identity: who ?? client,
  method: method,
  pathAndQuery: path,
  body: bodyBytes ?? body,
  serverFingerprint: serverFp ?? server.identity.fingerprint,
  now: at ?? now,
  nonce: nonce,
);

AuthResult verify(
  String? header, {
  String method = 'POST',
  String path = sessionsPath,
  List<int>? bodyBytes,
  String? ownFp,
  DateTime? at,
  NonceCache? cache,
  Duration? window,
}) => window == null
    ? verifyAuthHeader(
        header: header,
        method: method,
        pathAndQuery: path,
        body: bodyBytes ?? body,
        ownFingerprint: ownFp ?? server.identity.fingerprint,
        now: at ?? now,
        nonces: cache ?? newCache(),
      )
    : verifyAuthHeader(
        header: header,
        method: method,
        pathAndQuery: path,
        body: bodyBytes ?? body,
        ownFingerprint: ownFp ?? server.identity.fingerprint,
        now: at ?? now,
        nonces: cache ?? newCache(),
        window: window,
      );

Matcher failedWith(AuthFailure f) =>
    isA<AuthFailed>().having((r) => r.reason, 'reason', f);

/// Header parts: [v1, cert, ts, nonce, sig].
List<String> parts(String header) => header.split('.');
String join(List<String> p) => p.join('.');

String flipChar(String s, int i) {
  final c = s[i];
  final repl = c == 'A' ? 'B' : 'A';
  return s.replaceRange(i, i + 1, repl);
}

void main() {
  setUpAll(() {
    client = KeyIdentity.fromGenerated(
      generateIdentity(deviceId: 'client-device', now: now),
    );
    other = KeyIdentity.fromGenerated(
      generateIdentity(deviceId: 'other-device', now: now),
    );
    server = KeyIdentity.fromGenerated(
      generateIdentity(deviceId: 'server-device', now: now),
    );
    otherServer = KeyIdentity.fromGenerated(
      generateIdentity(deviceId: 'other-server', now: now),
    );
  });

  group('valid proof', () {
    test('valid_proof_verifies and yields the authenticated peer', () {
      final r = verify(build());
      expect(r, isA<AuthOk>());
      final peer = (r as AuthOk).peer;
      expect(peer.fingerprint, client.identity.fingerprint);
      expect(peer.certDer, client.identity.certDer);
      expect(peer.deviceId, 'client-device');
    });

    test('header grammar: v1.<cert>.<ts ms>.<nonce 22>.<sig 86>', () {
      final h = build();
      final p = parts(h);
      expect(p.length, 5);
      expect(p[0], 'v1');
      expect(b64urlDecode(p[1]), client.identity.certDer);
      expect(p[2], '${now.millisecondsSinceEpoch}');
      expect(p[3].length, 22);
      expect(b64urlDecode(p[3]).length, 16);
      expect(p[4].length, 86);
      expect(b64urlDecode(p[4]).length, 64);
      expect(h.length, lessThan(kMaxAuthHeaderBytes));
      expect(h, matches(RegExp(r'^[A-Za-z0-9_.-]+$')));
    });

    test('nonce is fresh on every call; same inputs + same nonce give the same header', () {
      expect(build(), isNot(build()));
      final n = Uint8List.fromList(List.generate(16, (i) => i));
      expect(build(nonce: n), build(nonce: n));
    });

    test('the signature covers exactly the documented text', () {
      final n = Uint8List.fromList(List.generate(16, (i) => 0x30 + i));
      final h = build(nonce: n, bodyBytes: const []);
      final p = parts(h);
      final text = [
        'POST',
        sessionsPath,
        sha256Hex(const []),
        '${now.millisecondsSinceEpoch}',
        b64urlEncode(n),
        server.identity.fingerprint,
        client.identity.fingerprint,
      ].join('\n');
      expect(
        verifySignature(
          certDer: client.identity.certDer,
          domain: SigDomain.auth,
          message: utf8.encode(text),
          signature: b64urlDecode(p[4]),
        ),
        isTrue,
      );
    });

    test('method is upper-cased on both sides; fingerprints are case-insensitive inputs', () {
      final h = build(
        method: 'post',
        serverFp: server.identity.fingerprint.toLowerCase(),
      );
      expect(verify(h, method: 'POST'), isA<AuthOk>());
      final h2 = build(method: 'POST');
      expect(
        verify(
          h2,
          method: 'post',
          ownFp: server.identity.fingerprint.toLowerCase(),
        ),
        isA<AuthOk>(),
      );
    });

    test('a query string is part of the signed target', () {
      final h = build(path: '/api/v1/info?x=1');
      expect(verify(h, path: '/api/v1/info?x=1'), isA<AuthOk>());
      expect(
        verify(build(path: '/api/v1/info?x=1'), path: '/api/v1/info?x=2'),
        failedWith(AuthFailure.badSignature),
      );
    });

    test('empty bodies work', () {
      expect(
        verify(build(bodyBytes: const []), bodyBytes: const []),
        isA<AuthOk>(),
      );
    });

    test('pathAndQueryOf renders the origin-form target', () {
      expect(
        pathAndQueryOf(Uri.parse('https://1.2.3.4:5/api/v1/info')),
        '/api/v1/info',
      );
      expect(
        pathAndQueryOf(Uri.parse('https://h/api/v1/x?a=b%20c&d=1')),
        '/api/v1/x?a=b%20c&d=1',
      );
      expect(pathAndQueryOf(Uri.parse('https://h')), '/');
    });
  });

  group('tampering (each must fail the signature)', () {
    late String header;
    setUp(() => header = build());

    test('tampered_method', () {
      expect(
        verify(header, method: 'PUT'),
        failedWith(AuthFailure.badSignature),
      );
      expect(
        verify(header, method: 'GET'),
        failedWith(AuthFailure.badSignature),
      );
    });

    test('tampered_path', () {
      expect(
        verify(header, path: '/api/v1/session'),
        failedWith(AuthFailure.badSignature),
      );
      expect(
        verify(header, path: '/api/v1/sessions/'),
        failedWith(AuthFailure.badSignature),
      );
      expect(
        verify(header, path: '/api/v1/register'),
        failedWith(AuthFailure.badSignature),
      );
    });

    test('tampered_body', () {
      final b = Uint8List.fromList(body)..[3] ^= 1;
      expect(
        verify(header, bodyBytes: b),
        failedWith(AuthFailure.badSignature),
      );
      expect(
        verify(header, bodyBytes: const []),
        failedWith(AuthFailure.badSignature),
      );
      expect(
        verify(header, bodyBytes: [...body, 0x20]),
        failedWith(AuthFailure.badSignature),
      );
    });

    test(
      'tampered_ts (within the window, so only the signature can catch it)',
      () {
        final p = parts(header);
        for (final delta in [-1, 1, 1000, -59000]) {
          final q = [...p]..[2] = '${now.millisecondsSinceEpoch + delta}';
          expect(
            verify(join(q)),
            failedWith(AuthFailure.badSignature),
            reason: 'delta $delta',
          );
        }
      },
    );

    test('tampered_nonce', () {
      final p = parts(header);
      final q = [...p]..[3] = flipChar(p[3], 0);
      expect(verify(join(q)), failedWith(AuthFailure.badSignature));
      final q2 = [...p]..[3] = b64urlEncode(secureRandomBytes(16));
      expect(verify(join(q2)), failedWith(AuthFailure.badSignature));
    });

    test('tampered_serverFingerprint (channel binding)', () {
      final r = verify(header, ownFp: otherServer.identity.fingerprint);
      expect(
        r,
        anyOf(
          failedWith(AuthFailure.badSignature),
          failedWith(AuthFailure.serverFingerprintMismatch),
        ),
      );
      expect(r, isA<AuthFailed>());
    });

    test('proof_for_server_A_rejected_by_server_B (a relaying MITM cannot replay it)', () {
      final forA = build(serverFp: server.identity.fingerprint);
      // the MITM terminated TLS with its own certificate, so the client signed ITS fingerprint
      final signedForMitm = build(serverFp: otherServer.identity.fingerprint);
      // the real server (server) receives the relayed proof and refuses it
      expect(
        verify(signedForMitm, ownFp: server.identity.fingerprint),
        isA<AuthFailed>(),
      );
      // and the proof meant for the real server does not work on the MITM either
      expect(
        verify(forA, ownFp: otherServer.identity.fingerprint),
        isA<AuthFailed>(),
      );
      // control
      expect(verify(forA, ownFp: server.identity.fingerprint), isA<AuthOk>());
    });

    test(
      'tampered_clientFp: another certificate with the original signature',
      () {
        final p = parts(header);
        final q = [...p]..[1] = b64urlEncode(other.identity.certDer);
        expect(verify(join(q)), failedWith(AuthFailure.badSignature));
      },
    );

    test('a signature copied onto a different request body/ts/nonce combination fails', () {
      final a = parts(build());
      final b = parts(build(bodyBytes: utf8.encode('{}')));
      final q = [...a]..[4] = b[4];
      expect(verify(join(q)), failedWith(AuthFailure.badSignature));
    });

    test('a flipped signature bit fails', () {
      final p = parts(header);
      final sig = Uint8List.fromList(b64urlDecode(p[4]))..[10] ^= 4;
      final q = [...p]..[4] = b64urlEncode(sig);
      expect(verify(join(q)), failedWith(AuthFailure.badSignature));
    });

    test(
      'domain_separation: a SigDomain.bye signature does not verify as auth',
      () {
        final n = Uint8List.fromList(List.generate(16, (i) => 7 + i));
        final text = [
          'POST',
          sessionsPath,
          sha256Hex(body),
          '${now.millisecondsSinceEpoch}',
          b64urlEncode(n),
          server.identity.fingerprint,
          client.identity.fingerprint,
        ].join('\n');
        final byeSig = client.sign(SigDomain.bye, utf8.encode(text));
        final forged = join([
          'v1',
          b64urlEncode(client.identity.certDer),
          '${now.millisecondsSinceEpoch}',
          b64urlEncode(n),
          b64urlEncode(byeSig),
        ]);
        expect(verify(forged), failedWith(AuthFailure.badSignature));
        // control: the same text signed under the auth domain is accepted
        final okSig = client.sign(SigDomain.auth, utf8.encode(text));
        final good = join([
          'v1',
          b64urlEncode(client.identity.certDer),
          '${now.millisecondsSinceEpoch}',
          b64urlEncode(n),
          b64urlEncode(okSig),
        ]);
        expect(verify(good), isA<AuthOk>());
        // and at the raw level
        expect(
          verifySignature(
            certDer: client.identity.certDer,
            domain: SigDomain.auth,
            message: utf8.encode(text),
            signature: byeSig,
          ),
          isFalse,
        );
        expect(
          verifySignature(
            certDer: client.identity.certDer,
            domain: SigDomain.bye,
            message: utf8.encode(text),
            signature: byeSig,
          ),
          isTrue,
        );
      },
    );
  });

  group('freshness and replay', () {
    test('replayed_nonce_rejected (second use of the same header)', () {
      final cache = newCache();
      final h = build();
      expect(verify(h, cache: cache), isA<AuthOk>());
      expect(verify(h, cache: cache), failedWith(AuthFailure.replayed));
      expect(verify(h, cache: cache), failedWith(AuthFailure.replayed));
    });

    test('a failed verification does not burn the nonce', () {
      final cache = newCache();
      final h = build();
      expect(
        verify(h, bodyBytes: const [1], cache: cache),
        failedWith(AuthFailure.badSignature),
      );
      expect(cache.length, 0);
      expect(verify(h, cache: cache), isA<AuthOk>());
    });

    test('the replay cache is per server instance', () {
      final h = build();
      expect(verify(h, cache: newCache()), isA<AuthOk>());
      expect(verify(h, cache: newCache()), isA<AuthOk>());
    });

    test('stale_timestamp_rejected beyond 120 s in both directions', () {
      final old = build(at: now.subtract(const Duration(seconds: 121)));
      final future = build(at: now.add(const Duration(seconds: 121)));
      expect(verify(old), failedWith(AuthFailure.stale));
      expect(verify(future), failedWith(AuthFailure.stale));
      expect(
        verify(build(at: now.subtract(const Duration(milliseconds: 120001)))),
        failedWith(AuthFailure.stale),
      );
    });

    test('exactly 120 s of skew is still accepted', () {
      expect(
        verify(build(at: now.subtract(const Duration(seconds: 120)))),
        isA<AuthOk>(),
      );
      expect(
        verify(build(at: now.add(const Duration(seconds: 120)))),
        isA<AuthOk>(),
      );
    });

    test('a custom window is honoured', () {
      final h = build(at: now.subtract(const Duration(seconds: 30)));
      expect(
        verify(h, window: const Duration(seconds: 10)),
        failedWith(AuthFailure.stale),
      );
      expect(
        verify(
          build(at: now.subtract(const Duration(seconds: 30))),
          window: const Duration(seconds: 60),
        ),
        isA<AuthOk>(),
      );
    });

    test('a stale header is refused before any signature work and does not enter the cache', () {
      final cache = newCache();
      final r = verify(
        build(at: now.subtract(const Duration(hours: 1))),
        cache: cache,
      );
      expect(r, failedWith(AuthFailure.stale));
      expect(cache.length, 0);
    });
  });

  group('malformed input', () {
    test('missing: null and empty', () {
      expect(verify(null), failedWith(AuthFailure.missing));
      expect(verify(''), failedWith(AuthFailure.missing));
    });

    test('grammar violations are malformed', () {
      final p = parts(build());
      final cases = <String, String>{
        'version v2': join(['v2', ...p.sublist(1)]),
        'version empty': join(['', ...p.sublist(1)]),
        'four parts': p.sublist(0, 4).join('.'),
        'six parts': '${join(p)}.AAAA',
        'one part': 'v1',
        'dots only': '....',
        'empty cert': join([p[0], '', p[2], p[3], p[4]]),
        'empty ts': join([p[0], p[1], '', p[3], p[4]]),
        'empty nonce': join([p[0], p[1], p[2], '', p[4]]),
        'empty sig': join([p[0], p[1], p[2], p[3], '']),
        'padded sig': join([p[0], p[1], p[2], p[3], '${p[4]}=']),
        'standard alphabet': join([
          p[0],
          p[1],
          p[2],
          p[3],
          p[4].replaceFirst(RegExp('[A-Za-z]'), '+'),
        ]),
        'ts leading zero': join([p[0], p[1], '0${p[2]}', p[3], p[4]]),
        'ts plus sign': join([p[0], p[1], '+${p[2]}', p[3], p[4]]),
        'ts negative': join([p[0], p[1], '-1', p[3], p[4]]),
        'ts not a number': join([p[0], p[1], 'abc', p[3], p[4]]),
        'ts with fraction': join([p[0], p[1], '${p[2]}.5', p[3], p[4]]),
        'ts 17 digits': join([p[0], p[1], '12345678901234567', p[3], p[4]]),
        'ts hex': join([p[0], p[1], '0x10', p[3], p[4]]),
        'nonce 21 chars': join([p[0], p[1], p[2], p[3].substring(1), p[4]]),
        'nonce 23 chars': join([p[0], p[1], p[2], '${p[3]}A', p[4]]),
        'nonce non-canonical': join([
          p[0],
          p[1],
          p[2],
          '${p[3].substring(0, 21)}B',
          p[4],
        ]),
        'sig 85 chars': join([p[0], p[1], p[2], p[3], p[4].substring(1)]),
        'sig 87 chars': join([p[0], p[1], p[2], p[3], '${p[4]}A']),
        'newline in header': '${join(p)}\n',
        'space in header': ' ${join(p)}',
        'tab inside': join([
          p[0],
          p[1],
          p[2],
          '${p[3].substring(0, 5)}\t${p[3].substring(6)}',
          p[4],
        ]),
        'non-ascii': join([
          p[0],
          p[1],
          p[2],
          p[3],
          '${p[4].substring(0, 80)}éééééé',
        ]),
        'NUL byte': join([
          p[0],
          p[1],
          p[2],
          '${p[3].substring(0, 5)}\u0000${p[3].substring(6)}',
          p[4],
        ]),
      };
      cases.forEach((name, h) {
        expect(verify(h), failedWith(AuthFailure.malformed), reason: name);
      });
    });

    test(
      'oversized_header: above 4 KiB is malformed, without being parsed',
      () {
        final p = parts(build());
        final huge = join([p[0], 'A' * 5000, p[2], p[3], p[4]]);
        expect(huge.length, greaterThan(kMaxAuthHeaderBytes));
        expect(verify(huge), failedWith(AuthFailure.malformed));
        expect(verify('v1.${'A' * 100000}'), failedWith(AuthFailure.malformed));
        expect(verify('x' * 1000000), failedWith(AuthFailure.malformed));
      },
    );

    test(
      'truncated headers at every length never throw and are never accepted',
      () {
        final h = build();
        for (var n = 0; n < h.length; n++) {
          final r = verify(h.substring(0, n));
          expect(r, isA<AuthFailed>(), reason: 'truncated to $n');
        }
      },
    );

    test(
      'a request target that cannot be signed is malformed, not an exception',
      () {
        final h = build();
        for (final path in [
          '',
          '*',
          'no-slash',
          '/a b',
          '/a\nb',
          '/é',
          '/a\u0000b',
        ]) {
          expect(
            verify(h, path: path),
            failedWith(AuthFailure.malformed),
            reason: path,
          );
        }
        expect(verify(h, method: ''), failedWith(AuthFailure.malformed));
        expect(verify(h, method: 'PO ST'), failedWith(AuthFailure.malformed));
      },
    );

    test('10k_random_headers_never_throw', () {
      final rnd = Random(0xA17);
      const alphabet =
          'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.=+/ \n\t';
      final cache = newCache();
      for (var i = 0; i < 10000; i++) {
        final String h;
        switch (i % 5) {
          case 0:
            h = String.fromCharCodes(
              List.generate(rnd.nextInt(300), (_) => rnd.nextInt(0x300)),
            );
          case 1:
            h = List.generate(
              rnd.nextInt(400),
              (_) => alphabet[rnd.nextInt(alphabet.length)],
            ).join();
          case 2:
            // plausible shape with random pieces
            h = [
              'v1',
              b64urlEncode(secureRandomBytes(rnd.nextInt(700))),
              '${rnd.nextInt(1 << 31) * 1000}',
              b64urlEncode(secureRandomBytes(16)),
              b64urlEncode(secureRandomBytes(64)),
            ].join('.');
          case 3:
            // well-formed pieces around a real certificate but random signature (each of these
            // costs a real verification, so only every 25th iteration takes this branch)
            h = i % 125 == 3
                ? [
                    'v1',
                    b64urlEncode(client.identity.certDer),
                    '${now.millisecondsSinceEpoch + rnd.nextInt(2000) - 1000}',
                    b64urlEncode(secureRandomBytes(16)),
                    b64urlEncode(secureRandomBytes(64)),
                  ].join('.')
                : 'v1.${b64urlEncode(secureRandomBytes(40))}';
          default:
            h = '.' * rnd.nextInt(10);
        }
        final r = verify(h, cache: cache);
        expect(r, isA<AuthFailed>(), reason: 'case ${i % 5}');
      }
      expect(cache.length, 0);
    });

    test('mutated valid headers never throw and are never accepted', () {
      final rnd = Random(0xB22);
      final h = build();
      const url =
          'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.';
      for (var i = 0; i < 800; i++) {
        final cs = h.split('');
        final flips = 1 + rnd.nextInt(3);
        for (var k = 0; k < flips; k++) {
          cs[rnd.nextInt(cs.length)] = url[rnd.nextInt(url.length)];
        }
        final m = cs.join();
        if (m == h) continue;
        expect(verify(m), isA<AuthFailed>());
      }
    });
  });

  group('certificate checks', () {
    String headerWithCert(Uint8List cert, {int ts = -1}) => join([
      'v1',
      b64urlEncode(cert),
      '${ts < 0 ? now.millisecondsSinceEpoch : ts}',
      b64urlEncode(secureRandomBytes(16)),
      b64urlEncode(secureRandomBytes(64)),
    ]);

    final key = generateP256Scalar();
    Uint8List cert({bool ca = false, Uint8List? spki, int padding = 0}) =>
        buildCertificateDer(
          signerKey: key,
          subjectPublicPoint: p256PublicPoint(key),
          subjectCn: 'x',
          notBefore: now,
          notAfter: now.add(const Duration(days: 30)),
          serial: BigInt.one,
          ca: ca,
          spkiOverride: spki,
          extraExtensions: padding == 0
              ? const []
              : [
                  derExtension(
                    oid: '1.2.3.4.5',
                    critical: false,
                    value: derOctetString(Uint8List(padding)),
                  ),
                ],
        );

    test('a CA:true certificate is certInvalid', () {
      expect(
        verify(headerWithCert(cert(ca: true))),
        failedWith(AuthFailure.certInvalid),
      );
    });

    test('wrong key types are certInvalid (P-384, RSA, off-curve)', () {
      final p384 = derSequence([
        derSequence([derOid(oidEcPublicKey), derOid('1.3.132.0.34')]),
        derBitString([4, ...Uint8List(96)]),
      ]);
      final rsa = derSequence([
        derSequence([derOid('1.2.840.113549.1.1.1'), derNull()]),
        derBitString([0x30, 0x03, 0x02, 0x01, 0x01]),
      ]);
      final off = derSequence([
        derSequence([derOid(oidEcPublicKey), derOid(oidPrime256v1)]),
        derBitString(Uint8List.fromList(p256PublicPoint(key))..[50] ^= 1),
      ]);
      for (final spki in [p384, rsa, off]) {
        expect(
          verify(headerWithCert(cert(spki: spki))),
          failedWith(AuthFailure.certInvalid),
        );
      }
    });

    test('oversized_cert is certInvalid (2 KiB cap), at the parse level and on the wire', () {
      var lo = 0;
      var hi = 3000;
      while (lo < hi) {
        final mid = (lo + hi + 1) ~/ 2;
        if (cert(padding: mid).length <= kMaxCertDerBytes) {
          lo = mid;
        } else {
          hi = mid - 1;
        }
      }
      final big = cert(padding: lo + 1);
      expect(big.length, greaterThan(kMaxCertDerBytes));
      expect(verify(headerWithCert(big)), failedWith(AuthFailure.certInvalid));
      // 2100 bytes encodes to more than the 2731 characters a 2 KiB certificate can need
      expect(
        verify(headerWithCert(Uint8List(2100))),
        failedWith(AuthFailure.certInvalid),
      );
      // far beyond any sane size the 4 KiB header cap answers first
      expect(
        verify(headerWithCert(Uint8List(3000))),
        failedWith(AuthFailure.malformed),
      );
    });

    test('garbage and trailing bytes are certInvalid', () {
      expect(
        verify(headerWithCert(Uint8List.fromList([1, 2, 3]))),
        failedWith(AuthFailure.certInvalid),
      );
      expect(
        verify(
          headerWithCert(Uint8List.fromList([...client.identity.certDer, 0])),
        ),
        failedWith(AuthFailure.certInvalid),
      );
      expect(
        verify(headerWithCert(client.identity.certDer.sublist(0, 100))),
        failedWith(AuthFailure.certInvalid),
      );
    });

    test(
      'a certificate whose subject is not a single CN gives deviceId null',
      () {
        final k = generateP256Scalar();
        final c = buildCertificateDer(
          signerKey: k,
          subjectPublicPoint: p256PublicPoint(k),
          subjectCn: 'n' * 65,
          notBefore: now,
          notAfter: now.add(const Duration(days: 30)),
          serial: BigInt.one,
        );
        final nonce = secureRandomBytes(16);
        final text = [
          'POST',
          sessionsPath,
          sha256Hex(body),
          '${now.millisecondsSinceEpoch}',
          b64urlEncode(nonce),
          server.identity.fingerprint,
          fingerprintHex(c),
        ].join('\n');
        final sig = p256SignRaw(
          k,
          domainSeparate(SigDomain.auth, utf8.encode(text)),
        );
        final h = join([
          'v1',
          b64urlEncode(c),
          '${now.millisecondsSinceEpoch}',
          b64urlEncode(nonce),
          b64urlEncode(sig),
        ]);
        final r = verify(h);
        expect(r, isA<AuthOk>());
        expect((r as AuthOk).peer.deviceId, isNull);
        expect(r.peer.fingerprint, fingerprintHex(c));
      },
    );
  });

  group('verifySignature (raw)', () {
    final msg = utf8.encode('message');
    late Uint8List good;
    setUpAll(() => good = client.sign('LSP1-TEST', msg));

    bool v(
      List<int> sig, {
      Uint8List? cert,
      String domain = 'LSP1-TEST',
      List<int>? m,
    }) => verifySignature(
      certDer: cert ?? client.identity.certDer,
      domain: domain,
      message: m ?? msg,
      signature: sig,
    );

    test('accepts a genuine signature', () {
      expect(v(good), isTrue);
    });

    test('rejects r=0, s=0, r>=n, s>=n and wrong lengths', () {
      final r = good.sublist(0, 32);
      final s = good.sublist(32);
      final zero = Uint8List(32);
      final n = bigIntToBytes(kP256Order, 32);
      final nPlus = bigIntToBytes(kP256Order + BigInt.one, 32);
      final ff = Uint8List.fromList(List.filled(32, 0xff));
      final cases = <String, List<int>>{
        'r=0': [...zero, ...s],
        's=0': [...r, ...zero],
        'r=n': [...n, ...s],
        's=n': [...r, ...n],
        'r=n+1': [...nPlus, ...s],
        's=n+1': [...r, ...nPlus],
        'r=max': [...ff, ...s],
        's=max': [...r, ...ff],
        'zeros': Uint8List(64),
        'empty': const <int>[],
        '1 byte': const [1],
        '63 bytes': good.sublist(0, 63),
        '65 bytes': [...good, 0],
        '128 bytes': Uint8List(128),
        'DER encoded': derSequence([
          derInteger(bigIntFromBytes(r)),
          derInteger(bigIntFromBytes(s)),
        ]),
      };
      cases.forEach((name, sig) {
        expect(v(sig), isFalse, reason: name);
      });
    });

    test('rejects a wrong message, wrong domain, wrong key', () {
      expect(v(good, m: utf8.encode('messagf')), isFalse);
      expect(v(good, domain: 'LSP1-TESU'), isFalse);
      expect(v(good, domain: 'LSP1-TEST2'), isFalse);
      expect(v(good, cert: other.identity.certDer), isFalse);
    });

    test('non-P-256 / CA / oversize / garbage certificates verify nothing', () {
      final k = generateP256Scalar();
      Uint8List c({bool ca = false, Uint8List? spki}) => buildCertificateDer(
        signerKey: k,
        subjectPublicPoint: p256PublicPoint(k),
        subjectCn: 'x',
        notBefore: now,
        notAfter: now.add(const Duration(days: 1)),
        serial: BigInt.one,
        ca: ca,
        spkiOverride: spki,
      );
      final sig = p256SignRaw(k, domainSeparate('LSP1-TEST', msg));
      expect(v(sig, cert: c()), isTrue, reason: 'control: valid certificate');
      expect(v(sig, cert: c(ca: true)), isFalse);
      expect(
        v(
          sig,
          cert: c(
            spki: derSequence([
              derSequence([derOid(oidEcPublicKey), derOid('1.3.132.0.34')]),
              derBitString([4, ...Uint8List(96)]),
            ]),
          ),
        ),
        isFalse,
      );
      expect(v(sig, cert: Uint8List(3000)), isFalse);
      expect(v(sig, cert: Uint8List(0)), isFalse);
      expect(v(sig, cert: Uint8List.fromList([0x30, 0x80])), isFalse);
    });

    test('invalid domains verify nothing and do not throw', () {
      expect(v(good, domain: ''), isFalse);
      expect(v(good, domain: 'A\u0000B'), isFalse);
    });

    test('random signatures never throw and never verify', () {
      final rnd = Random(77);
      for (var i = 0; i < 300; i++) {
        final sig = Uint8List.fromList(
          List.generate(64, (_) => rnd.nextInt(256)),
        );
        expect(v(sig), isFalse);
      }
    });
  });

  group('NonceCache', () {
    test('defaults: 5 minutes, 8192 entries', () {
      expect(kNonceCacheTtl, const Duration(minutes: 5));
      expect(kNonceCacheCapacity, 8192);
    });

    test('add reports first use; contains sees it', () {
      final c = NonceCache(clock: () => now);
      expect(c.contains('a'), isFalse);
      expect(c.add('a'), isTrue);
      expect(c.contains('a'), isTrue);
      expect(c.add('a'), isFalse);
      expect(c.length, 1);
    });

    test('entries expire after the TTL (injectable clock)', () {
      var t = now;
      final c = NonceCache(clock: () => t);
      c.add('a');
      t = now.add(const Duration(minutes: 4, seconds: 59));
      expect(c.contains('a'), isTrue);
      t = now.add(const Duration(minutes: 5));
      expect(c.contains('a'), isFalse);
      expect(c.length, 0);
      expect(c.add('a'), isTrue);
    });

    test('LRU bound: the oldest entry is evicted first', () {
      final c = NonceCache(capacity: 3, clock: () => now);
      for (final k in ['a', 'b', 'c']) {
        c.add(k);
      }
      c.add('d');
      expect(c.length, 3);
      expect(c.contains('a'), isFalse);
      for (final k in ['b', 'c', 'd']) {
        expect(c.contains(k), isTrue);
      }
    });

    test('default capacity holds 8192 and evicts beyond it', () {
      final c = NonceCache(clock: () => now);
      for (var i = 0; i < 9000; i++) {
        c.add('k$i');
      }
      expect(c.length, 8192);
      expect(c.contains('k0'), isFalse);
      expect(c.contains('k8999'), isTrue);
    });

    test('expired entries are purged before the capacity applies', () {
      var t = now;
      final c = NonceCache(capacity: 2, clock: () => t);
      c.add('a');
      c.add('b');
      t = now.add(const Duration(minutes: 6));
      c.add('c');
      c.add('d');
      expect(c.contains('c'), isTrue);
      expect(c.contains('d'), isTrue);
      expect(c.length, 2);
    });
  });

  group('input validation and diagnostics', () {
    test('buildAuthHeader refuses unusable inputs', () {
      final fp = server.identity.fingerprint;
      expect(
        () => buildAuthHeader(
          identity: client,
          method: '',
          pathAndQuery: '/x',
          body: const [],
          serverFingerprint: fp,
        ),
        throwsArgumentError,
      );
      expect(
        () => buildAuthHeader(
          identity: client,
          method: 'P OST',
          pathAndQuery: '/x',
          body: const [],
          serverFingerprint: fp,
        ),
        throwsArgumentError,
      );
      for (final path in ['', 'x', '/a b', '/a\nb', '/é']) {
        expect(
          () => buildAuthHeader(
            identity: client,
            method: 'GET',
            pathAndQuery: path,
            body: const [],
            serverFingerprint: fp,
          ),
          throwsArgumentError,
          reason: path,
        );
      }
      for (final bad in ['', 'abc', '${fp}0', fp.substring(1)]) {
        expect(
          () => buildAuthHeader(
            identity: client,
            method: 'GET',
            pathAndQuery: '/x',
            body: const [],
            serverFingerprint: bad,
          ),
          throwsArgumentError,
          reason: bad,
        );
      }
      for (final len in [0, 15, 17]) {
        expect(
          () => buildAuthHeader(
            identity: client,
            method: 'GET',
            pathAndQuery: '/x',
            body: const [],
            serverFingerprint: fp,
            nonce: Uint8List(len),
          ),
          throwsArgumentError,
          reason: 'nonce $len',
        );
      }
    });

    test('now defaults to the wall clock', () {
      final h = buildAuthHeader(
        identity: client,
        method: 'GET',
        pathAndQuery: '/x',
        body: const [],
        serverFingerprint: server.identity.fingerprint,
      );
      final ts = int.parse(parts(h)[2]);
      expect(
        (ts - DateTime.now().millisecondsSinceEpoch).abs(),
        lessThan(5000),
      );
    });

    test('result toString carries at most a short fingerprint and no key or signature data', () {
      final h = build();
      final ok = verify(h);
      final text = ok.toString();
      expect(text.contains(client.identity.fingerprint), isFalse);
      expect(text, contains(shortFp(client.identity.fingerprint)));
      final p = parts(h);
      expect(text.contains(p[1].substring(0, 30)), isFalse);
      expect(text.contains(p[4]), isFalse);
      expect(
        verify(h, cache: newCache(), bodyBytes: const [9]).toString(),
        'AuthFailed(badSignature)',
      );
    });

    test(
      'no exception or result text contains key material on any failure path',
      () {
        final d = decodePkcs8PrivateKeyPem(client.privateKeyPem());
        final secrets = <String>[
          hexOf(bigIntToBytes(d, 32)),
          b64urlEncode(bigIntToBytes(d, 32)),
          base64.encode(bigIntToBytes(d, 32)),
        ];
        final p = parts(build());
        final results = <Object>[
          verify(null),
          verify(''),
          verify('garbage'),
          verify(join([p[0], p[1], p[2], p[3], flipChar(p[4], 0)])),
          verify(build(), bodyBytes: const [1]),
          verify(build(at: now.subtract(const Duration(hours: 2)))),
        ];
        try {
          buildAuthHeader(
            identity: client,
            method: '',
            pathAndQuery: '/x',
            body: const [],
            serverFingerprint: server.identity.fingerprint,
          );
        } on ArgumentError catch (e) {
          results.add(e);
        }
        for (final r in results) {
          for (final s in secrets) {
            expect('$r'.contains(s), isFalse);
          }
        }
      },
    );
  });

  group('known_answer_vector (docs/protocol/test-vectors-inc3.md section 3)', () {
    // Key: RFC 6979 A.2.5 test key (public). Signatures are deterministic (RFC 6979), so the whole
    // header is reproducible. Independently reproduced with Python cryptography (certificate
    // parsing, fingerprint, signed text) and `openssl dgst -sign -sigopt nonce-type:1`.
    final d = BigInt.parse(
      'c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721',
      radix: 16,
    );
    const serverFp =
        'F257EE87F7B71A1A495B40699CF5AAD04B668A2A5C684062C5B58D5EFB9642DD';
    const clientFp =
        '8279AFD34ED7AA162D8B04101F577788BC4EE216C7816129125E4ECB0D6D0438';
    const certHex =
        '308201673082010ea003020102020f0102030405060708090a0b0c0d0e0f300a'
        '06082a8648ce3d040302301b3119301706035504030c106c732d766563746f72'
        '2d636c69656e74301e170d3236313130333132303030305a170d333631313031'
        '3132303030305a301b3119301706035504030c106c732d766563746f722d636c'
        '69656e743059301306072a8648ce3d020106082a8648ce3d0301070342000460'
        'fed4ba255a9d31c961eb74c6356d68c049b8923b61fa6ce669622e60f29fb679'
        '03fe1008b8bc99a41ae9e95628bc64f2f1b20c2d7e9f5177a3c294d4462299a3'
        '353033300c0603551d130101ff04023000300e0603551d0f0101ff0404030207'
        '8030130603551d25040c300a06082b06010505070301300a06082a8648ce3d04'
        '030203470030440220608155e0edc2a136d45124064e70e2fee5d0c61406f743'
        '49f138609fc0d6277c022042e672d9ec170d8c6f19bb482bc33298c3d4b9c4b5'
        '3a1f7755eb6ef8f8415589';
    const expectedHeader =
        'v1.MIIBZzCCAQ6gAwIBAgIPAQIDBAUGBwgJCgsMDQ4PMAoGCCqGSM49BAMCMBsxG'
        'TAXBgNVBAMMEGxzLXZlY3Rvci1jbGllbnQwHhcNMjYxMTAzMTIwMDAwWhcNMzYxM'
        'TAxMTIwMDAwWjAbMRkwFwYDVQQDDBBscy12ZWN0b3ItY2xpZW50MFkwEwYHKoZIz'
        'j0CAQYIKoZIzj0DAQcDQgAEYP7UuiVanTHJYet0xjVtaMBJuJI7Yfps5mliLmDyn'
        '7Z5A_4QCLi8maQa6elWKLxk8vGyDC1-n1F3o8KU1EYimaM1MDMwDAYDVR0TAQH_B'
        'AIwADAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwEwCgYIKoZIz'
        'j0EAwIDRwAwRAIgYIFV4O3CoTbUUSQGTnDi_uXQxhQG90NJ8Thgn8DWJ3wCIELmc'
        'tnsFw2Mbxm7SCvDMpjD1LnEtTofd1Xrbvj4QVWJ.1793793605000.ICEiIyQlJi'
        'coKSorLC0uLw.2xvt7F7EGxRNlILs7dRdK4dNv0eJ4p6tRgt_uFnSJwWni3phVVr'
        '8niQVwdVWuIUH1tSUG_QwFqS4hgWe1Al9bw';
    const expectedSignedBytesHex =
        '4c5350312d415554482d763100504f53540a2f6170692f76312f73657373696f'
        '6e730a3933613233393731613931346535656163626630613864323531353463'
        '6461333039633363316337326662623939313464343763363066336362363831'
        '3538380a313739333739333630353030300a494345694979516c4a69636f4b53'
        '6f724c4330754c770a4632353745453837463742373141314134393542343036'
        '3939434635414144303442363638413241354336383430363243354235384435'
        '4546423936343244440a38323739414644333445443741413136324438423034'
        '3130314635373737383842433445453231364337383136313239313235453445'
        '43423044364430343338';
    const expectedSigHex =
        'db1bedec5ec41b144d9482ecedd45d2b874dbf4789e29ead460b7fb859d22705'
        'a78b7a61555afc9e2415c1d556b88507d6d4941bf43016a4b886059ed4097d6f';
    final vectorBody = utf8.encode('{"hello":"world"}');
    final vectorNonce = Uint8List.fromList(List.generate(16, (i) => 0x20 + i));
    final vectorAt = DateTime.utc(2026, 11, 4, 12, 0, 5);

    late KeyIdentity vectorClient;
    setUpAll(() {
      vectorClient = KeyIdentity.fromGenerated(
        identityFromScalar(
          deviceId: 'ls-vector-client',
          privateScalar: d,
          now: DateTime.utc(2026, 11, 4, 12),
          serial: BigInt.parse('0102030405060708090a0b0c0d0e0f', radix: 16),
        ),
      );
    });

    test('the vector certificate and fingerprint are reproducible', () {
      expect(hexOf(vectorClient.identity.certDer), certHex);
      expect(vectorClient.identity.fingerprint, clientFp);
    });

    test('buildAuthHeader reproduces the published header byte for byte', () {
      final h = buildAuthHeader(
        identity: vectorClient,
        method: 'POST',
        pathAndQuery: '/api/v1/sessions',
        body: vectorBody,
        serverFingerprint: serverFp,
        now: vectorAt,
        nonce: vectorNonce,
      );
      expect(h, expectedHeader);
    });

    test('signed bytes and signature are the published ones', () {
      final message = buildAuthMessage(
        method: 'POST',
        pathAndQuery: '/api/v1/sessions',
        body: vectorBody,
        timestampMs: vectorAt.millisecondsSinceEpoch,
        nonceB64: b64urlEncode(vectorNonce),
        serverFingerprint: serverFp,
        clientFingerprint: clientFp,
      );
      expect(
        hexOf(domainSeparate(SigDomain.auth, message)),
        expectedSignedBytesHex,
      );
      expect(hexOf(b64urlDecode(parts(expectedHeader)[4])), expectedSigHex);
      expect(
        sha256Hex(vectorBody),
        '93a23971a914e5eacbf0a8d25154cda309c3c1c72fbb9914d47c60f3cb681588',
      );
    });

    test('bye signature vector: domain LSP1-BYE over deviceId+fingerprint+ts', () {
      const byeText =
          'ls-vector-client8279AFD34ED7AA162D8B04101F577788BC4EE216C7816129125E4ECB0D6D04381793793600000';
      const byeSigHex =
          'a810c850c55ddb86be8ade8f00ef9f1e2ec668d93a527b3de7f7474b3d99d18b'
          '8436432ad9a087c2e94e63c2f32b7e28dd6fc62ce43831d8a50b85a61c12969d';
      expect(
        byeText,
        'ls-vector-client${vectorClient.identity.fingerprint}1793793600000',
      );
      final sig = vectorClient.sign(SigDomain.bye, utf8.encode(byeText));
      expect(hexOf(sig), byeSigHex);
      expect(
        b64urlEncode(sig),
        'qBDIUMVd24a-it6PAO-fHi7GaNk6Uns95_dHSz2Z0YuENkMq2aCHwulOY8LzK34o3W_GLOQ4MdilC4WmHBKWnQ',
      );
      expect(
        verifySignature(
          certDer: vectorClient.identity.certDer,
          domain: SigDomain.bye,
          message: utf8.encode(byeText),
          signature: sig,
        ),
        isTrue,
      );
      expect(
        verifySignature(
          certDer: vectorClient.identity.certDer,
          domain: SigDomain.auth,
          message: utf8.encode(byeText),
          signature: sig,
        ),
        isFalse,
      );
    });

    test('the published header verifies for the right request and fails for any other', () {
      AuthResult check({
        String method = 'POST',
        String path = '/api/v1/sessions',
        List<int>? b,
        String fp = serverFp,
        DateTime? at,
      }) => verifyAuthHeader(
        header: expectedHeader,
        method: method,
        pathAndQuery: path,
        body: b ?? vectorBody,
        ownFingerprint: fp,
        now: at ?? vectorAt,
        nonces: NonceCache(clock: () => vectorAt),
      );
      final ok = check();
      expect(ok, isA<AuthOk>());
      expect((ok as AuthOk).peer.fingerprint, clientFp);
      expect(ok.peer.deviceId, 'ls-vector-client');
      expect(check(method: 'GET'), failedWith(AuthFailure.badSignature));
      expect(
        check(path: '/api/v1/session'),
        failedWith(AuthFailure.badSignature),
      );
      expect(check(b: const []), failedWith(AuthFailure.badSignature));
      expect(
        check(
          fp: 'A257EE87F7B71A1A495B40699CF5AAD04B668A2A5C684062C5B58D5EFB9642DD',
        ),
        failedWith(AuthFailure.badSignature),
      );
      expect(
        check(at: vectorAt.add(const Duration(seconds: 121))),
        failedWith(AuthFailure.stale),
      );
    });
  });
}
