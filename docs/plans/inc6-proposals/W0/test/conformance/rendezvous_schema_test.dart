// Conformance tests for LSP-R1 rendezvous JSON schemas (draft 2020-12).
library;

import 'dart:convert';
import 'dart:io';

import 'package:json_schema/json_schema.dart';
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

final String schemasDir =
    _findUp(p.join('docs', 'protocol', 'rendezvous', 'schemas')) ??
    (throw StateError('docs/protocol/rendezvous/schemas not found'));

Map<String, Object?> _readJson(String path) =>
    (jsonDecode(File(path).readAsStringSync()) as Map).cast<String, Object?>();

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
  for (final e in _docs.entries) {
    _schemas[e.key] = JsonSchema.create(
      e.value,
      schemaVersion: SchemaVersion.draft2020_12,
    );
  }
}

void main() {
  _loadSchemas();

  group('LSP-R1 rendezvous schemas conformance', () {
    test('both rendezvous schemas are present in docs/protocol/rendezvous/schemas/', () {
      expect(_docs.keys.toSet(), {'rendezvous-envelope', 'rendezvous-record'});
    });

    test(
      'draft 2020-12, unique \$id ending in file name, and valid examples',
      () {
        expect(_byId.length, _docs.length, reason: 'duplicate \$id found');
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
        test('${e.key}: example #$i validates against schema', () {
          final res = _schemas[e.key]!.validate(examples[i]);
          expect(
            res.isValid,
            isTrue,
            reason:
                '${e.key} example #$i: ${res.errors.map((err) => err.message).join('; ')}',
          );
        });
      }
    }

    test('negative control: rendezvous-envelope rejects non-hex pubkey', () {
      final invalidEnvelope = {
        'kind': 20059,
        'pubkey': 'not-a-valid-hex-key',
        'created_at': 1799284800,
        'tags': [],
        'content': 'data',
        'id': 'a' * 64,
        'sig': 'b' * 128,
      };
      final res = _schemas['rendezvous-envelope']!.validate(invalidEnvelope);
      expect(res.isValid, isFalse);
    });

    test(
      'negative control: rendezvous-record rejects missing discriminator type',
      () {
        final invalidRecord = {'v': 1, 'seq': 1, 'issuedAt': 1799284800000};
        final res = _schemas['rendezvous-record']!.validate(invalidRecord);
        expect(res.isValid, isFalse);
      },
    );
  });
}
