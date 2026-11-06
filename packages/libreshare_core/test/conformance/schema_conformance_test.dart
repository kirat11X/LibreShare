// Protocol conformance for the JSON shapes (LSP-1 section 7, spec section 13):
//
//  * every schema in docs/protocol/schemas loads and its `examples` validate;
//  * the validator really rejects bad input (negative controls);
//  * toJson() of every DTO and LsException.toEnvelope() validate;
//  * golden fixtures round-trip fromJson -> toJson and validate;
//  * fromJson ignores unknown members at every level and tolerates missing
//    optional members;
//  * the JSON a live ApiServer emits validates;
//  * the error-code table of LSP-1 section 4.3.5 equals LsErrorCode.
//
// The schemas and the markdown table are located by walking up from the
// working directory, so the test runs from the package or the repo root.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:json_schema/json_schema.dart';
import 'package:libreshare_core/libreshare_core.dart';
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
    (throw StateError(
      'docs/protocol/schemas not found above ${Directory.current}',
    ));
final String lspMarkdown =
    _findUp(p.join('docs', 'protocol', 'LSP-1.md')) ??
    (throw StateError('docs/protocol/LSP-1.md not found'));
final String fixturesDir =
    _findUp(p.join('test', 'conformance', 'fixtures')) ??
    _findUp(
      p.join('packages', 'libreshare_core', 'test', 'conformance', 'fixtures'),
    ) ??
    (throw StateError('fixtures directory not found'));

Map<String, Object?> _readJson(String path) =>
    (jsonDecode(File(path).readAsStringSync()) as Map).cast<String, Object?>();

/// Schema documents keyed by file name stem (`device-info`) and by `$id`.
final Map<String, Map<String, Object?>> _docs = {};
final Map<String, Map<String, Object?>> _byId = {};
final Map<String, JsonSchema> _schemas = {};

void _loadSchemas() {
  final files =
      Directory(schemasDir)
          .listSync()
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
  // Cross-file $ref (session-request -> device-info, ...) resolves through
  // the $id of the sibling documents; nothing is fetched from the network.
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

/// Validates [instance]; the failure message lists the validator's errors.
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

/// Normalises model output (typed lists, DateTime-free maps) to plain JSON.
Object? plain(Object? j) => jsonDecode(jsonEncode(j));

Map<String, Object?> deepCopy(Map<String, Object?> m) =>
    (plain(m) as Map).cast<String, Object?>();

/// Adds unknown members to every JSON object in [j], except to maps keyed by
/// ids (`acceptedFiles`), where an extra key would be a legitimate entry.
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

// ------------------------------------------------------------------ models

const _fp = 'FC074C4445C65D5C5208058734A816CFC5E77A51D5D9B596AD324828CEFA422E';
const _emptySha =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
const _someSha =
    '938ed3faacee1cb99788419b4bbbe70690b67a0494621834c0e92424623645b6';

const deviceFull = DeviceInfo(
  deviceId: '5b0f7d8e-3c1a-4f2b-9d6e-1a2b3c4d5e6f',
  alias: 'Ravi-ThinkPad',
  platform: 'windows',
  fingerprint: _fp,
  addrs: [
    DeviceAddress('192.168.1.23', iface: 'wifi'),
    DeviceAddress('10.0.0.5', iface: 'ethernet'),
    DeviceAddress('fe80::1'),
  ],
  caps: ['resume', 'tunnel', 'sas'],
);
const deviceDefaults = DeviceInfo(
  deviceId: 'd-1',
  alias: 'x',
  platform: 'linux',
);

final fileBig = FileItem(
  fileId: 'f1',
  fileName: 'report.pdf',
  size: 5242880000,
  chunkCount: 1250,
  mime: 'application/pdf',
  sha256: _someSha,
  modified: DateTime.utc(2026, 10, 30, 10),
);
const fileEmpty = FileItem(
  fileId: 'f2',
  fileName: 'empty.txt',
  relativePath: 'docs/notes',
  size: 0,
  chunkCount: 0,
  mime: 'text/plain',
  sha256: _emptySha,
);
final fileOver2Gib = FileItem(
  fileId: 'f3',
  fileName: 'disk.img',
  size: 5368709120,
  chunkCount: 1280,
  modified: DateTime.utc(2026, 1, 2, 3, 4, 5, 678),
);

final tunnel = TunnelOffer(
  provider: 'cloudflare-quick',
  url: 'https://x.trycloudflare.com/t/ABkLScJAffjjp9vnJ60X5w',
  keyB64: '9XGqai5pBy8t4HsHIxcu68X4_e4fOg7MYyKYMHc7WPA',
  expiresAt: DateTime.utc(2026, 11, 2, 12, 30),
);

SessionRequest requestWith({String? pin, TunnelOffer? offer}) => SessionRequest(
  sender: deviceFull,
  pin: pin,
  files: [fileBig, fileEmpty],
  totalSize: fileBig.size + fileEmpty.size,
  tunnelOffer: offer,
);

const token1 = 'mwiKDV2SFbOnBV-HSn3ehQ';
const token2 = 'PfCtA719HZzJ7Kupi_t2sQ';

SessionStatus statusOf(TransferStatus s, [FailureReason? reason]) =>
    SessionStatus(
      sessionId: 'c1d2e3f4-0a1b-4c2d-8e3f-a4b5c6d7e8f9',
      status: s,
      failureReason: reason,
      acceptedFiles: s == TransferStatus.inProgress
          ? {
              'f1': const AcceptedFile(token: token1),
              'f2': const AcceptedFile(
                token: token2,
                receivedRanges: [
                  [0, 41],
                  [50, 50],
                ],
              ),
            }
          : const {},
    );

// ------------------------------------------------------------ fixture table

class Golden {
  const Golden(this.file, this.schema, this.roundTrip);
  final String file;
  final String schema;

  /// fromJson then toJson.
  final Object? Function(Map<String, Object?> json) roundTrip;
}

Map<String, Object?> _m(Object? o) => (o! as Map).cast<String, Object?>();

final List<Golden> goldens = [
  Golden(
    'device_info.json',
    'device-info',
    (j) => DeviceInfo.fromJson(j).toJson(),
  ),
  Golden(
    'device_info_loopback.json',
    'device-info',
    (j) => DeviceInfo.fromJson(j).toJson(),
  ),
  Golden('file_item.json', 'file-item', (j) => FileItem.fromJson(j).toJson()),
  Golden(
    'file_item_empty.json',
    'file-item',
    (j) => FileItem.fromJson(j).toJson(),
  ),
  Golden(
    'file_item_over_2gib.json',
    'file-item',
    (j) => FileItem.fromJson(j).toJson(),
  ),
  Golden(
    'session_request.json',
    'session-request',
    (j) => SessionRequest.fromJson(j).toJson(),
  ),
  Golden(
    'session_request_tunnel.json',
    'session-request',
    (j) => SessionRequest.fromJson(j).toJson(),
  ),
  for (final s in ['pending', 'in_progress', 'completed', 'failed'])
    Golden(
      'session_status_$s.json',
      'session-status',
      (j) => SessionStatus.fromJson(j).toJson(),
    ),
  Golden(
    'file_state.json',
    'file-state',
    (j) => FileState.fromJson(j).toJson(),
  ),
  Golden(
    'file_verification.json',
    'file-verification',
    (j) => FileVerification.fromJson(j).toJson(),
  ),
  Golden(
    'tunnel_offer.json',
    'tunnel-offer',
    (j) => TunnelOffer.fromJson(j).toJson(),
  ),
  Golden(
    'error_envelope.json',
    'error-envelope',
    (j) => LsException.fromEnvelope(j).toEnvelope(),
  ),
];

// ----------------------------------------------------------- live wire rig

class Wire {
  Wire(this.port);
  final int port;
  final HttpClient _http = HttpClient();

  Future<(int, Map<String, Object?>)> json(
    String method,
    String path, {
    Object? body,
    String? token,
  }) async {
    final req = await _http.openUrl(
      method,
      Uri.parse('http://127.0.0.1:$port$kApiPrefix$path'),
    );
    if (token != null) req.headers.set('authorization', 'Bearer $token');
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

  Future<(int, Map<String, Object?>)> putChunk(
    String path,
    List<int> bytes,
    String token,
  ) async {
    final req = await _http.putUrl(
      Uri.parse('http://127.0.0.1:$port$kApiPrefix$path'),
    );
    req.headers
      ..set('authorization', 'Bearer $token')
      ..set(kChunkHashHeader, sha256.convert(bytes).toString())
      ..contentType = ContentType.binary
      ..contentLength = bytes.length;
    req.add(bytes);
    final res = await req.close();
    final text = await utf8.decodeStream(res);
    return (res.statusCode, (jsonDecode(text) as Map).cast<String, Object?>());
  }

  void close() => _http.close(force: true);
}

// --------------------------------------------------------------------- main

void main() {
  _loadSchemas();

  group('schemas', () {
    test(
      'all nine LSP/1 schemas are present and declared as draft 2020-12',
      () {
        expect(_docs.keys, {
          'device-info',
          'discovery-announce',
          'error-envelope',
          'file-item',
          'file-state',
          'file-verification',
          'session-request',
          'session-status',
          'tunnel-offer',
        });
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
        }
      },
    );

    for (final e in _docs.entries) {
      final examples = (e.value['examples']! as List).cast<Object?>();
      for (var i = 0; i < examples.length; i++) {
        test('${e.key}: example #$i validates', () {
          expectValid(e.key, examples[i], 'example #$i');
        });
      }
    }

    test(
      'LSP-1 payload examples validate (SessionRequest, SessionStatus, ...)',
      () {
        // The prose examples of LSP-1 section 4.3.3 / 4.6.
        expectValid('file-state', {
          'receivedRanges': [
            [0, 41],
          ],
          'chunkCount': 1250,
        });
        expectValid('file-verification', {
          'verified': true,
          'sha256': _someSha,
        });
        expectValid('error-envelope', {
          'error': {
            'code': 'UPGRADE_REQUIRED',
            'message': 'unsupported protocol major 2',
            'retryable': false,
          },
          'supported': ['1'],
        });
      },
    );
  });

  group('negative controls: the validator rejects what the spec forbids', () {
    Map<String, Object?> example(String schema, [int i = 0]) =>
        deepCopy(_m((_docs[schema]!['examples']! as List)[i]));

    test('DeviceInfo', () {
      expectInvalid('device-info', example('device-info')..remove('deviceId'));
      expectInvalid('device-info', example('device-info')..remove('alias'));
      expectInvalid(
        'device-info',
        example('device-info')..['fingerprint'] = _fp.toLowerCase(),
        'lowercase fingerprint',
      );
      expectInvalid(
        'device-info',
        example('device-info')..['fingerprint'] = 'ABCD',
        'short fingerprint',
      );
      expectInvalid('device-info', example('device-info')..['v'] = '1');
      expectInvalid('device-info', example('device-info')..['port'] = 70000);
      expectInvalid('device-info', example('device-info')..['port'] = '53318');
      expectInvalid('device-info', example('device-info')..['caps'] = [1]);
    });

    test('FileItem', () {
      expectInvalid(
        'file-item',
        example('file-item')..['sha256'] = _someSha.toUpperCase(),
      );
      expectInvalid('file-item', example('file-item')..['sha256'] = 'abc');
      expectInvalid('file-item', example('file-item')..['size'] = -1);
      expectInvalid('file-item', example('file-item')..remove('chunkCount'));
      expectInvalid(
        'file-item',
        example('file-item')..['modified'] = 'yesterday',
      );
      expectInvalid('file-item', example('file-item')..['fileName'] = '');
    });

    test('SessionRequest', () {
      expectInvalid(
        'session-request',
        example('session-request')..['pin'] = '12345',
      );
      expectInvalid(
        'session-request',
        example('session-request')..['totalSize'] = -1,
      );
      expectInvalid(
        'session-request',
        example('session-request')..remove('files'),
      );
      expectInvalid(
        'session-request',
        example('session-request')..['tunnelOffer'] = {'provider': 'x'},
        'incomplete tunnelOffer',
      );
      expectInvalid(
        'session-request',
        example('session-request')
          ..['files'] = [
            {'fileId': 'f1'},
          ],
        'file without name/size',
      );
    });

    test('SessionStatus', () {
      expectInvalid(
        'session-status',
        example('session-status')..['status'] = 'DONE',
      );
      expectInvalid(
        'session-status',
        example('session-status')..['status'] = 'pending',
      );
      expectInvalid(
        'session-status',
        example('session-status')..['failureReason'] = 'BOOM',
      );
      expectInvalid(
        'session-status',
        example('session-status', 1)
          ..['acceptedFiles'] = {
            'f1': {'token': 'short'},
          },
        'token below 22 chars',
      );
      expectInvalid(
        'session-status',
        example('session-status', 1)
          ..['acceptedFiles'] = {
            'f1': {
              'token': token1,
              'receivedRanges': [
                [3],
              ],
            },
          },
        'range with one end',
      );
    });

    test('FileState / FileVerification / TunnelOffer / ErrorEnvelope', () {
      expectInvalid('file-state', {'chunkCount': -1});
      expectInvalid('file-state', {
        'receivedRanges': [
          [0, 1, 2],
        ],
        'chunkCount': 3,
      });
      expectInvalid('file-verification', {
        'verified': 'yes',
        'sha256': _someSha,
      });
      expectInvalid('file-verification', {'verified': true, 'sha256': 'xyz'});
      expectInvalid(
        'tunnel-offer',
        example('tunnel-offer')..['url'] = 'http://x',
      );
      expectInvalid(
        'tunnel-offer',
        example('tunnel-offer')..['keyB64'] = 'short',
      );
      expectInvalid(
        'tunnel-offer',
        example('tunnel-offer')..['expiresAt'] = 'soon',
      );
      expectInvalid('error-envelope', {
        'error': {'code': 'NOPE', 'message': 'm', 'retryable': false},
      });
      expectInvalid('error-envelope', {
        'error': {'code': 'NOT_FOUND', 'message': 'm'},
      });
      expectInvalid('error-envelope', {'code': 'NOT_FOUND'});
    });

    test('DiscoveryAnnounce needs announce and a valid port', () {
      expectInvalid(
        'discovery-announce',
        example('discovery-announce')..remove('announce'),
      );
      expectInvalid(
        'discovery-announce',
        example('discovery-announce')..['deviceId'] = '',
      );
      for (final port in [-1, 65536]) {
        expectInvalid(
          'discovery-announce',
          example('discovery-announce')..['port'] = port,
          'port $port',
        );
      }
    });

    test('DiscoveryAnnounce port 0 is a send-only probe: valid only with '
        'announce:true (LSP-1 4.2 rule 8)', () {
      expectValid(
        'discovery-announce',
        example('discovery-announce')..['port'] = 0,
        'probe',
      );
      expectValid('discovery-announce', example('discovery-announce', 1));
      expectInvalid(
        'discovery-announce',
        example('discovery-announce')
          ..['port'] = 0
          ..['announce'] = false,
        'port 0 with announce:false',
      );
      // A real port is fine with either announce value.
      expectValid(
        'discovery-announce',
        example('discovery-announce')..['announce'] = false,
      );
    });
  });

  group('toJson() output validates against its schema', () {
    test('DeviceInfo (defaults and fully populated)', () {
      expectValid('device-info', deviceDefaults.toJson());
      expectValid('device-info', deviceFull.toJson());
      expectValid(
        'device-info',
        DeviceInfo(
          deviceId: 'x',
          alias: 'Ünïcode ✓ 名前',
          platform: 'android',
          deviceType: 'phone',
          port: 53327,
        ).toJson(),
      );
    });

    test(
      'DeviceInfo of a send-only client (port 0) is still a valid sender',
      () {
        // `ls send` / `ls info` build their identity with port 0: no API
        // listener. It travels as SessionRequest.sender.
        const sendOnly = DeviceInfo(
          deviceId: 'cli-1',
          alias: 'cli',
          platform: 'linux',
          port: 0,
        );
        expectValid('device-info', sendOnly.toJson());
        expectValid(
          'session-request',
          SessionRequest(
            sender: sendOnly,
            files: [fileEmpty],
            totalSize: 0,
          ).toJson(),
        );
      },
    );

    test('DeviceInfo + announce is a DiscoveryAnnounce', () {
      for (final announce in [true, false]) {
        expectValid('discovery-announce', {
          ...deviceFull.toJson(),
          'announce': announce,
        });
      }
      // Before TLS the fingerprint is empty (LSP-1 4.2 rule 7).
      expectValid('discovery-announce', {
        ...deviceDefaults.toJson(),
        'announce': true,
      });
    });

    test('the codec\'s send-only probe (port 0) is a DiscoveryAnnounce', () {
      final bytes = encodeAnnounce(deviceFull, announce: true, probe: true);
      final json = jsonDecode(utf8.decode(bytes));
      expect((json as Map)['port'], 0);
      expectValid('discovery-announce', json, 'probe from encodeAnnounce');
      expectValid(
        'discovery-announce',
        jsonDecode(utf8.decode(encodeAnnounce(deviceFull, announce: false))),
        'reply from encodeAnnounce',
      );
    });

    test('FileItem', () {
      for (final f in [fileBig, fileEmpty, fileOver2Gib]) {
        expectValid('file-item', f.toJson(), f.fileId);
      }
      // A local (non-UTC) timestamp is emitted as UTC.
      expectValid(
        'file-item',
        FileItem(
          fileId: 'f',
          fileName: 'n',
          size: 1,
          chunkCount: 1,
          modified: DateTime(2026, 5, 6, 7, 8, 9),
        ).toJson(),
      );
    });

    test('TunnelOffer', () {
      expectValid('tunnel-offer', tunnel.toJson());
    });

    test('SessionRequest with and without tunnelOffer', () {
      expectValid('session-request', requestWith().toJson(), 'no offer');
      expectValid(
        'session-request',
        requestWith(pin: '123456').toJson(),
        'pin',
      );
      expectValid(
        'session-request',
        requestWith(pin: '000000', offer: tunnel).toJson(),
        'tunnelOffer',
      );
      final withOffer = requestWith(offer: tunnel).toJson();
      expect(withOffer['tunnelOffer'], isA<Map<String, Object?>>());
      expect(requestWith().toJson()['tunnelOffer'], isNull);
    });

    test('SessionStatus: all four statuses and every failure reason', () {
      expectValid('session-status', statusOf(TransferStatus.pending).toJson());
      expectValid(
        'session-status',
        statusOf(TransferStatus.inProgress).toJson(),
      );
      expectValid(
        'session-status',
        statusOf(TransferStatus.completed).toJson(),
      );
      for (final r in FailureReason.values) {
        expectValid(
          'session-status',
          statusOf(TransferStatus.failed, r).toJson(),
          r.wire,
        );
      }
      expectValid('session-status', statusOf(TransferStatus.failed).toJson());
    });

    test('FileState', () {
      expectValid(
        'file-state',
        const FileState(receivedRanges: [], chunkCount: 0).toJson(),
      );
      expectValid(
        'file-state',
        FileState(
          receivedRanges: compactRanges([0, 1, 2, 7, 9, 10]),
          chunkCount: 1250,
        ).toJson(),
      );
    });

    test('FileVerification', () {
      expectValid(
        'file-verification',
        const FileVerification(verified: true, sha256: _emptySha).toJson(),
      );
    });

    test('LsException.toEnvelope() for every LsErrorCode', () {
      for (final c in LsErrorCode.values) {
        expectValid(
          'error-envelope',
          LsException(c, 'diagnostic').toEnvelope(),
          c.wire,
        );
        expectValid(
          'error-envelope',
          LsException(c).toEnvelope(),
          '${c.wire} (empty message)',
        );
      }
    });
  });

  group('golden fixtures', () {
    test('every fixture file is covered by the table', () {
      final onDisk = {
        for (final f in Directory(fixturesDir).listSync().whereType<File>())
          p.basename(f.path),
      };
      expect(onDisk, goldens.map((g) => g.file).toSet());
    });

    for (final g in goldens) {
      test('${g.file}: validates and round-trips fromJson -> toJson', () {
        final golden = _readJson(p.join(fixturesDir, g.file));
        expectValid(g.schema, golden, g.file);
        expect(plain(g.roundTrip(deepCopy(golden))), golden);
      });
    }

    test('the model fixtures equal the in-code models', () {
      Map<String, Object?> fx(String n) => _readJson(p.join(fixturesDir, n));
      expect(plain(fileBig.toJson()), fx('file_item.json'));
      expect(plain(fileEmpty.toJson()), fx('file_item_empty.json'));
      expect(plain(fileOver2Gib.toJson()), fx('file_item_over_2gib.json'));
      expect(plain(tunnel.toJson()), fx('tunnel_offer.json'));
      expect(
        plain(statusOf(TransferStatus.inProgress).toJson()),
        fx('session_status_in_progress.json'),
      );
      expect(
        plain(statusOf(TransferStatus.failed, FailureReason.rejected).toJson()),
        fx('session_status_failed.json'),
      );
      expect(
        plain(statusOf(TransferStatus.pending).toJson()),
        fx('session_status_pending.json'),
      );
      expect(
        plain(statusOf(TransferStatus.completed).toJson()),
        fx('session_status_completed.json'),
      );
      expect(
        plain(
          const FileState(
            receivedRanges: [
              [0, 41],
              [50, 50],
            ],
            chunkCount: 1250,
          ).toJson(),
        ),
        fx('file_state.json'),
      );
    });

    test(
      'parsed values keep their types (64-bit sizes, UTC dates, ranges)',
      () {
        final item = FileItem.fromJson(
          _readJson(p.join(fixturesDir, 'file_item_over_2gib.json')),
        );
        expect(item.size, 5368709120);
        expect(item.sha256, isNull);
        expect(item.modified, DateTime.utc(2026, 1, 2, 3, 4, 5, 678));
        expect(item.modified!.isUtc, isTrue);
        final st = SessionStatus.fromJson(
          _readJson(p.join(fixturesDir, 'session_status_in_progress.json')),
        );
        expect(st.status, TransferStatus.inProgress);
        expect(st.acceptedFiles['f2']!.receivedRanges, [
          [0, 41],
          [50, 50],
        ]);
        expect(
          expandRanges(st.acceptedFiles['f2']!.receivedRanges),
          hasLength(43),
        );
      },
    );
  });

  group('unknown members are ignored at every level (LSP-1 0.2, spec 4.6)', () {
    for (final g in goldens) {
      test(g.file, () {
        final golden = _readJson(p.join(fixturesDir, g.file));
        final noisy = _m(withUnknown(golden));
        expect(noisy, isNot(golden), reason: 'sanity: noise was injected');
        expect(plain(g.roundTrip(deepCopy(noisy))), golden);
      });
    }

    test(
      'a future minor version and unknown capability tokens are accepted',
      () {
        final d = DeviceInfo.fromJson({
          'proto': 'libreshare',
          'v': '1.7',
          'deviceId': 'd',
          'alias': 'a',
          'caps': ['resume', 'teleport'],
          'newThing': {'x': 1},
        });
        expect(d.version, '1.7');
        expect(d.caps, ['resume', 'teleport']);
        expectValid('device-info', d.toJson());
      },
    );
  });

  group('missing optional members take their defaults', () {
    test('DeviceInfo needs only deviceId and alias', () {
      final d = DeviceInfo.fromJson({'deviceId': 'd', 'alias': 'a'});
      expect(d.platform, 'unknown');
      expect(d.deviceType, 'desktop');
      expect(d.fingerprint, '');
      expect(d.port, kDefaultPort);
      expect(d.addrs, isEmpty);
      expect(d.version, kProtocolVersion);
      expectValid('device-info', d.toJson());
      expect(DeviceAddress.fromJson({'ip': '1.2.3.4'}).iface, 'unknown');
    });

    test('FileItem needs fileId, fileName, size, chunkCount', () {
      final f = FileItem.fromJson({
        'fileId': 'f',
        'fileName': 'n',
        'size': 3,
        'chunkCount': 1,
      });
      expect(f.mime, 'application/octet-stream');
      expect(f.relativePath, isNull);
      expect(f.sha256, isNull);
      expect(f.modified, isNull);
      expectValid('file-item', f.toJson());
    });

    test('SessionRequest and SessionStatus', () {
      final r = SessionRequest.fromJson({
        'sender': {'deviceId': 'd', 'alias': 'a'},
        'files': <Object?>[],
        'totalSize': 0,
      });
      expect(r.chunkSize, kChunkSize);
      expect(r.pin, isNull);
      expect(r.tunnelOffer, isNull);
      final s = SessionStatus.fromJson({'sessionId': 's', 'status': 'PENDING'});
      expect(s.acceptedFiles, isEmpty);
      expect(s.failureReason, isNull);
      expect(AcceptedFile.fromJson({'token': token1}).receivedRanges, isEmpty);
      expect(FileState.fromJson({'chunkCount': 4}).receivedRanges, isEmpty);
    });

    test(
      'LsException.fromEnvelope: unknown code -> INTERNAL, missing message',
      () {
        final e = LsException.fromEnvelope({
          'error': {'code': 'FROM_THE_FUTURE'},
          'extra': 1,
        }, status: 418);
        expect(e.code, LsErrorCode.internal);
        expect(e.message, 'HTTP 418');
        expect(LsException.fromEnvelope(const {}).code, LsErrorCode.internal);
        final known = LsException.fromEnvelope({
          'error': {
            'code': 'TOKEN_INVALID',
            'message': 'm',
            'retryable': false,
          },
        });
        expect(known.code, LsErrorCode.tokenInvalid);
        expect(known.httpStatus, 401);
      },
    );
  });

  group('wire values', () {
    test('enums in the schemas equal the Dart enums', () {
      Set<Object?> enumOf(Object? node) =>
          ((node! as Map)['enum']! as List).toSet();
      final status = _m(_docs['session-status']!['properties']);
      expect(
        enumOf(status['status']),
        TransferStatus.values.map((s) => s.wire).toSet(),
      );
      expect(enumOf(status['failureReason']), {
        ...FailureReason.values.map((r) => r.wire),
        null,
      });
      final env = _m(
        _m(_m(_docs['error-envelope']!['properties'])['error'])['properties'],
      );
      expect(
        enumOf(env['code']),
        LsErrorCode.values.map((c) => c.wire).toSet(),
      );
    });

    test('TransferStatus and FailureReason round-trip their wire strings', () {
      for (final s in TransferStatus.values) {
        expect(TransferStatus.fromWire(s.wire), s);
      }
      for (final r in FailureReason.values) {
        expect(FailureReason.fromWire(r.wire), r);
      }
      expect(FailureReason.fromWire(null), isNull);
      expect(TransferStatus.values, hasLength(4));
    });
  });

  group('LSP-1 error-code table equals LsErrorCode', () {
    // Rows look like: | `CODE` | 409 | yes | meaning | [I1] |
    final rowRe = RegExp(
      r'^\|\s*`([A-Z_]+)`\s*\|\s*(\d{3})\s*\|\s*(yes|no)\s*\|',
      multiLine: true,
    );
    final md = File(lspMarkdown).readAsStringSync();
    final sectionStart = md.indexOf('#### 4.3.5');
    final section = md.substring(
      sectionStart,
      md.indexOf('### 4.4', sectionStart),
    );
    final rows = {
      for (final m in rowRe.allMatches(section))
        m.group(1)!: (int.parse(m.group(2)!), m.group(3) == 'yes'),
    };

    test('the table was parsed (markup shape guard)', () {
      expect(sectionStart, isNonNegative);
      expect(rows, isNotEmpty);
      expect(
        rowRe.allMatches(section).length,
        rows.length,
        reason: 'duplicate code rows in the table',
      );
    });

    test('same set of codes', () {
      expect(rows.keys.toSet(), LsErrorCode.values.map((c) => c.wire).toSet());
    });

    for (final c in LsErrorCode.values) {
      test('${c.wire}: HTTP ${c.httpStatus}, retryable ${c.retryable}', () {
        final row = rows[c.wire];
        expect(row, isNotNull, reason: '${c.wire} missing in LSP-1 4.3.5');
        expect(row!.$1, c.httpStatus, reason: 'HTTP status of ${c.wire}');
        expect(row.$2, c.retryable, reason: 'retryable of ${c.wire}');
      });
    }

    test('protocol constants quoted in LSP-1 4.1 match protocol.dart', () {
      expect(kChunkSize, 4194304);
      expect(md, contains('4,194,304'));
      expect(kMaxJsonBytes, 262144);
      expect(md, contains('262144'));
      expect(kMaxFilesPerSession, 10000);
      expect(md, contains('10,000'));
      expect(kPermissionTimeout, const Duration(seconds: 120));
      expect(md, contains('| Permission timeout | 120 s'));
      expect(kDefaultPort, 53318);
      expect(kPortFallbackMax, 53327);
      expect(md, contains('`53319`-`53327`'));
      expect(kApiPrefix, '/api/v1');
      expect(kChunkRetries, 3);
      expect(kChunkHashHeader, 'x-ls-chunk-sha256');
      expect(kProtocolVersion, '1.0');
    });
  });

  group('JSON produced by a live ApiServer validates', () {
    late Directory dir;
    late LibreShareEngine auto;
    late LibreShareEngine manual;
    late Wire wire;
    late Wire manualWire;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('ls_schema_wire_');
      LibreShareEngine mk(String n, {required bool autoAccept}) =>
          LibreShareEngine(
            self: DeviceInfo(
              deviceId: 'wire-$n',
              alias: 'wire-$n',
              platform: 'linux',
              fingerprint: '',
            ),
            downloadDir: Directory(p.join(dir.path, n)),
            preferredPort: 0,
            autoAccept: autoAccept,
            bindAddress: InternetAddress.loopbackIPv4,
            enableRateLimit: false,
          );
      auto = mk('auto', autoAccept: true);
      manual = mk('manual', autoAccept: false);
      wire = Wire(await auto.start());
      manualWire = Wire(await manual.start());
    });

    tearDown(() async {
      wire.close();
      manualWire.close();
      await auto.dispose(force: true);
      await manual.dispose(force: true);
      dir.deleteSync(recursive: true);
    });

    SessionRequest requestFor(List<int> data, {int port = 0}) => SessionRequest(
      sender: DeviceInfo(
        deviceId: 'wire-sender',
        alias: 'wire-sender',
        platform: 'linux',
        port: port,
      ),
      files: [
        FileItem(
          fileId: 'f1',
          fileName: 'wire.bin',
          size: data.length,
          chunkCount: 1,
          sha256: sha256.convert(data).toString(),
          modified: DateTime.utc(2026, 3, 4, 5, 6, 7),
        ),
      ],
      totalSize: data.length,
    );

    test('a complete transfer: every JSON response conforms', () async {
      final data = List<int>.generate(5000, (i) => i * 7 % 251);

      var (status, body) = await wire.json('GET', '/info');
      expect(status, 200);
      expectValid('device-info', body, 'GET /info');
      expect(body['deviceId'], 'wire-auto');

      (status, body) = await wire.json(
        'POST',
        '/register',
        body: deviceFull.toJson(),
      );
      expect(status, 200);
      expectValid('device-info', body, 'POST /register');

      // A send-only client identifies itself with port 0 (see `ls send`).
      (status, body) = await wire.json(
        'POST',
        '/sessions',
        body: requestFor(data).toJson(),
      );
      expect(status, 200);
      expectValid('session-status', body, 'POST /sessions');
      expect(body['status'], 'IN_PROGRESS');
      final sid = body['sessionId']! as String;
      final tok =
          ((body['acceptedFiles']! as Map)['f1'] as Map)['token']! as String;

      (status, body) = await wire.json('GET', '/sessions/$sid?wait=0');
      expect(status, 200);
      expectValid('session-status', body, 'GET /sessions/{sid}');

      (status, body) = await wire.json(
        'GET',
        '/sessions/$sid/files/f1/state',
        token: tok,
      );
      expect(status, 200);
      expectValid('file-state', body, 'GET .../state');
      expect(body['chunkCount'], 1);

      (status, body) = await wire.putChunk(
        '/sessions/$sid/files/f1/chunks/0',
        data,
        tok,
      );
      expect(status, 200);
      expect(body, {'ack': true, 'index': 0});

      (status, body) = await wire.json(
        'GET',
        '/sessions/$sid/files/f1/state',
        token: tok,
      );
      expectValid('file-state', body, 'GET .../state after chunk');
      expect(body['receivedRanges'], [
        [0, 0],
      ]);

      (status, body) = await wire.json(
        'POST',
        '/sessions/$sid/files/f1/complete',
        token: tok,
      );
      expect(status, 200);
      expectValid('file-verification', body, 'POST .../complete');
      expect(body['sha256'], sha256.convert(data).toString());

      (status, body) = await wire.json('POST', '/sessions/$sid/finish');
      expect(status, 200);
      expectValid('session-status', body, 'POST .../finish');
      expect(body['status'], 'COMPLETED');
    });

    test(
      'PENDING (202), FAILED/REJECTED and cancel responses conform',
      () async {
        final data = List<int>.filled(100, 1);
        var (status, body) = await manualWire.json(
          'POST',
          '/sessions',
          body: requestFor(data).toJson(),
        );
        expect(status, 202);
        expectValid('session-status', body, 'POST /sessions (pending)');
        expect(body['status'], 'PENDING');
        final sid = body['sessionId']! as String;

        await manual.receiver.reject(sid);
        (status, body) = await manualWire.json('GET', '/sessions/$sid?wait=0');
        expect(status, 200);
        expectValid('session-status', body, 'GET (rejected)');
        expect(body['status'], 'FAILED');
        expect(body['failureReason'], 'REJECTED');

        // A cancelled session answers later calls with 410 CANCELLED.
        (status, body) = await wire.json(
          'POST',
          '/sessions',
          body: requestFor(data).toJson(),
        );
        final sid2 = body['sessionId']! as String;
        (status, body) = await wire.json('POST', '/sessions/$sid2/cancel');
        expect(status, 200);
        (status, body) = await wire.json('GET', '/sessions/$sid2?wait=0');
        expect(status, 410);
        expectValid('error-envelope', body, '410');
        expect(body['error'], containsPair('code', 'CANCELLED'));
      },
    );

    test('error responses conform for the common failure modes', () async {
      final data = List<int>.filled(10, 2);

      var (status, body) = await wire.json('GET', '/sessions/nope?wait=0');
      expect(status, 404);
      expectValid('error-envelope', body, '404');

      (status, body) = await wire.json('DELETE', '/info');
      expect(status, 404, reason: 'wrong method is 404, no 405');
      expectValid('error-envelope', body, 'wrong method');

      (status, body) = await wire.json(
        'POST',
        '/sessions',
        body: <String, Object?>{},
      );
      expect(status, 400);
      expectValid('error-envelope', body, '400');

      (status, body) = await wire.json(
        'POST',
        '/register',
        body: {...deviceFull.toJson(), 'v': '2.0'},
      );
      expect(status, 426);
      expectValid('error-envelope', body, '426');
      expect(body['supported'], ['1']);

      (status, body) = await wire.json(
        'POST',
        '/sessions',
        body: {...requestFor(data).toJson(), 'totalSize': 999},
      );
      expect(status, 400, reason: 'sizes do not sum to totalSize');
      expectValid('error-envelope', body, '400 totalSize');

      (status, body) = await wire.json(
        'POST',
        '/sessions',
        body: requestFor(data).toJson(),
      );
      final sid = body['sessionId']! as String;
      (status, body) = await wire.json(
        'GET',
        '/sessions/$sid/files/f1/state',
        token: 'wrong-token',
      );
      expect(status, 401);
      expectValid('error-envelope', body, '401');
      expect(body['error'], containsPair('code', 'TOKEN_INVALID'));

      (status, body) = await wire.json('POST', '/sessions/$sid/finish');
      expect(status, 409, reason: 'file not verified yet');
      expectValid('error-envelope', body, '409');
    });
  });
}
