// NIP-01 Nostr event serialization, ID calculation, and frame parsing.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../security/crypto_primitives.dart';
import 'bip340.dart';

/// Concrete Nostr event per NIP-01 specification.
class NostrEvent {
  const NostrEvent({
    required this.id,
    required this.pubkey,
    required this.createdAt,
    required this.kind,
    required this.tags,
    required this.content,
    required this.sig,
  });

  /// SHA-256 hash of the serialized event in 64-char lowercase hex.
  final String id;

  /// 32-byte BIP-340 public key in 64-char lowercase hex.
  final String pubkey;

  /// Timestamp in seconds since Unix epoch.
  final int createdAt;

  /// Integer event kind (e.g. 20059 for ephemeral envelopes).
  final int kind;

  /// List of tag arrays (e.g. [["p", "<channel_id_hex>"]]).
  final List<List<String>> tags;

  /// String payload (base64url encrypted envelope for LSP-R1).
  final String content;

  /// 64-byte BIP-340 Schnorr signature in 128-char lowercase hex.
  final String sig;

  /// Computes the canonical NIP-01 serialized JSON string:
  /// `[0, pubkey, created_at, kind, tags, content]`.
  static String serializeCanonical({
    required String pubkey,
    required int createdAt,
    required int kind,
    required List<List<String>> tags,
    required String content,
  }) {
    return jsonEncode([
      0,
      pubkey.toLowerCase(),
      createdAt,
      kind,
      tags,
      content,
    ]);
  }

  /// Computes the 64-char hex event ID from canonical serialization.
  static String computeEventId({
    required String pubkey,
    required int createdAt,
    required int kind,
    required List<List<String>> tags,
    required String content,
  }) {
    final serialized = serializeCanonical(
      pubkey: pubkey,
      createdAt: createdAt,
      kind: kind,
      tags: tags,
      content: content,
    );
    final hash = crypto.sha256.convert(utf8.encode(serialized)).bytes;
    return hexOf(hash).toLowerCase();
  }

  /// Creates and signs a new [NostrEvent] using private key [sk].
  factory NostrEvent.createAndSign({
    required BigInt sk,
    required int kind,
    required List<List<String>> tags,
    required String content,
    int? createdAt,
    Uint8List? auxRand,
  }) {
    final pkBytes = getBip340PublicKey(sk);
    final pubkeyHex = hexOf(pkBytes).toLowerCase();
    final nowSec =
        createdAt ?? (DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000);

    final eventIdHex = computeEventId(
      pubkey: pubkeyHex,
      createdAt: nowSec,
      kind: kind,
      tags: tags,
      content: content,
    );

    final idBytes = Uint8List.fromList(
      List.generate(
        32,
        (i) => int.parse(eventIdHex.substring(i * 2, i * 2 + 2), radix: 16),
      ),
    );

    final sigBytes = signBip340(sk: sk, message: idBytes, auxRand: auxRand);
    final sigHex = hexOf(sigBytes).toLowerCase();

    return NostrEvent(
      id: eventIdHex,
      pubkey: pubkeyHex,
      createdAt: nowSec,
      kind: kind,
      tags: tags,
      content: content,
      sig: sigHex,
    );
  }

  /// Verifies both the event ID hash and the BIP-340 Schnorr signature.
  bool verify() {
    final expectedId = computeEventId(
      pubkey: pubkey,
      createdAt: createdAt,
      kind: kind,
      tags: tags,
      content: content,
    );
    if (id.toLowerCase() != expectedId.toLowerCase()) {
      return false;
    }

    if (pubkey.length != 64 || sig.length != 128) {
      return false;
    }

    try {
      final pkBytes = Uint8List.fromList(
        List.generate(
          32,
          (i) => int.parse(pubkey.substring(i * 2, i * 2 + 2), radix: 16),
        ),
      );
      final idBytes = Uint8List.fromList(
        List.generate(
          32,
          (i) => int.parse(id.substring(i * 2, i * 2 + 2), radix: 16),
        ),
      );
      final sigBytes = Uint8List.fromList(
        List.generate(
          64,
          (i) => int.parse(sig.substring(i * 2, i * 2 + 2), radix: 16),
        ),
      );

      return verifyBip340(
        pubKeyBytes: pkBytes,
        message: idBytes,
        sig: sigBytes,
      );
    } catch (_) {
      return false;
    }
  }

  /// Converts event to NIP-01 JSON map.
  Map<String, Object?> toJson() => {
    'id': id,
    'pubkey': pubkey,
    'created_at': createdAt,
    'kind': kind,
    'tags': tags,
    'content': content,
    'sig': sig,
  };

  /// Parses event from NIP-01 JSON map.
  factory NostrEvent.fromJson(Map<String, dynamic> json) {
    return NostrEvent(
      id: json['id'] as String? ?? '',
      pubkey: json['pubkey'] as String? ?? '',
      createdAt: json['created_at'] as int? ?? 0,
      kind: json['kind'] as int? ?? 0,
      tags:
          (json['tags'] as List?)
              ?.map((t) => (t as List).cast<String>().toList())
              .toList() ??
          const [],
      content: json['content'] as String? ?? '',
      sig: json['sig'] as String? ?? '',
    );
  }
}
