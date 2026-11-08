// Schema validation tests for rendezvous records and wire envelopes.
library;

import 'dart:convert';
import 'dart:io';

import 'package:json_schema/json_schema.dart';
import 'package:libreshare_core/libreshare_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String _findRepoRoot() {
  var dir = Directory.current.absolute;
  while (true) {
    if (File(p.join(dir.path, 'pubspec.yaml')).existsSync() &&
        Directory(p.join(dir.path, 'docs')).existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('Repository root not found from ${Directory.current}');
    }
    dir = parent;
  }
}

void main() {
  group('Rendezvous Schema Conformance (Wave 0)', () {
    late String root;
    late JsonSchema recordSchema;
    late JsonSchema envelopeSchema;

    setUpAll(() {
      root = _findRepoRoot();
      final recordSchemaFile = File(
        p.join(
          root,
          'docs',
          'protocol',
          'rendezvous',
          'schemas',
          'rendezvous-record.schema.json',
        ),
      );
      final envelopeSchemaFile = File(
        p.join(
          root,
          'docs',
          'protocol',
          'rendezvous',
          'schemas',
          'rendezvous-envelope.schema.json',
        ),
      );

      expect(
        recordSchemaFile.existsSync(),
        isTrue,
        reason: 'Record schema file must exist',
      );
      expect(
        envelopeSchemaFile.existsSync(),
        isTrue,
        reason: 'Envelope schema file must exist',
      );

      recordSchema = JsonSchema.create(
        jsonDecode(recordSchemaFile.readAsStringSync()) as Object,
      );
      envelopeSchema = JsonSchema.create(
        jsonDecode(envelopeSchemaFile.readAsStringSync()) as Object,
      );
    });

    test(
      'PresenceRecord JSON validates against rendezvous-record.schema.json',
      () {
        const presence = PresenceRecord(
          seq: 1,
          issuedAt: 1799284800000,
          ttl: 300,
          candidates: [
            {'kind': 'directIpv6', 'host': '2001:db8::1', 'port': 53330},
            {'kind': 'mappedIpv4', 'host': '198.51.100.1', 'port': 53330},
          ],
          caps: ['rdv1'],
        );

        final res = recordSchema.validate(presence.toJson());
        expect(
          res.isValid,
          isTrue,
          reason: res.errors.map((e) => e.message).join('; '),
        );
      },
    );

    test('OfferRecord and ReplyRecord JSON validate against rendezvous-record.schema.json', () {
      const offer = OfferRecord(
        seq: 2,
        issuedAt: 1799284810000,
        offerId: 'off_9f82bc710a',
        manifest: {'sessionId': 's1', 'totalSize': 100},
        tunnelOffer: {'provider': 'cloudflare', 'url': 'https://example.com'},
        candidates: [
          {'kind': 'directIpv6', 'host': '2001:db8::1', 'port': 53330},
        ],
      );
      final resOffer = recordSchema.validate(offer.toJson());
      expect(
        resOffer.isValid,
        isTrue,
        reason: resOffer.errors.map((e) => e.message).join('; '),
      );

      const reply = ReplyRecord(
        seq: 3,
        issuedAt: 1799284815000,
        offerId: 'off_9f82bc710a',
        decision: 'accept',
        sealedAck: 'ack_token_123',
      );
      final resReply = recordSchema.validate(reply.toJson());
      expect(
        resReply.isValid,
        isTrue,
        reason: resReply.errors.map((e) => e.message).join('; '),
      );
    });

    test(
      'ProbeRecord, RevokeRecord, PairHelloRecord, PairAcceptRecord validate',
      () {
        final probe = ProbeRecord(
          seq: 4,
          issuedAt: 1799284820000,
          nonce: 'n123',
        );
        expect(recordSchema.validate(probe.toJson()).isValid, isTrue);

        final revoke = RevokeRecord(
          seq: 5,
          issuedAt: 1799284825000,
          revokedAt: 1799284825000,
        );
        expect(recordSchema.validate(revoke.toJson()).isValid, isTrue);

        final hello = PairHelloRecord(
          seq: 6,
          issuedAt: 1799284830000,
          scannerFingerprint: 'A' * 64,
          nonce: 'nonce1',
          mac: 'mac1',
        );
        expect(recordSchema.validate(hello.toJson()).isValid, isTrue);

        final accept = PairAcceptRecord(
          seq: 7,
          issuedAt: 1799284835000,
          inviterFingerprint: 'B' * 64,
          nonce: 'nonce2',
          mac: 'mac2',
        );
        expect(recordSchema.validate(accept.toJson()).isValid, isTrue);
      },
    );

    test('Negative control: Record missing required discriminator fails validation', () {
      final invalid = {'v': 1, 'seq': 1, 'issuedAt': 12345678};
      final res = recordSchema.validate(invalid);
      expect(res.isValid, isFalse);
    });

    test('Rendezvous envelope JSON validates against rendezvous-envelope.schema.json', () {
      final envelopeJson = {
        'kind': 20059,
        'pubkey': 'a' * 64,
        'created_at': 1799284800,
        'tags': [
          ['p', 'b' * 64],
          ['expiration', '1799285100'],
        ],
        'content': 'base64url_encrypted_payload_here',
        'id': 'c' * 64,
        'sig': 'd' * 128,
      };

      final res = envelopeSchema.validate(envelopeJson);
      expect(
        res.isValid,
        isTrue,
        reason: res.errors.map((e) => e.message).join('; '),
      );
    });

    test('Negative control: Envelope with invalid pubkey hex length fails validation', () {
      final invalidEnvelope = {
        'kind': 20059,
        'pubkey': 'short', // invalid: requires 64 hex
        'created_at': 1799284800,
        'tags': [],
        'content': 'payload',
        'id': 'c' * 64,
        'sig': 'd' * 128,
      };

      final res = envelopeSchema.validate(invalidEnvelope);
      expect(res.isValid, isFalse);
    });
  });
}
