// Protocol conformance for LSP/1.1, the secure profile of Increment 3
// (docs/plans/inc3.md section 3; LSP-1 sections 0.3, 4.2 rules 9-11, 4.3.2,
// 4.3.4, 4.3.6, 4.7 and 5.1-5.4).
//
//  * the four new schemas (auth-proof, sas-reveal, pair-request, pair-response)
//    load, their `examples` validate and every length / member / type rule
//    rejects broken input;
//  * the edited schemas (session-request.sasCommit, session-status.sas,
//    discovery-announce `bye`, error-envelope, device-info) still accept their
//    LSP/1.0 shapes and the new ones;
//  * toJson() of SasChallenge, SessionRequest.sasCommit, SessionStatus.sas,
//    PairRequest and PairResponse validates, optional members are emitted only
//    when non-null, fromJson round-trips and ignores unknown members;
//  * LSP-1.md documents what the plan lists: route table, error codes, check
//    order, constants, signature domains, bye datagram, pair URI, caps tokens,
//    compatibility table, and every [I3] section is present;
//  * the plaintext profile stays the LSP/1.0 wire (legacy tolerance).
//
// Known-answer vectors (SAS commit and code, X-LS-Auth, HKDF) live in
// docs/protocol/test-vectors-inc3.md, produced by the crypto package; the
// assertions that consume that file are added once it exists.
//
// New file on purpose: the Inc 1/2 conformance tests are not edited. The new
// schemas sit in docs/protocol/schemas/lsp11/ because schema_conformance_test
// pins the exact set of top-level schema files; this test loads the schema
// tree recursively, so moving the files up one level needs no change here.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:json_schema/json_schema.dart';
import 'package:libreshare_core/libreshare_core.dart';
import 'package:libreshare_core/src/security/crypto_primitives.dart'
    show b64urlDecode, fingerprintHex, sha256Hex;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// ------------------------------------------------------------------ loading

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

final String schemasDir =
    _findUp(p.join('docs', 'protocol', 'schemas')) ??
    (throw StateError('docs/protocol/schemas not found'));
final String lspMarkdown =
    _findUp(p.join('docs', 'protocol', 'LSP-1.md')) ??
    (throw StateError('docs/protocol/LSP-1.md not found'));
final String fixturesDir =
    _findUp(p.join('test', 'conformance', 'fixtures', 'lsp11')) ??
    _findUp(
      p.join(
        'packages',
        'libreshare_core',
        'test',
        'conformance',
        'fixtures',
        'lsp11',
      ),
    ) ??
    (throw StateError('fixtures/lsp11 not found'));

Map<String, Object?> _readJson(String path) =>
    (jsonDecode(File(path).readAsStringSync()) as Map).cast<String, Object?>();

final Map<String, Map<String, Object?>> _docs = {};
final Map<String, Map<String, Object?>> _byId = {};
final Map<String, JsonSchema> _schemas = {};

void _loadSchemas() {
  final files =
      Directory(schemasDir)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.schema.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in files) {
    final doc = _readJson(f.path);
    final name = p.basename(f.path).replaceFirst('.schema.json', '');
    _docs[name] = doc;
    _byId[doc[r'$id']! as String] = doc;
  }
  final provider = RefProvider.sync(
    (String ref) => _byId[ref] ?? _byId[ref.split('#').first],
  );
  for (final e in _docs.entries) {
    _schemas[e.key] = JsonSchema.create(
      e.value,
      schemaVersion: SchemaVersion.draft2020_12,
      refProvider: provider,
    );
  }
}

void expectValid(String schema, Object? instance, [String? what]) {
  final s = _schemas[schema] ?? (throw ArgumentError('no schema $schema'));
  final r = s.validate(instance, validateFormats: true);
  expect(
    r.isValid,
    isTrue,
    reason:
        '${what ?? 'instance'} vs $schema: ${r.errors.join('; ')}\n'
        '${jsonEncode(instance)}',
  );
}

void expectInvalid(String schema, Object? instance, [String? what]) {
  final s = _schemas[schema] ?? (throw ArgumentError('no schema $schema'));
  final r = s.validate(instance, validateFormats: true);
  expect(
    r.isValid,
    isFalse,
    reason: '${what ?? 'instance'} should violate $schema',
  );
}

Object? plain(Object? j) => jsonDecode(jsonEncode(j));

Map<String, Object?> deepCopy(Map<String, Object?> m) =>
    (plain(m) as Map).cast<String, Object?>();

Map<String, Object?> _m(Object? o) => (o! as Map).cast<String, Object?>();

Object? withUnknown(Object? j, {String? key}) {
  const opaque = {'acceptedFiles'};
  if (j is Map) {
    final out = <String, Object?>{
      for (final e in j.entries)
        e.key as String: withUnknown(e.value, key: e.key as String),
    };
    if (!opaque.contains(key)) {
      out['x-unknown-member'] = {
        'nested': [1, 2, 3],
        'deep': {'a': null},
      };
      out['futureFlag'] = true;
    }
    return out;
  }
  if (j is List) return [for (final e in j) withUnknown(e, key: key)];
  return j;
}

/// Unpadded base64url of [n] deterministic bytes (the text length is what the
/// schemas pin: 16 B = 22, 32 B = 43, 64 B = 86 characters).
String b64(int n, [int seed = 1]) => base64Url
    .encode(
      Uint8List.fromList([for (var i = 0; i < n; i++) (i * 31 + seed) & 255]),
    )
    .replaceAll('=', '');

/// A base64url string of exactly [chars] characters (shape test only).
String chars(int chars, [String c = 'A']) => c * chars;

// ------------------------------------------------------------------- models

const fpS = 'FC074C4445C65D5C5208058734A816CFC5E77A51D5D9B596AD324828CEFA422E';
const fpR = '1F819647D8A757EEBF01D603D43E7608511EF99B48C0E58D5EC33F78B13C0314';

const sender = DeviceInfo(
  deviceId: '5b0f7d8e-3c1a-4f2b-9d6e-1a2b3c4d5e6f',
  alias: 'Ravi-ThinkPad',
  platform: 'windows',
  fingerprint: fpS,
  addrs: [DeviceAddress('192.168.1.23', iface: 'wifi')],
  caps: ['resume', 'sas', 'pair'],
  version: kProtocolVersionSecure,
);
const receiver = DeviceInfo(
  deviceId: '0f6c2a9e-7b1d-4c3e-8a5f-9e8d7c6b5a43',
  alias: 'Ravi-Pixel',
  platform: 'android',
  deviceType: 'phone',
  fingerprint: fpR,
  addrs: [DeviceAddress('192.168.1.40', iface: 'wifi')],
  caps: ['resume', 'sas', 'pair'],
  version: kProtocolVersionSecure,
);

final String commit = b64(32, 3);
final String nonceS = b64(16, 5);
final String nonceR = b64(16, 7);
final String mac = b64(32, 11);
final String macAck = b64(32, 13);

const emptyFile = FileItem(
  fileId: 'f1',
  fileName: 'empty.txt',
  size: 0,
  chunkCount: 0,
  mime: 'text/plain',
  sha256: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
);

SessionRequest requestWith({String? sasCommit, String? pin}) => SessionRequest(
  sender: sender,
  files: const [emptyFile],
  totalSize: 0,
  sasCommit: sasCommit,
  pin: pin,
);

SessionStatus pendingWith({SasChallenge? sas}) => SessionStatus(
  sessionId: 'c1d2e3f4-0a1b-4c2d-8e3f-a4b5c6d7e8f9',
  status: TransferStatus.pending,
  sas: sas,
);

PairRequest pairRequest() =>
    PairRequest(sender: sender, nonce: nonceS, mac: mac);
PairResponse pairAccepted() => PairResponse(
  accepted: true,
  responder: receiver,
  nonce: nonceR,
  mac: macAck,
);
const pairDeclined = PairResponse(accepted: false, responder: receiver);

// --------------------------------------------------------------- the markdown

final String md = File(lspMarkdown).readAsStringSync();

/// Text from the first occurrence of [from] up to (excluding) [to].
String section(String from, String to) {
  final a = md.indexOf(from);
  expect(a, isNonNegative, reason: 'LSP-1.md has no "$from"');
  final b = md.indexOf(to, a + from.length);
  expect(b, isNonNegative, reason: 'LSP-1.md has no "$to" after "$from"');
  return md.substring(a, b);
}

/// Table rows of [text] as lists of trimmed cells.
List<List<String>> rows(String text) => [
  for (final line in text.split('\n'))
    if (line.startsWith('|'))
      line
          .split('|')
          .sublist(1, line.split('|').length - 1)
          .map((c) => c.trim())
          .toList(),
];

// ------------------------------------------------------------------ fixtures

class Golden {
  const Golden(this.file, this.schema, [this.roundTrip]);
  final String file;
  final String schema;
  final Object? Function(Map<String, Object?> json)? roundTrip;
}

final List<Golden> goldens = [
  Golden(
    'device_info_secure.json',
    'device-info',
    (j) => DeviceInfo.fromJson(j).toJson(),
  ),
  Golden(
    'session_request_sas.json',
    'session-request',
    (j) => SessionRequest.fromJson(j).toJson(),
  ),
  Golden(
    'session_status_sas.json',
    'session-status',
    (j) => SessionStatus.fromJson(j).toJson(),
  ),
  Golden(
    'sas_reveal.json',
    'sas-reveal',
    (j) => SasChallenge.fromJson(j).toJson(),
  ),
  Golden(
    'pair_request.json',
    'pair-request',
    (j) => PairRequest.fromJson(j).toJson(),
  ),
  Golden(
    'pair_response_accepted.json',
    'pair-response',
    (j) => PairResponse.fromJson(j).toJson(),
  ),
  Golden(
    'pair_response_declined.json',
    'pair-response',
    (j) => PairResponse.fromJson(j).toJson(),
  ),
  const Golden('auth_proof.json', 'auth-proof'),
  const Golden('announce_secure.json', 'discovery-announce'),
  const Golden('bye_datagram.json', 'discovery-announce'),
  Golden(
    'error_envelope_auth_invalid.json',
    'error-envelope',
    (j) => LsException.fromEnvelope(j).toEnvelope(),
  ),
  Golden(
    'error_envelope_key_changed.json',
    'error-envelope',
    (j) => LsException.fromEnvelope(j).toEnvelope(),
  ),
];

Map<String, Object?> fixture(String name) =>
    _readJson(p.join(fixturesDir, name));

// ----------------------------------------------------------------- live rig

Future<(int, Map<String, Object?>)> _call(
  HttpClient http,
  int port,
  String method,
  String path, {
  Object? body,
}) async {
  final req = await http.openUrl(
    method,
    Uri.parse('http://127.0.0.1:$port$kApiPrefix$path'),
  );
  if (body != null) {
    req.headers.contentType = ContentType.json;
    req.add(utf8.encode(jsonEncode(body)));
  }
  final res = await req.close();
  final text = await utf8.decodeStream(res);
  return (
    res.statusCode,
    text.isEmpty
        ? <String, Object?>{}
        : (jsonDecode(text) as Map).cast<String, Object?>(),
  );
}

// --------------------------------------------------------------------- main

void main() {
  _loadSchemas();

  const lsp10 = {
    'device-info',
    'discovery-announce',
    'error-envelope',
    'file-item',
    'file-state',
    'file-verification',
    'session-request',
    'session-status',
    'tunnel-offer',
  };
  const lsp11 = {'auth-proof', 'sas-reveal', 'pair-request', 'pair-response'};

  group('schemas', () {
    test('the four LSP/1.1 schemas sit next to the nine LSP/1.0 ones', () {
      expect(_docs.keys.toSet(), {...lsp10, ...lsp11});
    });

    test('draft 2020-12, unique \$id ending in the file name, examples', () {
      expect(_byId.length, _docs.length, reason: 'duplicate \$id');
      for (final e in _docs.entries) {
        expect(
          e.value[r'$schema'],
          'https://json-schema.org/draft/2020-12/schema',
          reason: e.key,
        );
        expect(
          (e.value[r'$id']! as String).endsWith('/${e.key}.schema.json'),
          isTrue,
          reason: '\$id of ${e.key}',
        );
        expect(e.value['examples'], isA<List<Object?>>(), reason: e.key);
        expect((e.value['examples']! as List), isNotEmpty, reason: e.key);
        expect(e.value['description'], isA<String>(), reason: e.key);
      }
    });

    for (final name in [...lsp11, ...lsp10]) {
      final examples = (_docs[name]!['examples']! as List).cast<Object?>();
      for (var i = 0; i < examples.length; i++) {
        test('$name: example #$i validates', () {
          expectValid(name, examples[i], 'example #$i');
        });
      }
    }

    test('the examples added to LSP/1.0 schemas use the new members', () {
      Iterable<Map<String, Object?>> ex(String s) =>
          (_docs[s]!['examples']! as List).map(_m);
      expect(
        ex('session-request').any((e) => e.containsKey('sasCommit')),
        true,
      );
      expect(ex('session-status').any((e) => e.containsKey('sas')), true);
      expect(ex('discovery-announce').any((e) => e['t'] == 'bye'), true);
      final codes = ex('error-envelope').map((e) => _m(e['error'])['code']);
      expect(codes, containsAll(['AUTH_INVALID', 'KEY_CHANGED']));
    });

    test('encoded lengths: 16 B = 22, 32 B = 43, 64 B = 86, 2 KiB = 2731', () {
      expect(b64(16), hasLength(22));
      expect(b64(32), hasLength(43));
      expect(b64(64), hasLength(86));
      expect(b64(2048), hasLength(2731));
    });
  });

  group('negative controls: auth-proof (decoded X-LS-Auth)', () {
    Map<String, Object?> proof() => deepCopy(fixture('auth_proof.json'));

    test('the fixture is valid and carries the five members', () {
      expectValid('auth-proof', proof());
      expect(proof().keys, containsAll(['v', 'cert', 'ts', 'nonce', 'sig']));
    });

    test('every member is required', () {
      for (final k in ['v', 'cert', 'ts', 'nonce', 'sig']) {
        expectInvalid('auth-proof', proof()..remove(k), 'without $k');
      }
    });

    test('nonce is 16 bytes = 22 characters, sig 64 bytes = 86', () {
      for (final n in [0, 21, 23, 24, 43]) {
        expectInvalid('auth-proof', proof()..['nonce'] = chars(n), 'nonce $n');
      }
      for (final n in [0, 85, 87, 88, 128]) {
        expectInvalid('auth-proof', proof()..['sig'] = chars(n), 'sig $n');
      }
      expectValid('auth-proof', proof()..['nonce'] = b64(16));
      expectValid('auth-proof', proof()..['sig'] = b64(64));
    });

    test('cert: 1..2731 base64url characters (2 KiB cap)', () {
      expectValid('auth-proof', proof()..['cert'] = b64(2048));
      expectInvalid('auth-proof', proof()..['cert'] = b64(2049));
      expectInvalid('auth-proof', proof()..['cert'] = '');
      for (final bad in ['.', '+', '/', '=', ' ']) {
        expectInvalid('auth-proof', proof()..['cert'] = 'AAAA${bad}AAAA', bad);
        expectInvalid('auth-proof', proof()..['sig'] = chars(85) + bad, bad);
        expectInvalid('auth-proof', proof()..['nonce'] = chars(21) + bad, bad);
      }
    });

    test('version is exactly "v1"', () {
      for (final v in <Object?>['v2', 'V1', 'v1.0', '1', 1, null, '']) {
        expectInvalid('auth-proof', proof()..['v'] = v, 'v=$v');
      }
    });

    test('ts is a non-negative integer of epoch milliseconds', () {
      for (final ts in <Object?>[
        '1762257600000',
        1.5,
        -1,
        null,
        true,
        [1],
      ]) {
        expectInvalid('auth-proof', proof()..['ts'] = ts, 'ts=$ts');
      }
      expectValid('auth-proof', proof()..['ts'] = 0);
    });

    test('members of the wrong JSON type', () {
      for (final k in ['cert', 'nonce', 'sig']) {
        expectInvalid('auth-proof', proof()..[k] = 7, '$k as int');
        expectInvalid('auth-proof', proof()..[k] = ['x'], '$k as list');
        expectInvalid('auth-proof', proof()..[k] = null, '$k as null');
      }
    });

    group('header grammar  v1.<cert>.<ts>.<nonce>.<sig>', () {
      final headerDef = _m(_m(_docs['auth-proof']![r'$defs'])['header']);
      final header = JsonSchema.create({
        r'$schema': _docs['auth-proof']![r'$schema'],
        ...headerDef,
      }, schemaVersion: SchemaVersion.draft2020_12);
      String build(Map<String, Object?> j) =>
          'v1.${j['cert']}.${j['ts']}.${j['nonce']}.${j['sig']}';
      bool ok(String h) => header.validate(h).isValid;

      test('the fixture assembles to a valid header and splits back', () {
        final j = proof();
        final h = build(j);
        expect(ok(h), isTrue, reason: h);
        final parts = h.split('.');
        expect(parts, hasLength(5));
        expect(parts[0], j['v']);
        expect(parts[1], j['cert']);
        expect(int.parse(parts[2]), j['ts']);
        expect(parts[3], j['nonce']);
        expect(parts[4], j['sig']);
        expect(h.length, lessThanOrEqualTo(4096));
      });

      test('malformed headers are refused', () {
        final j = proof();
        final good = build(j);
        expect(ok(good), isTrue);
        expect(ok(good.replaceFirst('v1.', 'v2.')), isFalse, reason: 'version');
        expect(ok(good.replaceFirst('v1.', '')), isFalse, reason: 'no version');
        expect(ok('$good.AAAA'), isFalse, reason: 'six segments');
        expect(
          ok(good.replaceFirst('.${j['ts']}', '')),
          isFalse,
          reason: 'no ts',
        );
        expect(ok(build(j..['sig'] = chars(85))), isFalse, reason: 'short sig');
        expect(ok(build(j..['sig'] = chars(87))), isFalse, reason: 'long sig');
        j['sig'] = b64(64);
        expect(ok(build(j..['nonce'] = chars(23))), isFalse, reason: 'nonce');
        j['nonce'] = b64(16);
        expect(ok(build(j..['ts'] = 'x1')), isFalse, reason: 'ts');
        expect(ok(build(j..['ts'] = '017')), isFalse, reason: 'leading zero');
        expect(ok(build(j..['ts'] = '')), isFalse, reason: 'empty ts');
        j['ts'] = 1762257600000;
        expect(ok(build(j..['cert'] = '')), isFalse, reason: 'empty cert');
        expect(
          ok(build(j..['cert'] = chars(2732))),
          isFalse,
          reason: 'cert cap',
        );
        expect(ok(' $good'), isFalse, reason: 'leading space');
        expect(ok('$good\n'), isFalse, reason: 'trailing newline');
      });
    });
  });

  group('negative controls: sas-reveal', () {
    Map<String, Object?> reveal() => deepCopy(fixture('sas_reveal.json'));

    test('nonce is required and exactly 22 base64url characters', () {
      expectValid('sas-reveal', reveal());
      expectInvalid('sas-reveal', <String, Object?>{}, 'empty object');
      expectInvalid('sas-reveal', reveal()..remove('nonce'));
      for (final n in [0, 21, 23, 24, 43, 44]) {
        expectInvalid('sas-reveal', {'nonce': chars(n)}, 'nonce $n chars');
      }
      expectInvalid('sas-reveal', {'nonce': '${chars(22)}=='}, 'padded');
    });

    test('type and alphabet', () {
      for (final bad in <Object?>[
        7,
        null,
        true,
        ['x'],
        {'a': 1},
      ]) {
        expectInvalid('sas-reveal', {'nonce': bad}, 'nonce=$bad');
      }
      for (final c in ['+', '/', '.', ' ', '=']) {
        expectInvalid('sas-reveal', {'nonce': chars(21) + c}, 'char "$c"');
      }
      expectInvalid('sas-reveal', 'AAAAAAAAAAAAAAAAAAAAAA', 'bare string');
      expectInvalid('sas-reveal', [reveal()], 'array');
    });

    test('unknown members are ignored', () {
      expectValid('sas-reveal', {...reveal(), 'future': 1});
    });
  });

  group('negative controls: pair-request / pair-response', () {
    Map<String, Object?> req() => deepCopy(fixture('pair_request.json'));
    Map<String, Object?> ok() =>
        deepCopy(fixture('pair_response_accepted.json'));
    Map<String, Object?> no() =>
        deepCopy(fixture('pair_response_declined.json'));

    test('pair-request: members, lengths, types', () {
      expectValid('pair-request', req());
      for (final k in ['sender', 'nonce', 'mac']) {
        expectInvalid('pair-request', req()..remove(k), 'without $k');
      }
      for (final n in [0, 21, 23, 43]) {
        expectInvalid('pair-request', req()..['nonce'] = chars(n), 'nonce $n');
      }
      for (final n in [0, 42, 44, 86]) {
        expectInvalid('pair-request', req()..['mac'] = chars(n), 'mac $n');
      }
      expectInvalid('pair-request', req()..['mac'] = 7);
      expectInvalid('pair-request', req()..['nonce'] = null);
      expectInvalid('pair-request', req()..['sender'] = 'me');
      expectInvalid('pair-request', req()..['sender'] = <String, Object?>{});
    });

    test('pair-request: the scanner must carry a real fingerprint', () {
      Map<String, Object?> withFp(Object? fp) {
        final r = req();
        _m(r['sender'])['fingerprint'] = fp;
        return r;
      }

      expectValid('pair-request', withFp(fpS));
      for (final fp in <Object?>['', fpS.toLowerCase(), 'ABCD', null, 5]) {
        expectInvalid('pair-request', withFp(fp), 'fingerprint=$fp');
      }
      final noFp = req();
      _m(noFp['sender']).remove('fingerprint');
      expectInvalid('pair-request', noFp, 'fingerprint absent');
    });

    test(
      'pair-response: accepted needs nonce and mac, declined has neither',
      () {
        expectValid('pair-response', ok());
        expectValid('pair-response', no());
        expectInvalid(
          'pair-response',
          ok()..remove('nonce'),
          'accepted w/o nonce',
        );
        expectInvalid('pair-response', ok()..remove('mac'), 'accepted w/o mac');
        expectInvalid(
          'pair-response',
          no()..['nonce'] = nonceR,
          'declined with nonce',
        );
        expectInvalid(
          'pair-response',
          no()..['mac'] = macAck,
          'declined with mac',
        );
        expectInvalid('pair-response', ok()..['nonce'] = chars(21));
        expectInvalid('pair-response', ok()..['mac'] = chars(44));
      },
    );

    test('pair-response: members and types', () {
      for (final k in ['accepted', 'responder']) {
        expectInvalid('pair-response', ok()..remove(k), 'without $k');
        expectInvalid('pair-response', no()..remove(k), 'without $k');
      }
      for (final v in <Object?>['yes', 1, null, 'true']) {
        expectInvalid('pair-response', no()..['accepted'] = v, 'accepted=$v');
      }
      final noFp = ok();
      _m(noFp['responder'])['fingerprint'] = '';
      expectInvalid('pair-response', noFp, 'responder without fingerprint');
    });

    test('unknown members are ignored', () {
      expectValid('pair-request', _m(withUnknown(req())));
      expectValid('pair-response', _m(withUnknown(ok())));
      expectValid('pair-response', _m(withUnknown(no())));
    });
  });

  group('negative controls: edited LSP/1.0 schemas', () {
    Map<String, Object?> sessionRequest() =>
        deepCopy(fixture('session_request_sas.json'));
    Map<String, Object?> sessionStatus() =>
        deepCopy(fixture('session_status_sas.json'));
    Map<String, Object?> bye() => deepCopy(fixture('bye_datagram.json'));

    test('session-request.sasCommit is exactly 43 base64url characters', () {
      expectValid('session-request', sessionRequest());
      expectValid(
        'session-request',
        sessionRequest()..remove('sasCommit'),
        'optional',
      );
      for (final n in [0, 1, 22, 42, 44, 64, 86]) {
        expectInvalid(
          'session-request',
          sessionRequest()..['sasCommit'] = chars(n),
          'sasCommit $n chars',
        );
      }
      expectInvalid(
        'session-request',
        sessionRequest()..['sasCommit'] = '${chars(43)}=',
        'padded',
      );
      for (final c in ['+', '/', '.', ' ']) {
        expectInvalid(
          'session-request',
          sessionRequest()..['sasCommit'] = chars(42) + c,
          'char "$c"',
        );
      }
      for (final bad in <Object?>[
        7,
        true,
        ['x'],
        {'a': 1},
        null,
      ]) {
        expectInvalid(
          'session-request',
          sessionRequest()..['sasCommit'] = bad,
          'sasCommit=$bad',
        );
      }
    });

    test('session-status.sas is {nonce: 22 characters}', () {
      expectValid('session-status', sessionStatus());
      expectValid('session-status', sessionStatus()..remove('sas'), 'optional');
      for (final n in [0, 21, 23, 43]) {
        expectInvalid(
          'session-status',
          sessionStatus()..['sas'] = {'nonce': chars(n)},
          'nonce $n',
        );
      }
      for (final bad in <Object?>['x', 7, null, true, <String, Object?>{}]) {
        expectInvalid(
          'session-status',
          sessionStatus()..['sas'] = bad,
          'sas=$bad',
        );
      }
      expectInvalid(
        'session-status',
        sessionStatus()..['sas'] = {'nonce': 5},
        'nonce int',
      );
    });

    test('discovery-announce bye: members, version, lengths, types', () {
      expectValid('discovery-announce', bye());
      for (final k in [
        'proto',
        'v',
        't',
        'deviceId',
        'fingerprint',
        'ts',
        'sig',
      ]) {
        expectInvalid('discovery-announce', bye()..remove(k), 'without $k');
      }
      for (final t in <Object?>['hello', 'BYE', '', null, 1]) {
        expectInvalid('discovery-announce', bye()..['t'] = t, 't=$t');
      }
      for (final v in <Object?>['1.0', '2.0', '1', '', 'x', 1.1, null]) {
        expectInvalid('discovery-announce', bye()..['v'] = v, 'v=$v');
      }
      for (final v in ['1.1', '1.2', '1.10']) {
        expectValid('discovery-announce', bye()..['v'] = v, 'v=$v');
      }
      for (final fp in <Object?>['', fpS.toLowerCase(), 'ABCD', null]) {
        expectInvalid(
          'discovery-announce',
          bye()..['fingerprint'] = fp,
          'fp=$fp',
        );
      }
      for (final n in [0, 85, 87, 128]) {
        expectInvalid(
          'discovery-announce',
          bye()..['sig'] = chars(n),
          'sig $n',
        );
      }
      for (final ts in <Object?>['1762257600000', 1.5, -1, null]) {
        expectInvalid('discovery-announce', bye()..['ts'] = ts, 'ts=$ts');
      }
      expectInvalid('discovery-announce', bye()..['proto'] = 'other');
      expectInvalid('discovery-announce', bye()..['deviceId'] = '');
    });

    test(
      'a bye tolerates unknown members; announce+bye in one is ambiguous',
      () {
        expectValid('discovery-announce', _m(withUnknown(bye())));
        final mixed = <String, Object?>{
          ...deepCopy(fixture('announce_secure.json')),
          't': 'bye',
          'ts': 1762257600000,
          'sig': b64(64),
        };
        expectInvalid('discovery-announce', mixed, 'both shapes at once');
      },
    );

    test('LSP/1.0 announce rules still hold inside the oneOf', () {
      Map<String, Object?> announce() =>
          deepCopy(fixture('announce_secure.json'));
      expectValid('discovery-announce', announce());
      expectInvalid('discovery-announce', announce()..remove('announce'));
      expectInvalid(
        'discovery-announce',
        announce()
          ..['port'] = 0
          ..['announce'] = false,
        'port 0 with announce:false',
      );
      expectValid('discovery-announce', announce()..['port'] = 0, 'probe');
    });

    test('the new error codes are in the envelope schema', () {
      for (final code in ['AUTH_INVALID', 'KEY_CHANGED']) {
        expectValid('error-envelope', {
          'error': {'code': code, 'message': 'm', 'retryable': false},
        });
      }
      expectInvalid('error-envelope', {
        'error': {'code': 'AUTH_REQUIRED', 'message': 'm', 'retryable': false},
      });
      final env = _m(
        _m(_m(_docs['error-envelope']!['properties'])['error'])['properties'],
      );
      expect(
        ((_m(env['code'])['enum']!) as List).toSet(),
        LsErrorCode.values.map((c) => c.wire).toSet(),
      );
    });

    test('device-info accepts a v1.1 secure device and a v1.0 legacy one', () {
      expectValid('device-info', fixture('device_info_secure.json'));
      expectValid('device-info', sender.toJson());
      expectValid(
        'device-info',
        const DeviceInfo(deviceId: 'x', alias: 'y', platform: 'z').toJson(),
      );
      expect(sender.toJson()['v'], kProtocolVersionSecure);
    });
  });

  group('DTO toJson() validates; optional members only when non-null', () {
    test('SessionRequest.sasCommit', () {
      final withCommit = requestWith(sasCommit: commit).toJson();
      expect(withCommit['sasCommit'], commit);
      expectValid('session-request', withCommit, 'with commit');
      final without = requestWith().toJson();
      expect(without.containsKey('sasCommit'), isFalse);
      expectValid('session-request', without, 'without commit');
      expectValid(
        'session-request',
        requestWith(sasCommit: commit, pin: '000123').toJson(),
        'commit and pin',
      );
    });

    test('a sasCommit of the wrong length is rejected by the schema', () {
      for (final bad in [commit.substring(1), '${commit}A', 'short', '']) {
        expectInvalid(
          'session-request',
          requestWith(sasCommit: bad).toJson(),
          'sasCommit "${bad.length} chars"',
        );
      }
      // The DTO itself is a transport: it does not validate. The schema does.
      expect(requestWith(sasCommit: 'short').toJson()['sasCommit'], 'short');
    });

    test('a real SHA-256 commitment is 43 characters', () {
      final digest = sha256.convert(utf8.encode('commitment shape')).bytes;
      final text = base64Url.encode(digest).replaceAll('=', '');
      expect(text, hasLength(43));
      expectValid('session-request', requestWith(sasCommit: text).toJson());
    });

    test('SessionStatus.sas and SasChallenge', () {
      final s = pendingWith(sas: SasChallenge(nonce: nonceR));
      expect(s.toJson()['sas'], {'nonce': nonceR});
      expectValid('session-status', s.toJson(), 'with sas');
      expect(pendingWith().toJson().containsKey('sas'), isFalse);
      expectValid('session-status', pendingWith().toJson(), 'without sas');
      expectValid('sas-reveal', SasChallenge(nonce: nonceS).toJson());
      expect(SasChallenge(nonce: nonceS).toJson().keys, ['nonce']);
    });

    test('PairRequest', () {
      expectValid('pair-request', pairRequest().toJson());
      expect(pairRequest().toJson().keys, ['sender', 'nonce', 'mac']);
    });

    test('PairResponse accepted and declined', () {
      expectValid('pair-response', pairAccepted().toJson(), 'accepted');
      expectValid('pair-response', pairDeclined.toJson(), 'declined');
      final declined = pairDeclined.toJson();
      expect(declined.containsKey('nonce'), isFalse);
      expect(declined.containsKey('mac'), isFalse);
      expect(pairAccepted().toJson()['nonce'], nonceR);
      expect(pairAccepted().toJson()['mac'], macAck);
    });

    test('fromJson(toJson(x)) round-trips', () {
      final r = requestWith(sasCommit: commit, pin: '123456');
      expect(
        plain(
          SessionRequest.fromJson(
            deepCopy(plain(r.toJson())! as Map<String, Object?>),
          ).toJson(),
        ),
        plain(r.toJson()),
      );
      expect(SessionRequest.fromJson(r.toJson()).sasCommit, commit);
      expect(SessionRequest.fromJson(requestWith().toJson()).sasCommit, isNull);

      final s = pendingWith(sas: SasChallenge(nonce: nonceR));
      final s2 = SessionStatus.fromJson(
        deepCopy(plain(s.toJson())! as Map<String, Object?>),
      );
      expect(s2.sas!.nonce, nonceR);
      expect(plain(s2.toJson()), plain(s.toJson()));
      expect(SessionStatus.fromJson(pendingWith().toJson()).sas, isNull);

      final pr = PairRequest.fromJson(
        deepCopy(plain(pairRequest().toJson())! as Map<String, Object?>),
      );
      expect(plain(pr.toJson()), plain(pairRequest().toJson()));
      expect(pr.sender.fingerprint, fpS);

      for (final resp in [pairAccepted(), pairDeclined]) {
        final back = PairResponse.fromJson(
          deepCopy(plain(resp.toJson())! as Map<String, Object?>),
        );
        expect(plain(back.toJson()), plain(resp.toJson()));
        expect(back.accepted, resp.accepted);
        expect(back.nonce, resp.nonce);
        expect(back.mac, resp.mac);
      }
    });

    test('unknown members are ignored at every level', () {
      Map<String, Object?> noisy(Map<String, Object?> j) =>
          _m(withUnknown(deepCopy(j)));
      expect(
        SessionRequest.fromJson(noisy(requestWith(sasCommit: commit).toJson()))
            .sasCommit,
        commit,
      );
      expect(
        SessionStatus.fromJson(
          noisy(pendingWith(sas: SasChallenge(nonce: nonceR)).toJson()),
        ).sas!.nonce,
        nonceR,
      );
      expect(PairRequest.fromJson(noisy(pairRequest().toJson())).mac, mac);
      expect(
        PairResponse.fromJson(noisy(pairAccepted().toJson())).nonce,
        nonceR,
      );
      expect(SasChallenge.fromJson({'nonce': nonceS, 'x': 1}).nonce, nonceS);
    });
  });

  group('golden fixtures (fixtures/lsp11)', () {
    test('every fixture file is covered by the table', () {
      final onDisk = {
        for (final f in Directory(fixturesDir).listSync().whereType<File>())
          p.basename(f.path),
      };
      expect(onDisk, goldens.map((g) => g.file).toSet());
    });

    for (final g in goldens) {
      test('${g.file}: validates against ${g.schema}', () {
        expectValid(g.schema, fixture(g.file), g.file);
      });
      if (g.roundTrip != null) {
        test('${g.file}: round-trips fromJson -> toJson', () {
          final golden = fixture(g.file);
          expect(plain(g.roundTrip!(deepCopy(golden))), golden);
        });
        test('${g.file}: unknown members are ignored', () {
          final golden = fixture(g.file);
          final noisy = _m(withUnknown(golden));
          expect(noisy, isNot(golden));
          expect(plain(g.roundTrip!(deepCopy(noisy))), golden);
        });
      }
    }

    test('the model fixtures equal the in-code models', () {
      expect(
        plain(requestWith(sasCommit: commit).toJson()),
        fixture('session_request_sas.json'),
        reason: 'session_request_sas.json is requestWith(sasCommit:)',
      );
      expect(
        plain(pendingWith(sas: SasChallenge(nonce: nonceR)).toJson()),
        fixture('session_status_sas.json'),
      );
      expect(
        plain(SasChallenge(nonce: nonceS).toJson()),
        fixture('sas_reveal.json'),
      );
      expect(plain(pairRequest().toJson()), fixture('pair_request.json'));
      expect(
        plain(pairAccepted().toJson()),
        fixture('pair_response_accepted.json'),
      );
      expect(
        plain(pairDeclined.toJson()),
        fixture('pair_response_declined.json'),
      );
      expect(plain(sender.toJson()), fixture('device_info_secure.json'));
    });

    test('LsException envelopes for the new codes', () {
      final a = LsException.fromEnvelope(
        fixture('error_envelope_auth_invalid.json'),
      );
      expect(a.code, LsErrorCode.authInvalid);
      expect(a.httpStatus, 401);
      expect(a.retryable, isFalse);
      final k = LsException.fromEnvelope(
        fixture('error_envelope_key_changed.json'),
      );
      expect(k.code, LsErrorCode.keyChanged);
      expect(k.httpStatus, 403);
      expect(k.retryable, isFalse);
    });

    test('auth_proof.json uses the documented sizes', () {
      final j = fixture('auth_proof.json');
      expect(j['v'], 'v1');
      expect((j['nonce']! as String).length, 22);
      expect((j['sig']! as String).length, 86);
      expect((j['cert']! as String).length, lessThanOrEqualTo(2731));
      expect(j['ts'], isA<int>());
    });

    test('a LSP/1.0 decoder accepts a v1.1 announce and drops a bye', () {
      final announce = utf8.encode(jsonEncode(fixture('announce_secure.json')));
      final decoded = decodeAnnounce(announce);
      expect(decoded, isNotNull);
      expect(decoded!.info.version, '1.1');
      expect(decoded.info.fingerprint, hasLength(64));
      final byeBytes = utf8.encode(jsonEncode(fixture('bye_datagram.json')));
      expect(byeBytes.length, lessThanOrEqualTo(kMaxAnnounceBytes));
      expect(
        decodeAnnounce(byeBytes),
        isNull,
        reason: 'LSP/1.0 receivers drop a bye silently (LSP-1 4.2 rule 9)',
      );
      expect(decodeAnnounce(byeBytes, allowProbe: true), isNull);
    });
  });

  group('constants', () {
    test('the LSP/1.1 constants have the documented values', () {
      expect(kProtocolVersion, '1.0', reason: 'plaintext profile');
      expect(kProtocolVersionSecure, '1.1', reason: 'secure profile');
      expect(kMaxSessionJsonBytes, 4 * 1024 * 1024);
      expect(kMaxJsonBytes, 256 * 1024);
      expect(kAuthHeader, 'x-ls-auth');
      expect(kSasRevealTimeout, const Duration(seconds: 30));
      expect(kPairTimeout, const Duration(seconds: 125));
      expect(kAuthWindow, const Duration(seconds: 120));
      expect(kPermissionTimeout, const Duration(seconds: 120));
    });

    test('the signature domains are the documented labels', () {
      expect(SigDomain.auth, 'LSP1-AUTH-v1');
      expect(SigDomain.sasCommit, 'LSP1-SAS-C');
      expect(SigDomain.sasValue, 'LSP1-SAS-V');
      expect(SigDomain.bye, 'LSP1-BYE');
      expect(SigDomain.pairRequest, 'LSP1-PAIR-REQ');
      expect(SigDomain.pairInfo, 'LSP-R1 pair');
    });
  });

  group('LSP-1.md documents LSP/1.1', () {
    test('every [I3] section is present and marked', () {
      const headings = [
        '### 0.3 ',
        '#### 4.3.6 ',
        '### 4.7 ',
        '### 5.1 ',
        '### 5.2 ',
        '### 5.3 ',
        '### 5.4 ',
      ];
      for (final h in headings) {
        final line = md.split('\n').where((l) => l.startsWith(h)).toList();
        expect(line, hasLength(1), reason: 'exactly one "$h" heading');
        expect(line.single, contains('[I3]'), reason: line.single);
      }
      // The inline [I3] items: bye (4.2 rule 9), caps (rule 11), pair URI (rule 6).
      final s42 = section('### 4.2 ', '### 4.3 ');
      for (final marker in [
        RegExp(
          r'^9\. \*\*[^\n]*bye[^\n]*\[I3\]',
          multiLine: true,
          caseSensitive: false,
        ),
        RegExp(r'^10\. \*\*[^\n]*\[I3\]', multiLine: true),
        RegExp(r'^11\. \*\*[^\n]*[Cc]apab[^\n]*\[I3\]', multiLine: true),
      ]) {
        expect(
          marker.hasMatch(s42),
          isTrue,
          reason: '${marker.pattern} in 4.2',
        );
      }
      final s434 = section('#### 4.3.4 ', '#### 4.3.5 ');
      expect(s434, contains('**`POST /sessions/{sid}/sas` [I3].**'));
      expect(s434, contains('**`POST /pair` [I3].**'));
      expect(s434, contains('**Secure-profile order [I3].**'));
    });

    test('sections stay in order and 4.3.5 is still followed by 4.4', () {
      final order = [
        '## 4. Wire protocol',
        '### 4.1 ',
        '### 4.2 ',
        '### 4.3 ',
        '#### 4.3.1 ',
        '#### 4.3.2 ',
        '#### 4.3.3 ',
        '#### 4.3.4 ',
        '#### 4.3.5 ',
        '#### 4.3.6 ',
        '### 4.4 ',
        '### 4.5 ',
        '### 4.6 ',
        '### 4.7 ',
        '## 5. Security summary',
        '### 5.1 ',
        '### 5.2 ',
        '### 5.3 ',
        '### 5.4 ',
        '## 6. Session state machine',
        '## 7. Conformance',
        '## 8. Increment matrix',
      ];
      var last = -1;
      for (final h in order) {
        final at = md.indexOf('\n$h');
        expect(at, isNonNegative, reason: 'missing "$h"');
        expect(at, greaterThan(last), reason: '"$h" out of order');
        last = at;
      }
    });

    test('route table lists exactly the routes of the plan', () {
      final table = section('#### 4.3.2 ', '#### 4.3.3 ');
      final routeRows = <String, List<String>>{};
      for (final cells in rows(table)) {
        final m = RegExp(r'^`((?:GET|POST|PUT|DELETE) [^`]+)`$')
            .firstMatch(cells.first);
        if (m != null) routeRows[m.group(1)!] = cells;
      }
      expect(routeRows.keys.toSet(), {
        'GET /info',
        'POST /register',
        'POST /sessions',
        'GET /sessions/{sid}?wait=N',
        'GET /sessions/{sid}/files/{fid}/state',
        'PUT /sessions/{sid}/files/{fid}/chunks/{idx}',
        'POST /sessions/{sid}/files/{fid}/complete',
        'POST /sessions/{sid}/finish',
        'POST /sessions/{sid}/cancel',
        'POST /sessions/{sid}/sas',
        'POST /pair',
      });
      expect(routeRows, hasLength(11));

      // The two new routes are [I3]; their errors and auth are documented.
      final sas = routeRows['POST /sessions/{sid}/sas']!.join(' | ');
      expect(sas, contains('[I3]'));
      expect(sas, contains('X-LS-Auth'));
      for (final c in [
        '401 AUTH_INVALID',
        '404 NOT_FOUND',
        '409 WRONG_STATE',
      ]) {
        expect(sas, contains(c), reason: '/sas $c');
      }
      final pair = routeRows['POST /pair']!.join(' | ');
      expect(pair, contains('[I3]'));
      expect(pair, contains('X-LS-Auth'));
      for (final c in ['401 AUTH_INVALID', '404 NOT_FOUND']) {
        expect(pair, contains(c), reason: '/pair $c');
      }
      // X-LS-Auth is required on the proof routes; GET /info only for Contacts-only.
      for (final r in ['POST /sessions', 'POST /register']) {
        expect(routeRows[r]!.join(' | '), contains('X-LS-Auth'), reason: r);
      }
      expect(
        routeRows['GET /info']!.join(' | '),
        allOf(contains('X-LS-Auth'), contains('Contacts-only')),
      );
      // File-token routes are unchanged: no proof.
      for (final r in [
        'GET /sessions/{sid}/files/{fid}/state',
        'PUT /sessions/{sid}/files/{fid}/chunks/{idx}',
        'POST /sessions/{sid}/files/{fid}/complete',
      ]) {
        expect(
          routeRows[r]!.join(' | '),
          isNot(contains('X-LS-Auth')),
          reason: r,
        );
      }
    });

    test('error-code table: all codes of the plan are documented as [I3]', () {
      final table = section('#### 4.3.5 ', '#### 4.3.6 ');
      final byCode = <String, List<String>>{};
      for (final cells in rows(table)) {
        final m = RegExp(r'^`([A-Z_]+)`$').firstMatch(cells.first);
        if (m != null && cells.length >= 5) byCode[m.group(1)!] = cells;
      }
      expect(
        byCode.keys.toSet(),
        LsErrorCode.values.map((c) => c.wire).toSet(),
      );
      const secure = {
        'AUTH_INVALID': (401, false),
        'KEY_CHANGED': (403, false),
        'PIN_REQUIRED': (401, false),
        'PIN_INVALID': (401, false),
        'BLOCKED': (403, false),
        'INSUFFICIENT_STORAGE': (507, false),
      };
      for (final e in secure.entries) {
        final cells = byCode[e.key]!;
        expect(int.parse(cells[1]), e.value.$1, reason: '${e.key} status');
        expect(cells[2] == 'yes', e.value.$2, reason: '${e.key} retryable');
        expect(cells.last, contains('[I3]'), reason: '${e.key} marker');
      }
      for (final c in LsErrorCode.values) {
        expect(
          int.parse(byCode[c.wire]![1]),
          c.httpStatus,
          reason: '${c.wire} HTTP status',
        );
        expect(byCode[c.wire]![2] == 'yes', c.retryable, reason: c.wire);
      }
      // Meaning column carries the LSP/1.1 rules.
      expect(
        byCode['AUTH_INVALID']![3],
        allOf(contains('X-LS-Auth'), contains('commitment')),
      );
      expect(byCode['KEY_CHANGED']![3], contains('deviceId'));
      expect(byCode['NOT_FOUND']![3], contains('Contacts-only'));
      expect(byCode['TOO_LARGE']![3], contains('4 MiB'));
    });

    test('4.1 defaults quote the LSP/1.1 constants', () {
      final table = section('### 4.1 ', '### 4.2 ');
      String row(String constant) => rows(table)
          .firstWhere(
            (c) => c.any((x) => x.contains('`$constant`')),
            orElse: () => fail('no 4.1 row for $constant'),
          )
          .join(' | ');
      expect(row('kProtocolVersionSecure'), contains('1.1'));
      expect(row('kProtocolVersion'), contains('1.0'));
      expect(
        row('kMaxSessionJsonBytes'),
        allOf(contains('4 MiB'), contains('4,194,304'), contains('[I3]')),
      );
      expect(row('kMaxJsonBytes'), contains('262144'));
      expect(row('kAuthHeader'), contains('X-LS-Auth'));
      expect(row('kAuthWindow'), contains('120 s'));
      expect(row('kSasRevealTimeout'), contains('30 s'));
      expect(row('kPairTimeout'), contains('125 s'));
      expect(row('kPermissionTimeout'), contains('120 s'));
      expect(table, contains('TLS 1.3'));
    });

    test('POST /sessions check order of the secure profile (plan section 3, item 8)', () {
      final block = section(
        '**Secure-profile order [I3].**',
        '**`GET /sessions/{sid}?wait=N`.**',
      );
      final steps = [
        for (final m in RegExp(
          r'^(\d+)\. \*\*([a-z ]+)\*\*',
          multiLine: true,
        ).allMatches(block))
          m.group(2)!,
      ];
      expect(steps, [
        'gate',
        'rate limit',
        'body size',
        'auth',
        'shape',
        'version',
        'consistency',
        'sender match',
        'trust',
        'pin',
        'storage',
        'pending',
        'busy',
      ]);
      final numbers = [
        for (final m in RegExp(
          r'^(\d+)\. \*\*',
          multiLine: true,
        ).allMatches(block))
          int.parse(m.group(1)!),
      ];
      expect(numbers, List.generate(13, (i) => i + 1));
      // Spot checks of the status each step answers with.
      expect(block, contains('404 NOT_FOUND'));
      expect(block, contains('429 RATE_LIMITED'));
      expect(block, contains('413 TOO_LARGE'));
      expect(block, contains('401 AUTH_INVALID'));
      expect(block, contains('426 UPGRADE_REQUIRED'));
      expect(block, contains('403 KEY_CHANGED'));
      expect(block, contains('403 BLOCKED'));
      expect(block, contains('401 PIN_REQUIRED'));
      expect(block, contains('507 INSUFFICIENT_STORAGE'));
      expect(block, contains('409 BUSY'));
      expect(block, allOf(contains('3 per IP'), contains('8')));
    });

    test('4.3.6 specifies the X-LS-Auth grammar, signed text and checks', () {
      final s = section('#### 4.3.6 ', '### 4.4 ');
      for (final needle in [
        'X-LS-Auth',
        'v1.<cert>.<ts>.<nonce>.<sig>',
        SigDomain.auth,
        'METHOD',
        'serverFp',
        'clientFp',
        'SHA-256(body)',
        '120 s',
        '8192',
        '5 min',
        '2 KiB',
        '4 KiB',
        'Date',
        'POST /sessions',
        'POST /register',
        'POST /pair',
        '/sas',
        'GET /info',
        'Contacts-only',
        'AUTH_INVALID',
        'auth-proof.schema.json',
        'channel binding',
      ]) {
        expect(s, contains(needle), reason: '4.3.6 mentions $needle');
      }
    });

    test('every signature domain is documented', () {
      for (final label in [
        SigDomain.auth,
        SigDomain.sasCommit,
        SigDomain.sasValue,
        SigDomain.bye,
        SigDomain.pairRequest,
        SigDomain.pairInfo,
      ]) {
        expect(md, contains(label), reason: 'LSP-1.md mentions "$label"');
      }
    });

    test('5.1 SAS commit/reveal: flow, formulas, deadlines', () {
      final s = section('### 5.1 ', '### 5.2 ');
      for (final needle in [
        'sasCommit',
        'sas.nonce',
        'Ns',
        'Nr',
        SigDomain.sasCommit,
        SigDomain.sasValue,
        'mod 10^6',
        'POST /sessions/{sid}/sas',
        '30 s',
        '120 s',
        'never auto-accept',
        'FAILED(TIMEOUT)',
        'FAILED(PROTOCOL_ERROR)',
        'test-vectors-inc3.md',
        'AUTH_INVALID',
        'MUST cancel the session',
      ]) {
        expect(s, contains(needle), reason: '5.1 mentions $needle');
      }
    });

    test('5.2 PIN, 5.3 pairing, 5.4 Contacts-only', () {
      final pin = section('### 5.2 ', '### 5.3 ');
      for (final needle in [
        'PIN_REQUIRED',
        'PIN_INVALID',
        'BLOCKED',
        '5 failures',
        '10 min',
        '25',
        'Retry-After',
      ]) {
        expect(pin, contains(needle), reason: '5.2 mentions $needle');
      }
      final pair = section('### 5.3 ', '### 5.4 ');
      for (final needle in [
        'libreshare://pair?v=1&s=',
        '`r=`',
        'Increment 6',
        SigDomain.pairRequest,
        SigDomain.pairInfo,
        'HKDF',
        'POST /pair',
        '125 s',
        '10 min',
        'single use',
        'K_pair',
      ]) {
        expect(pair, contains(needle), reason: '5.3 mentions $needle');
      }
      final contacts = section('### 5.4 ', '## 6. ');
      for (final needle in [
        '404 NOT_FOUND',
        'Contacts-only',
        'no oracle',
        'stranger',
      ]) {
        expect(contacts, contains(needle), reason: '5.4 mentions $needle');
      }
    });

    test(
      '4.2: bye datagram, pair URI, caps tokens, replaced rule 8 sentence',
      () {
        final s = section('### 4.2 ', '### 4.3 ');
        expect(s, contains('"t":"bye"'));
        expect(s, contains(SigDomain.bye));
        for (final needle in [
          '50 ms',
          '60 s',
          '5 verifications',
          'discovery-announce.schema.json',
        ]) {
          expect(s, contains(needle), reason: '4.2 mentions $needle');
        }
        expect(s, contains('libreshare://pair'));
        expect(s, isNot(contains('there is no goodbye datagram')));
        // caps tokens
        expect(s, contains('`sas`'));
        expect(s, contains('`pair`'));
        // secure devices announce v 1.1
        expect(s, contains('"v":"1.1"'));
      },
    );

    test('0.3 and 4.7: profiles and the mixed old/new table', () {
      final s03 = section('### 0.3 ', '## 4. Wire protocol');
      for (final needle in [
        'plaintext profile',
        'secure profile',
        '1.0',
        '1.1',
        'TLS 1.3',
        'kProtocolVersionSecure',
        'kSupportedMajors',
      ]) {
        expect(s03, contains(needle), reason: '0.3 mentions $needle');
      }
      final s47 = section('### 4.7 ', '## 5. Security summary');
      for (final needle in [
        'NO_CONNECTION',
        '--allow-insecure',
        'empty fingerprint',
        'closed connection',
        'INTERNAL',
        '404',
        'sasCommit',
        'bye',
      ]) {
        expect(s47, contains(needle), reason: '4.7 mentions $needle');
      }
    });

    test('section 5 and 7 reference the vectors and this test', () {
      expect(md, contains('docs/protocol/test-vectors-inc3.md'));
      final s7 = section('## 7. Conformance', '## 8. Increment matrix');
      expect(s7, contains('lsp11_conformance_test.dart'));
      expect(s7, contains('test-vectors-inc3.md'));
    });

    test('the Increment 3 ADRs exist', () {
      for (final f in [
        '0004-authentication-model.md',
        '0005-sas-commit-reveal.md',
      ]) {
        final path = _findUp(p.join('docs', 'adr', f));
        expect(path, isNotNull, reason: f);
        final text = File(path!).readAsStringSync();
        expect(text, contains('- Status:'));
        expect(text, contains('## Decision'));
        expect(text, contains('## Consequences'));
      }
    });
  });

  group('the byte layouts documented in LSP-1.md equal the implementation', () {
    // Independent re-computation from the formulas of LSP-1 5.1 and 4.3.6
    // (only dart:convert and package:crypto), compared with the production
    // code. The known-answer vectors file adds fixed values on top of this.
    Uint8List bytes(int n, int seed) =>
        Uint8List.fromList([for (var i = 0; i < n; i++) (i * 7 + seed) & 255]);
    Uint8List h(List<int> data) =>
        Uint8List.fromList(sha256.convert(data).bytes);
    List<int> domain(String label, List<int> msg) => [
      ...utf8.encode(label),
      0,
      ...msg,
    ];
    String b64u(List<int> b) => base64Url.encode(b).replaceAll('=', '');

    test('sasCommit = b64url(SHA-256("LSP1-SAS-C" 0x00 Ns fpS fpR))', () {
      final ns = bytes(16, 3);
      final expected = b64u(
        h(
          domain(SigDomain.sasCommit, [
            ...ns,
            ...ascii.encode(fpS),
            ...ascii.encode(fpR),
          ]),
        ),
      );
      final actual = sasCommit(
        ns: ns,
        senderFingerprint: fpS,
        receiverFingerprintSeenBySender: fpR,
      );
      expect(actual, expected);
      expect(actual, hasLength(43));
      expectValid('session-request', requestWith(sasCommit: actual).toJson());
      // The receiver recomputes with its OWN fingerprint: equal for a direct
      // connection, different behind a relaying man-in-the-middle.
      expect(
        sasCommitMatches(
          commit: actual,
          ns: ns,
          senderFingerprint: fpS,
          receiverFingerprintSeenBySender: fpR,
        ),
        isTrue,
      );
      expect(
        sasCommitMatches(
          commit: actual,
          ns: ns,
          senderFingerprint: fpS,
          receiverFingerprintSeenBySender: fpS,
        ),
        isFalse,
        reason: 'a relay presents its own certificate: commitment mismatch',
      );
    });

    test(
      'code = u32_be(SHA-256("LSP1-SAS-V" 0x00 Ns Nr min max)[0..4]) mod 10^6',
      () {
        var sawLeadingZero = false;
        for (var i = 0; i < 400; i++) {
          final ns = bytes(16, i);
          final nr = bytes(16, i + 101);
          final a = h([i, 1])
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join()
              .toUpperCase();
          final b = h([i, 2])
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join()
              .toUpperCase();
          final lo = a.compareTo(b) <= 0 ? a : b;
          final hi = a.compareTo(b) <= 0 ? b : a;
          final digest = h(
            domain(SigDomain.sasValue, [
              ...ns,
              ...nr,
              ...ascii.encode(lo),
              ...ascii.encode(hi),
            ]),
          );
          final value =
              ByteData.sublistView(digest).getUint32(0, Endian.big) % 1000000;
          final expected = value.toString().padLeft(6, '0');
          expect(
            sasCode(ns: ns, nr: nr, fingerprintA: a, fingerprintB: b),
            expected,
            reason: 'i=$i',
          );
          expect(
            sasCode(ns: ns, nr: nr, fingerprintA: b, fingerprintB: a),
            expected,
            reason: 'order of the fingerprints does not matter',
          );
          if (expected.startsWith('0')) sawLeadingZero = true;
        }
        expect(sawLeadingZero, isTrue, reason: 'leading zeros are kept');
        expect(sasCodeDisplay('048291'), '048 291');
      },
    );

    test('X-LS-Auth: grammar, signed text, domain and channel binding', () {
      final g = generateIdentity(deviceId: sender.deviceId);
      final id = KeyIdentity.fromGenerated(g);
      final body = utf8.encode(
        jsonEncode(requestWith(sasCommit: commit).toJson()),
      );
      final now = DateTime.utc(2026, 11, 4, 12);
      final nonce = bytes(16, 9);
      final header = buildAuthHeader(
        identity: id,
        method: 'POST',
        pathAndQuery: '$kApiPrefix/sessions',
        body: body,
        serverFingerprint: fpR,
        now: now,
        nonce: nonce,
      );

      // Grammar: v1.<cert>.<ts>.<nonce>.<sig>, validated by the schema's header text form.
      final headerSchema = JsonSchema.create({
        r'$schema': _docs['auth-proof']![r'$schema'],
        ..._m(_m(_docs['auth-proof']![r'$defs'])['header']),
      }, schemaVersion: SchemaVersion.draft2020_12);
      expect(headerSchema.validate(header).isValid, isTrue, reason: header);
      expect(header.length, lessThanOrEqualTo(4096));
      final parts = header.split('.');
      expect(parts, hasLength(5));
      final decoded = {
        'v': parts[0],
        'cert': parts[1],
        'ts': int.parse(parts[2]),
        'nonce': parts[3],
        'sig': parts[4],
      };
      expectValid('auth-proof', decoded, 'decoded header');
      expect(decoded['ts'], now.millisecondsSinceEpoch);
      expect(b64urlDecode(parts[3]), nonce);
      final cert = b64urlDecode(parts[1]);
      expect(cert, g.identity.certDer);
      expect(fingerprintHex(cert), g.identity.fingerprint);

      // Signed text: domain, NUL, then the eight LF-separated fields of 4.3.6.
      final m = utf8.encode(
        [
          'POST',
          '$kApiPrefix/sessions',
          sha256Hex(body),
          '${decoded['ts']}',
          parts[3],
          fpR,
          g.identity.fingerprint,
        ].join('\n'),
      );
      final sig = b64urlDecode(parts[4]);
      expect(sig, hasLength(64));
      bool verifies(String label, List<int> msg) => verifySignature(
        certDer: cert,
        domain: label,
        message: msg,
        signature: sig,
      );
      expect(verifies(SigDomain.auth, m), isTrue);
      // A different domain label, server fingerprint, body or method must not verify.
      expect(verifies(SigDomain.sasCommit, m), isFalse, reason: 'domain');
      expect(
        verifies(
          SigDomain.auth,
          utf8.encode(utf8.decode(m).replaceFirst(fpR, fpS)),
        ),
        isFalse,
        reason: 'serverFp',
      );
      expect(
        verifies(
          SigDomain.auth,
          utf8.encode(utf8.decode(m).replaceFirst('POST', 'PUT')),
        ),
        isFalse,
        reason: 'method',
      );
      expect(
        verifies(
          SigDomain.auth,
          utf8.encode(
            utf8.decode(m).replaceFirst(sha256Hex(body), sha256Hex([])),
          ),
        ),
        isFalse,
        reason: 'body',
      );

      // The receiver rebuilds the text with its OWN fingerprint: right server accepts,
      // another server (relay) rejects, the same nonce is a replay.
      AuthOk? ok;
      final cache = NonceCache();
      final r = verifyAuthHeader(
        header: header,
        method: 'POST',
        pathAndQuery: '$kApiPrefix/sessions',
        body: body,
        ownFingerprint: fpR,
        now: now,
        nonces: cache,
      );
      expect(r, isA<AuthOk>());
      ok = r as AuthOk;
      expect(ok.peer.fingerprint, g.identity.fingerprint);
      final replay = verifyAuthHeader(
        header: header,
        method: 'POST',
        pathAndQuery: '$kApiPrefix/sessions',
        body: body,
        ownFingerprint: fpR,
        now: now,
        nonces: cache,
      );
      expect(replay, isNot(isA<AuthOk>()), reason: 'replay');
      final relay = verifyAuthHeader(
        header: header,
        method: 'POST',
        pathAndQuery: '$kApiPrefix/sessions',
        body: body,
        ownFingerprint: fpS,
        now: now,
        nonces: NonceCache(),
      );
      expect(relay, isNot(isA<AuthOk>()), reason: 'proof for another server');
      final stale = verifyAuthHeader(
        header: header,
        method: 'POST',
        pathAndQuery: '$kApiPrefix/sessions',
        body: body,
        ownFingerprint: fpR,
        now: now.add(kAuthWindow + const Duration(seconds: 1)),
        nonces: NonceCache(),
      );
      expect(stale, isNot(isA<AuthOk>()), reason: '121 s later');
    });
  });

  group('the plaintext profile is exactly the LSP/1.0 wire', () {
    late Directory dir;
    late LibreShareEngine engine;
    late HttpClient http;
    late int port;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('ls_lsp11_conf_');
      engine = LibreShareEngine(
        self: const DeviceInfo(
          deviceId: 'lsp11-legacy',
          alias: 'lsp11-legacy',
          platform: 'linux',
          fingerprint: '',
        ),
        downloadDir: Directory(p.join(dir.path, 'rx')),
        preferredPort: 0,
        autoAccept: false,
        bindAddress: InternetAddress.loopbackIPv4,
        enableRateLimit: false,
      );
      port = await engine.start();
      http = HttpClient();
    });

    tearDown(() async {
      http.close(force: true);
      await engine.dispose(force: true);
      dir.deleteSync(recursive: true);
    });

    test('v1.1 senders and the new members are accepted and ignored', () async {
      var (status, body) = await _call(
        http,
        port,
        'POST',
        '/register',
        body: sender.toJson(),
      );
      expect(status, 200, reason: 'a peer with v 1.1 is accepted');
      expectValid('device-info', body, 'POST /register');

      (status, body) = await _call(
        http,
        port,
        'POST',
        '/sessions',
        body: requestWith(sasCommit: commit).toJson(),
      );
      expect(status, 202, reason: 'sasCommit is an unknown member to LSP/1.0');
      expectValid('session-status', body, 'POST /sessions');
      expect(body['status'], 'PENDING');
      expect(body.containsKey('sas'), isFalse, reason: 'no SAS without TLS');
    });

    test(
      '/sas and /pair do not exist on the plaintext profile (404)',
      () async {
        var (status, body) = await _call(
          http,
          port,
          'POST',
          '/sessions/nope/sas',
          body: {'nonce': nonceS},
        );
        expect(status, 404);
        expectValid('error-envelope', body, '/sas');
        expect(_m(body['error'])['code'], 'NOT_FOUND');

        (status, body) = await _call(
          http,
          port,
          'POST',
          '/pair',
          body: pairRequest().toJson(),
        );
        expect(status, 404);
        expectValid('error-envelope', body, '/pair');
        expect(_m(body['error'])['code'], 'NOT_FOUND');
      },
    );
  });
}
