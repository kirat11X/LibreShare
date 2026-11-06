// Known-answer conformance for LSP/1.1 (docs/protocol/test-vectors-inc3.md).
//
// Every fixed vector of the vector file is asserted against the REAL production
// functions. The expected values below are copied from the vector file, and a
// guard test checks that each copied constant still occurs in that file, so a
// vector that is edited without this test (or the other way round) fails here.
//
// Driven with fixed keys and fixed time/nonces (full end to end):
//  * the certificate (`identityFromScalar`), its fingerprint, `X-LS-Auth`
//    (`buildAuthHeader`), the `bye` datagram (`encodeBye`): ECDSA signing is
//    RFC 6979 deterministic, so the signature bytes are asserted too.
// Deterministic parts only (the production caller draws its own randomness):
//  * SAS commit and code (`sasCommit`, `sasCode`, fed with the fixed nonces),
//    pairing MACs and K_pair (`pairRequestMac`, `pairAckMac`, `derivePairKey`),
//    HKDF and HMAC primitives.
//
// Also here: the schema `examples` and the vector-derived messages validate
// against the schemas (a small drift guard for docs vs schemas).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:json_schema/json_schema.dart';
import 'package:libreshare_core/libreshare_core.dart';
import 'package:libreshare_core/src/security/cert_factory.dart'
    show identityFromScalar, p256SignRaw;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String? _findUp(String relative) {
  var dir = Directory.current.absolute;
  while (true) {
    final candidate = p.join(dir.path, relative);
    if (FileSystemEntity.typeSync(candidate) != FileSystemEntityType.notFound) {
      return candidate;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
}

final String _vectorsPath =
    _findUp(p.join('docs', 'protocol', 'test-vectors-inc3.md')) ??
    (throw StateError('docs/protocol/test-vectors-inc3.md not found'));
final String _schemasDir =
    _findUp(p.join('docs', 'protocol', 'schemas')) ??
    (throw StateError('docs/protocol/schemas not found'));

/// The vector file without any whitespace, for the "constant is in the file" guard.
final String _flatVectors = File(_vectorsPath)
    .readAsStringSync()
    .replaceAll(RegExp(r'\s+'), '');

/// Asserts that [value] occurs in the vector file and returns it.
String v(String name, String value) {
  expect(
    _flatVectors.contains(value.replaceAll(RegExp(r'\s+'), '')),
    isTrue,
    reason: 'constant "$name" is not in $_vectorsPath',
  );
  return value;
}

Uint8List fromHex(String s) {
  final h = s.replaceAll(RegExp(r'\s+'), '');
  final out = Uint8List(h.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

List<int> seq(int start, int n) => List<int>.generate(n, (i) => start + i);

String sha256OfString(String s) => c.sha256.convert(utf8.encode(s)).toString();

// ------------------------------------------------------------ vector inputs

const _d = 'c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721';
const _clientFp =
    '8279AFD34ED7AA162D8B04101F577788BC4EE216C7816129125E4ECB0D6D0438';
const _serverFp =
    'F257EE87F7B71A1A495B40699CF5AAD04B668A2A5C684062C5B58D5EFB9642DD';
const _bodyHash =
    '93a23971a914e5eacbf0a8d25154cda309c3c1c72fbb9914d47c60f3cb681588';
const _tsMs = 1793793605000;
const _nonceB64 = 'ICEiIyQlJicoKSorLC0uLw';
const _certHex =
    '308201673082010ea003020102020f0102030405060708090a0b0c0d0e0f300a06082a8648ce3d040302301b31193017'
    '06035504030c106c732d766563746f722d636c69656e74301e170d3236313130333132303030305a170d333631313031'
    '3132303030305a301b3119301706035504030c106c732d766563746f722d636c69656e743059301306072a8648ce3d02'
    '0106082a8648ce3d0301070342000460fed4ba255a9d31c961eb74c6356d68c049b8923b61fa6ce669622e60f29fb679'
    '03fe1008b8bc99a41ae9e95628bc64f2f1b20c2d7e9f5177a3c294d4462299a3353033300c0603551d130101ff040230'
    '00300e0603551d0f0101ff04040302078030130603551d25040c300a06082b06010505070301300a06082a8648ce3d04'
    '030203470030440220608155e0edc2a136d45124064e70e2fee5d0c61406f74349f138609fc0d6277c022042e672d9ec'
    '170d8c6f19bb482bc33298c3d4b9c4b53a1f7755eb6ef8f8415589';
const _certPem = '''
-----BEGIN CERTIFICATE-----
MIIBZzCCAQ6gAwIBAgIPAQIDBAUGBwgJCgsMDQ4PMAoGCCqGSM49BAMCMBsxGTAX
BgNVBAMMEGxzLXZlY3Rvci1jbGllbnQwHhcNMjYxMTAzMTIwMDAwWhcNMzYxMTAx
MTIwMDAwWjAbMRkwFwYDVQQDDBBscy12ZWN0b3ItY2xpZW50MFkwEwYHKoZIzj0C
AQYIKoZIzj0DAQcDQgAEYP7UuiVanTHJYet0xjVtaMBJuJI7Yfps5mliLmDyn7Z5
A/4QCLi8maQa6elWKLxk8vGyDC1+n1F3o8KU1EYimaM1MDMwDAYDVR0TAQH/BAIw
ADAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwEwCgYIKoZIzj0E
AwIDRwAwRAIgYIFV4O3CoTbUUSQGTnDi/uXQxhQG90NJ8Thgn8DWJ3wCIELmctns
Fw2Mbxm7SCvDMpjD1LnEtTofd1Xrbvj4QVWJ
-----END CERTIFICATE-----
''';
const _signedTextEscaped =
    r'POST\n/api/v1/sessions\n93a23971a914e5eacbf0a8d25154cda309c3c1c72fbb9914d47c60f3cb681588'
    r'\n1793793605000\nICEiIyQlJicoKSorLC0uLw'
    r'\nF257EE87F7B71A1A495B40699CF5AAD04B668A2A5C684062C5B58D5EFB9642DD'
    r'\n8279AFD34ED7AA162D8B04101F577788BC4EE216C7816129125E4ECB0D6D0438';
const _signedBytesHex =
    '4c5350312d415554482d763100504f53540a2f6170692f76312f73657373696f6e730a39336132333937316139313465'
    '356561636266306138643235313534636461333039633363316337326662623939313464343763363066336362363831'
    '3538380a313739333739333630353030300a494345694979516c4a69636f4b536f724c4330754c770a46323537454538'
    '374637423731413141343935423430363939434635414144303442363638413241354336383430363243354235384435'
    '4546423936343244440a3832373941464433344544374141313632443842303431303146353737373838424334454532'
    '3136433738313631323931323545344543423044364430343338';
const _sigHex =
    'db1bedec5ec41b144d9482ecedd45d2b874dbf4789e29ead460b7fb859d22705a78b7a61555afc9e2415c1d556b88507d6d4941bf43016a4b886059ed4097d6f';
const _header =
    'v1.MIIBZzCCAQ6gAwIBAgIPAQIDBAUGBwgJCgsMDQ4PMAoGCCqGSM49BAMCMBsxGTAXBgNVBAMMEGxzLXZlY3Rvci1jbGllbnQwHhcNMjYxMTAzMTIwMDAwWhcNMzYxMTAxMTIwMDAwWjAbMRkwFwYDVQQDDBBscy12ZWN0b3ItY2xpZW50MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEYP7UuiVanTHJYet0xjVtaMBJuJI7Yfps5mliLmDyn7Z5A_4QCLi8maQa6elWKLxk8vGyDC1-n1F3o8KU1EYimaM1MDMwDAYDVR0TAQH_BAIwADAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwEwCgYIKoZIzj0EAwIDRwAwRAIgYIFV4O3CoTbUUSQGTnDi_uXQxhQG90NJ8Thgn8DWJ3wCIELmctnsFw2Mbxm7SCvDMpjD1LnEtTofd1Xrbvj4QVWJ.1793793605000.ICEiIyQlJicoKSorLC0uLw.2xvt7F7EGxRNlILs7dRdK4dNv0eJ4p6tRgt_uFnSJwWni3phVVr8niQVwdVWuIUH1tSUG_QwFqS4hgWe1Al9bw';

// SAS and pairing
const _fpS = 'AE91A910C4E3D642640BD9CCFCBD18A6BB2ACF0091BEFFF1D7BD56C437F99EFF';
const _fpR = 'F257EE87F7B71A1A495B40699CF5AAD04B668A2A5C684062C5B58D5EFB9642DD';
const _fpM = '0ABECAEB9C5DD717D0F2184B2B615F1D497EDACFE6A3FC459E298E4D2818FCDB';

// Goodbye
const _byeTs = 1793793600000;
const _byeText =
    'ls-vector-client8279AFD34ED7AA162D8B04101F577788BC4EE216C7816129125E4ECB0D6D04381793793600000';
const _byeSigHex =
    'a810c850c55ddb86be8ade8f00ef9f1e2ec668d93a527b3de7f7474b3d99d18b8436432ad9a087c2e94e63c2f32b7e28dd6fc62ce43831d8a50b85a61c12969d';
const _byeSigB64 =
    'qBDIUMVd24a-it6PAO-fHi7GaNk6Uns95_dHSz2Z0YuENkMq2aCHwulOY8LzK34o3W_GLOQ4MdilC4WmHBKWnQ';

// -------------------------------------------------------- schema machinery

final Map<String, Map<String, Object?>> _docs = {};
final Map<String, JsonSchema> _schemas = {};

void _loadSchemas() {
  final files =
      Directory(_schemasDir)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.schema.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final byId = <String, Map<String, Object?>>{};
  for (final f in files) {
    final doc = (jsonDecode(f.readAsStringSync()) as Map)
        .cast<String, Object?>();
    _docs[p.basename(f.path).replaceFirst('.schema.json', '')] = doc;
    byId[doc[r'$id']! as String] = doc;
  }
  final provider = RefProvider.sync(
    (String ref) => byId[ref] ?? byId[ref.split('#').first],
  );
  for (final e in _docs.entries) {
    _schemas[e.key] = JsonSchema.create(
      e.value,
      schemaVersion: SchemaVersion.draft2020_12,
      refProvider: provider,
    );
  }
}

void expectValid(String schema, Object? instance, String what) {
  final r = _schemas[schema]!.validate(instance, validateFormats: true);
  expect(
    r.isValid,
    isTrue,
    reason: '$what vs $schema: ${r.errors.join('; ')}\n${jsonEncode(instance)}',
  );
}

void expectInvalid(String schema, Object? instance, String what) {
  expect(
    _schemas[schema]!.validate(instance, validateFormats: true).isValid,
    isFalse,
    reason: '$what should violate $schema',
  );
}

void main() {
  late KeyIdentity client;
  final body = utf8.encode('{"hello":"world"}');
  final nonce = Uint8List.fromList(seq(0x20, 16));
  final at = DateTime.fromMillisecondsSinceEpoch(_tsMs, isUtc: true);

  setUpAll(() {
    _loadSchemas();
    client = KeyIdentity.fromGenerated(
      identityFromScalar(
        deviceId: 'ls-vector-client',
        privateScalar: BigInt.parse(_d, radix: 16),
        now: DateTime.utc(2026, 11, 4, 12),
        serial: BigInt.parse('0102030405060708090a0b0c0d0e0f', radix: 16),
      ),
    );
  });

  group('guard: constants copied from the vector file are in the file', () {
    test(
      'every expected value occurs in docs/protocol/test-vectors-inc3.md',
      () {
        final all = <String, String>{
          'd': _d,
          'clientFp': _clientFp,
          'serverFp': _serverFp,
          'bodyHash': _bodyHash,
          'ts': '$_tsMs',
          'nonceB64': _nonceB64,
          'certHex': _certHex,
          'signedText': _signedTextEscaped,
          'signedBytes': _signedBytesHex,
          'sig': _sigHex,
          'header': _header,
          'fpS': _fpS,
          'fpR': _fpR,
          'fpM': _fpM,
          'byeTs': '$_byeTs',
          'byeText': _byeText,
          'byeSigHex': _byeSigHex,
          'byeSigB64': _byeSigB64,
          'pem-body': _certPem
              .split('\n')
              .where((l) => l.isNotEmpty && !l.startsWith('-----'))
              .join(),
        };
        for (final e in all.entries) {
          v(e.key, e.value);
        }
      },
    );

    test('the SAS fingerprints are SHA-256 of the documented strings', () {
      expect(
        sha256OfString('LibreShare Inc3 test vector: sender certificate'),
        _fpS.toLowerCase(),
      );
      expect(
        sha256OfString('LibreShare Inc3 test vector: receiver certificate'),
        _fpR.toLowerCase(),
      );
      expect(
        sha256OfString('LibreShare Inc3 test vector: mitm certificate'),
        _fpM.toLowerCase(),
      );
    });
  });

  group('section 1: domain labels', () {
    test('SigDomain equals the documented labels', () {
      expect(SigDomain.auth, v('auth', 'LSP1-AUTH-v1'));
      expect(SigDomain.sasCommit, v('sasC', 'LSP1-SAS-C'));
      expect(SigDomain.sasValue, v('sasV', 'LSP1-SAS-V'));
      expect(SigDomain.bye, v('bye', 'LSP1-BYE'));
      expect(SigDomain.pairRequest, v('req', 'LSP1-PAIR-REQ'));
      expect(SigDomain.pairAck, v('ack', 'LSP1-PAIR-ACK'));
      expect(SigDomain.pairInfo, v('info', 'LSP-R1 pair'));
    });

    test('domainSeparate is label || 0x00 || message', () {
      expect(domainSeparate('LSP1-BYE', [1, 2]), [
        ...utf8.encode('LSP1-BYE'),
        0,
        1,
        2,
      ]);
    });
  });

  group('section 2: HKDF-SHA-256 and HMAC-SHA-256', () {
    test('RFC 5869 A.1', () {
      final okm = hkdfSha256(
        ikm: List.filled(22, 0x0b),
        salt: fromHex(v('A1salt', '000102030405060708090a0b0c')),
        info: fromHex(v('A1info', 'f0f1f2f3f4f5f6f7f8f9')),
        length: 42,
      );
      expect(
        hexOf(okm),
        v(
          'A1okm',
          '3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865',
        ),
      );
    });

    test('RFC 5869 A.3 (empty salt and info)', () {
      final okm = hkdfSha256(
        ikm: List.filled(22, 0x0b),
        salt: const [],
        info: const [],
        length: 42,
      );
      expect(
        hexOf(okm),
        v(
          'A3okm',
          '8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8',
        ),
      );
    });

    test('RFC 4231 case 1: HMAC-SHA-256(0b x 20, "Hi There")', () {
      expect(
        hexOf(hmacSha256(List.filled(20, 0x0b), utf8.encode('Hi There'))),
        v(
          'hmac',
          'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7',
        ),
      );
    });

    test('RFC 6979 A.2.5 base case: P-256/SHA-256 over "sample"', () {
      final sig = p256SignRaw(
        BigInt.parse(_d, radix: 16),
        utf8.encode('sample'),
      );
      expect(
        hexOf(sig.sublist(0, 32)),
        'efd48b2aacb6a8fd1140dd9cd45e81d69d2c877b56aaf991c34d0ea84eaf3716',
      );
      expect(
        hexOf(sig.sublist(32)),
        'f7cb1c942d657c41d436c7a1b6e29f65f3e900dbb9aff4064dc4ab2f843acda8',
      );
      v(
        'rfc6979 r',
        'efd48b2aacb6a8fd1140dd9cd45e81d69d2c877b56aaf991c34d0ea84eaf3716',
      );
      v(
        'rfc6979 s',
        'f7cb1c942d657c41d436c7a1b6e29f65f3e900dbb9aff4064dc4ab2f843acda8',
      );
    });
  });

  group('section 3: X-LS-Auth', () {
    test(
      'the vector certificate: DER, PEM, size, validity, CN, fingerprint',
      () {
        final id = client.identity;
        expect(hexOf(id.certDer), _certHex.replaceAll(RegExp(r'\s'), ''));
        expect(id.certDer.length, 363);
        expect(id.certPem.trim(), _certPem.trim());
        expect(id.fingerprint, _clientFp);
        expect(fingerprintHex(fromHex(_certHex)), _clientFp);
        expect(id.deviceId, 'ls-vector-client');
        final parsed = parseCertificate(id.certDer);
        expect(parsed.subjectCn, 'ls-vector-client');
        expect(parsed.notBefore.toUtc(), DateTime.utc(2026, 11, 3, 12));
        expect(parsed.notAfter.toUtc(), DateTime.utc(2036, 11, 1, 12));
        expect(
          hexOf(parsed.publicPoint),
          '04'
          '60fed4ba255a9d31c961eb74c6356d68c049b8923b61fa6ce669622e60f29fb6'
          '7903fe1008b8bc99a41ae9e95628bc64f2f1b20c2d7e9f5177a3c294d4462299',
        );
      },
    );

    test('hex(SHA-256(body)) and the nonce text', () {
      expect(body.length, 17);
      expect(c.sha256.convert(body).toString(), _bodyHash);
      expect(b64urlEncode(nonce), _nonceB64);
      expect(hexOf(nonce), '202122232425262728292a2b2c2d2e2f');
      expect(at.toIso8601String(), '2026-11-04T12:00:05.000Z');
    });

    test('signed text M', () {
      final m = buildAuthMessage(
        method: 'POST',
        pathAndQuery: '/api/v1/sessions',
        body: body,
        timestampMs: _tsMs,
        nonceB64: _nonceB64,
        serverFingerprint: _serverFp,
        clientFingerprint: _clientFp,
      );
      expect(utf8.decode(m).replaceAll('\n', r'\n'), _signedTextEscaped);
      expect('\n'.allMatches(utf8.decode(m)).length, 6);
    });

    test('signed bytes "LSP1-AUTH-v1" 0x00 M', () {
      final m = buildAuthMessage(
        method: 'post',
        pathAndQuery: '/api/v1/sessions',
        body: body,
        timestampMs: _tsMs,
        nonceB64: _nonceB64,
        serverFingerprint: _serverFp,
        clientFingerprint: _clientFp,
      );
      expect(hexOf(domainSeparate(SigDomain.auth, m)), _signedBytesHex);
    });

    test('signature r||s of the signed bytes (RFC 6979, reproducible)', () {
      final m = buildAuthMessage(
        method: 'POST',
        pathAndQuery: '/api/v1/sessions',
        body: body,
        timestampMs: _tsMs,
        nonceB64: _nonceB64,
        serverFingerprint: _serverFp,
        clientFingerprint: _clientFp,
      );
      final sig = client.sign(SigDomain.auth, m);
      expect(sig.length, 64);
      expect(hexOf(sig), _sigHex);
      expect(
        verifySignature(
          certDer: client.identity.certDer,
          domain: SigDomain.auth,
          message: m,
          signature: fromHex(_sigHex),
        ),
        isTrue,
      );
    });

    test('buildAuthHeader reproduces the 611-character header', () {
      final h = buildAuthHeader(
        identity: client,
        method: 'POST',
        pathAndQuery: '/api/v1/sessions',
        body: body,
        serverFingerprint: _serverFp,
        now: at,
        nonce: nonce,
      );
      expect(h, _header);
      expect(h.length, 611);
    });

    test(
      'the header text and its decoded parts satisfy the auth-proof schema',
      () {
        final headerSchema = JsonSchema.create(
          ((_docs['auth-proof']![r'$defs']! as Map)['header']! as Map)
              .cast<String, Object?>(),
          schemaVersion: SchemaVersion.draft2020_12,
        );
        expect(headerSchema.validate(_header).isValid, isTrue);
        final parts = _header.split('.');
        expect(parts.length, 5);
        expectValid('auth-proof', {
          'v': parts[0],
          'cert': parts[1],
          'ts': int.parse(parts[2]),
          'nonce': parts[3],
          'sig': parts[4],
        }, 'decoded vector header');
        expect(parts[2], '$_tsMs');
        expect(parts[3], _nonceB64);
        expect(hexOf(b64urlDecode(parts[4])), _sigHex);
        expect(
          hexOf(b64urlDecode(parts[1])),
          _certHex.replaceAll(RegExp(r'\s'), ''),
        );
      },
    );

    AuthResult verify({
      String? header,
      String method = 'POST',
      String target = '/api/v1/sessions',
      List<int>? bodyBytes,
      String ownFp = _serverFp,
      DateTime? now,
      NonceCache? cache,
    }) => verifyAuthHeader(
      header: header ?? _header,
      method: method,
      pathAndQuery: target,
      body: bodyBytes ?? body,
      ownFingerprint: ownFp,
      now: now ?? at,
      nonces: cache ?? NonceCache(),
    );

    test('verification: accepted, peer fingerprint and deviceId', () {
      final r = verify();
      expect(r, isA<AuthOk>());
      final peer = (r as AuthOk).peer;
      expect(peer.fingerprint, _clientFp);
      expect(peer.deviceId, 'ls-vector-client');
    });

    test(
      'verification window is +-120 s around ts (inclusive), stale beyond',
      () {
        expect(
          verify(now: at.add(const Duration(seconds: 120))),
          isA<AuthOk>(),
        );
        expect(
          verify(now: at.subtract(const Duration(seconds: 120))),
          isA<AuthOk>(),
        );
        for (final d in const [121, -121]) {
          final r = verify(now: at.add(Duration(seconds: d)));
          expect(r, isA<AuthFailed>(), reason: '$d s');
          expect((r as AuthFailed).reason, AuthFailure.stale, reason: '$d s');
        }
      },
    );

    test(
      'changing method, target, a body byte or serverFp is badSignature',
      () {
        final flipped = Uint8List.fromList(body)..[2] ^= 1;
        final other =
            'AE91A910C4E3D642640BD9CCFCBD18A6BB2ACF0091BEFFF1D7BD56C437F99EFF';
        for (final r in <AuthResult>[
          verify(method: 'PUT'),
          verify(target: '/api/v1/register'),
          verify(bodyBytes: flipped),
          verify(ownFp: other),
        ]) {
          expect(r, isA<AuthFailed>());
          expect((r as AuthFailed).reason, AuthFailure.badSignature);
        }
      },
    );

    test('a second verification with the same cache is replayed', () {
      final cache = NonceCache();
      expect(verify(cache: cache), isA<AuthOk>());
      final r = verify(cache: cache);
      expect(r, isA<AuthFailed>());
      expect((r as AuthFailed).reason, AuthFailure.replayed);
    });

    test('lower-case method input still signs the upper-case text', () {
      final h = buildAuthHeader(
        identity: client,
        method: 'post',
        pathAndQuery: '/api/v1/sessions',
        body: body,
        serverFingerprint: _serverFp.toLowerCase(),
        now: at,
        nonce: nonce,
      );
      expect(h, _header);
    });
  });

  group('section 4: SAS commit and code', () {
    final ns = seq(0x00, 16);
    final nr = seq(0x10, 16);

    test('nonce encodings', () {
      expect(b64urlEncode(ns), v('Ns', 'AAECAwQFBgcICQoLDA0ODw'));
      expect(b64urlEncode(nr), v('Nr', 'EBESExQVFhcYGRobHB0eHw'));
    });

    test('commit, honest receiver fingerprint', () {
      final commit = sasCommit(
        ns: ns,
        senderFingerprint: _fpS,
        receiverFingerprintSeenBySender: _fpR,
      );
      expect(commit, v('c1', 'xVsm4yPtHTjhd4VytGITnQbYj6JcNg9e9N07JsZVscs'));
      expect(commit.length, 43);
    });

    test('commit, sender saw a MITM certificate', () {
      expect(
        sasCommit(
          ns: ns,
          senderFingerprint: _fpS,
          receiverFingerprintSeenBySender: _fpM,
        ),
        v('c2', 'l7DGyZO5eoGq8RPyF3MDvTfy1LN_4YESPyFCht7WJu4'),
      );
    });

    test('the receiver accepts the honest commit and rejects the MITM one', () {
      bool recompute(String commit) => sasCommitMatches(
        commit: commit,
        ns: ns,
        senderFingerprint: _fpS,
        receiverFingerprintSeenBySender: _fpR,
      );
      expect(recompute('xVsm4yPtHTjhd4VytGITnQbYj6JcNg9e9N07JsZVscs'), isTrue);
      expect(recompute('l7DGyZO5eoGq8RPyF3MDvTfy1LN_4YESPyFCht7WJu4'), isFalse);
    });

    final codes =
        <(String, List<int>, List<int>, String, String, String, String)>[
          ('00..0f / 10..1f fpS,fpR', ns, nr, _fpS, _fpR, '060044', '060 044'),
          ('00..0f / 10..1f fpR,fpS', ns, nr, _fpR, _fpS, '060044', '060 044'),
          ('00..0f / 10..1f fpS,fpM', ns, nr, _fpS, _fpM, '078646', '078 646'),
          (
            'Nr a0 x15,60',
            ns,
            [...List.filled(15, 0xa0), 0x60],
            _fpS,
            _fpR,
            '002408',
            '002 408',
          ),
          (
            'Nr b0 x15,09',
            ns,
            [...List.filled(15, 0xb0), 0x09],
            _fpS,
            _fpR,
            '090751',
            '090 751',
          ),
        ];
    for (final t in codes) {
      test('code ${t.$1} = ${t.$6}', () {
        final code = sasCode(
          ns: t.$2,
          nr: t.$3,
          fingerprintA: t.$4,
          fingerprintB: t.$5,
        );
        expect(code, v('code ${t.$1}', t.$6));
        expect(sasCodeDisplay(code), t.$7);
        v('shown ${t.$1}', t.$7);
      });
    }
  });

  group('section 5: pairing', () {
    // A = inviter (fpA = fpR), B = scanner (fpB = fpS).
    final secret = seq(0x40, 32);
    final nA = seq(0x60, 16);
    final nB = seq(0x70, 16);

    test('inputs encode as documented', () {
      expect(
        hexOf(secret),
        v(
          'S',
          '404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f',
        ),
      );
      expect(
        b64urlEncode(secret),
        v('S b64', 'QEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaW1xdXl8'),
      );
      expect(secret.length, 32);
    });

    test('PairRequest.mac', () {
      final mac = pairRequestMac(
        secret: secret,
        scannerFingerprint: _fpS,
        inviterFingerprint: _fpR,
        scannerNonce: nB,
      );
      expect(
        hexOf(mac),
        v(
          'req hex',
          'a4af9b3626dec060bc129302b38429c5e2a95278529ea944b9a710503fe18b67',
        ),
      );
      expect(
        b64urlEncode(mac),
        v('req b64', 'pK-bNibewGC8EpMCs4QpxeKpUnhSnqlEuacQUD_hi2c'),
      );
    });

    test('PairResponse.mac', () {
      final mac = pairAckMac(
        secret: secret,
        inviterFingerprint: _fpR,
        scannerFingerprint: _fpS,
        inviterNonce: nA,
        scannerNonce: nB,
      );
      expect(
        hexOf(mac),
        v(
          'ack hex',
          'da859a48862641fdf686a481a241f055d1bfa7cf419db45ad1a111a16b6134af',
        ),
      );
      expect(
        b64urlEncode(mac),
        v('ack b64', '2oWaSIYmQf32hqSBokHwVdG_p89BnbRa0aERoWthNK8'),
      );
    });

    test('K_pair, either fingerprint order', () {
      for (final order in [(_fpR, _fpS), (_fpS, _fpR)]) {
        final k = derivePairKey(
          secret: secret,
          inviterNonce: nA,
          scannerNonce: nB,
          fingerprintA: order.$1,
          fingerprintB: order.$2,
        );
        expect(
          hexOf(k),
          v(
            'kpair hex',
            '03e8c2507e0048b521fad8c05766fb7a5d218c723f91f161d1c4ec58d52af0ff',
          ),
        );
        expect(
          b64urlEncode(k),
          v('kpair b64', 'A-jCUH4ASLUh-tjAV2b7el0hjHI_kfFh0cTsWNUq8P8'),
        );
      }
    });

    test(
      'K_pair equals the documented raw HKDF construction (no NUL in info)',
      () {
        final lo = _fpR.compareTo(_fpS) <= 0 ? _fpR : _fpS;
        final hi = _fpR.compareTo(_fpS) <= 0 ? _fpS : _fpR;
        final info = [
          ...ascii.encode('LSP-R1 pair'),
          ...ascii.encode(lo),
          ...ascii.encode(hi),
        ];
        expect(info.length, 11 + 128);
        expect(info.contains(0), isFalse);
        final k = hkdfSha256(
          ikm: secret,
          salt: [...nA, ...nB],
          info: info,
          length: 32,
        );
        expect(
          hexOf(k),
          '03e8c2507e0048b521fad8c05766fb7a5d218c723f91f161d1c4ec58d52af0ff',
        );
      },
    );

    test('the MACs fit the PairRequest / PairResponse schemas', () {
      final sender = {
        'proto': 'libreshare',
        'v': '1.1',
        'deviceId': 'ls-vector-scanner',
        'alias': 'Scanner',
        'platform': 'linux',
        'deviceType': 'desktop',
        'fingerprint': _fpS,
        'port': 53318,
        'addrs': [
          {'ip': '192.168.1.23', 'if': 'wifi'},
        ],
        'caps': ['resume', 'sas', 'pair'],
      };
      expectValid('pair-request', {
        'sender': sender,
        'nonce': b64urlEncode(nB),
        'mac': 'pK-bNibewGC8EpMCs4QpxeKpUnhSnqlEuacQUD_hi2c',
      }, 'vector PairRequest');
      expectInvalid('pair-request', {
        'sender': sender,
        'nonce': b64urlEncode(nB),
        'mac': 'pK-bNibewGC8EpMCs4QpxeKpUnhSnqlEuacQUD_hi2',
      }, 'short mac');
      expectValid('pair-response', {
        'accepted': true,
        'responder': {...sender, 'fingerprint': _fpR},
        'nonce': b64urlEncode(nA),
        'mac': '2oWaSIYmQf32hqSBokHwVdG_p89BnbRa0aERoWthNK8',
      }, 'vector PairResponse');
    });
  });

  group('section 6: goodbye datagram', () {
    final at0 = DateTime.fromMillisecondsSinceEpoch(_byeTs, isUtc: true);

    test('signed text and signature', () {
      final id = client.identity;
      final text = '${id.deviceId}${id.fingerprint}$_byeTs';
      expect(text, _byeText);
      final sig = client.sign(SigDomain.bye, utf8.encode(text));
      expect(hexOf(sig), _byeSigHex);
      expect(b64urlEncode(sig), _byeSigB64);
      expect(_byeSigB64.length, 86);
    });

    test('encodeBye produces the vector datagram', () {
      final bytes = encodeBye(client, now: at0);
      final j = (jsonDecode(utf8.decode(bytes)) as Map).cast<String, Object?>();
      expect(j['proto'], 'libreshare');
      expect(j['v'], '1.1');
      expect(j['t'], 'bye');
      expect(j['deviceId'], 'ls-vector-client');
      expect(j['fingerprint'], _clientFp);
      expect(j['ts'], _byeTs);
      expect(j['sig'], _byeSigB64);
      expect(bytes.length, lessThan(300));
      expectValid('discovery-announce', j, 'vector bye');
    });

    test(
      'decodeBye / byeSignedText round trip and verify under LSP1-BYE only',
      () {
        final m = decodeBye(encodeBye(client, now: at0))!;
        expect(m.ts, _byeTs);
        expect(utf8.decode(byeSignedText(m)), _byeText);
        expect(hexOf(m.signature), _byeSigHex);
        bool verifies(String domain) => verifySignature(
          certDer: client.identity.certDer,
          domain: domain,
          message: byeSignedText(m),
          signature: m.signature,
        );
        expect(verifies(SigDomain.bye), isTrue);
        expect(verifies(SigDomain.auth), isFalse);
      },
    );
  });

  group('schemas: every example validates (drift guard)', () {
    test(
      'all schema files, including lsp11/, carry examples that validate',
      () {
        expect(
          _docs.keys,
          containsAll(<String>[
            'auth-proof',
            'pair-request',
            'pair-response',
            'sas-reveal',
            'session-request',
            'session-status',
            'discovery-announce',
            'error-envelope',
            'device-info',
          ]),
        );
        var count = 0;
        for (final e in _docs.entries) {
          final ex = e.value['examples'];
          expect(ex, isA<List<Object?>>(), reason: '${e.key} has examples');
          for (final item in (ex! as List)) {
            expectValid(e.key, item, '${e.key} example');
            count++;
          }
        }
        expect(count, greaterThanOrEqualTo(_docs.length));
      },
    );

    test('error-envelope code enum equals LsErrorCode', () {
      final enumValues = <String>{};
      void walk(Object? n) {
        if (n is Map) {
          if (n.containsKey('enum') && n['enum'] is List) {
            final l = (n['enum'] as List).whereType<String>().toList();
            if (l.contains('BAD_REQUEST')) enumValues.addAll(l);
          }
          n.values.forEach(walk);
        } else if (n is List) {
          n.forEach(walk);
        }
      }

      walk(_docs['error-envelope']);
      expect(enumValues, LsErrorCode.values.map((e) => e.wire).toSet());
    });
  });
}
