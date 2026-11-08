import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' as pc;

import '../security/crypto_primitives.dart';
import 'ble_messages.dart';

const String kBleTranscriptPrefix = 'LSBLE1';
const String kBleKeysInfo = 'LSBLE1-keys';
const String kBleAuthDomainCentral = 'LSBLE1-AUTH-C';
const String kBleAuthDomainPeripheral = 'LSBLE1-AUTH-P';

/// Ephemeral key pair for LS-BLE/1 key agreement.
class BleEphemeralKeyPair {
  BleEphemeralKeyPair._(this.privateKey, this.publicKey, this.publicKeyBase64);

  final pc.ECPrivateKey privateKey;
  final pc.ECPublicKey publicKey;
  final String publicKeyBase64;

  @override
  String toString() => 'BleEphemeralKeyPair(pub: $publicKeyBase64)';

  /// Generates a random ephemeral P-256 key pair.
  factory BleEphemeralKeyPair.generate([Random? random]) {
    final params = pc.ECDomainParameters('prime256v1');
    final rnd = random ?? Random.secure();
    final secureRandom = pc.SecureRandom('Fortuna')
      ..seed(
        pc.KeyParameter(
          Uint8List.fromList(List.generate(32, (_) => rnd.nextInt(256))),
        ),
      );

    final keyGen = pc.ECKeyGenerator();
    keyGen.init(
      pc.ParametersWithRandom(
        pc.ECKeyGeneratorParameters(params),
        secureRandom,
      ),
    );
    final pair = keyGen.generateKeyPair();

    final priv = pair.privateKey;
    final pub = pair.publicKey;
    final pubBytes = pub.Q!.getEncoded(false); // uncompressed 65 bytes
    return BleEphemeralKeyPair._(priv, pub, base64Encode(pubBytes));
  }

  /// Calculates the shared secret using ECDH agreement against peer's base64 uncompressed public key.
  Uint8List calculateSharedSecret(String peerPublicKeyBase64) {
    final params = pc.ECDomainParameters('prime256v1');
    final peerBytes = base64Decode(peerPublicKeyBase64);
    final peerQ = params.curve.decodePoint(peerBytes);
    final peerPub = pc.ECPublicKey(peerQ, params);

    final agreement = pc.ECDHBasicAgreement();
    agreement.init(privateKey);
    final secretBigInt = agreement.calculateAgreement(peerPub);

    // Convert secret BigInt to fixed 32-byte array
    final raw = secretBigInt.toRadixString(16).padLeft(64, '0');
    final bytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      bytes[i] = int.parse(raw.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }
}

/// Generates a random 16-byte base64 nonce.
String generateBleNonce([Random? random]) {
  final rnd = random ?? Random.secure();
  final bytes = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    bytes[i] = rnd.nextInt(256);
  }
  return base64Encode(bytes);
}

/// Computes the 32-byte handshake transcript hash th = SHA256("LSBLE1" || M1 || M2).
Uint8List computeTranscriptHash(BleM1 m1, BleM2 m2) {
  final m1Bytes = utf8.encode(m1.encode());
  final m2Bytes = utf8.encode(m2.encode());
  final bb = BytesBuilder()
    ..add(utf8.encode(kBleTranscriptPrefix))
    ..add(m1Bytes)
    ..add(m2Bytes);
  return sha256Bytes(bb.toBytes());
}

/// Derives directional 32-byte keys kC2P and kP2C via HKDF-SHA256(ss, salt=th, info="LSBLE1-keys", 64).
(Uint8List kC2P, Uint8List kP2C) deriveChannelKeys({
  required List<int> sharedSecret,
  required List<int> transcriptHash,
}) {
  final keyMaterial = hkdfSha256(
    ikm: sharedSecret,
    salt: transcriptHash,
    info: utf8.encode(kBleKeysInfo),
    length: 64,
  );
  final kC2P = Uint8List.sublistView(keyMaterial, 0, 32);
  final kP2C = Uint8List.sublistView(keyMaterial, 32, 64);
  return (kC2P, kP2C);
}

/// Directional authenticated encryption cipher for GATT messages.
class BleAeadCipher {
  BleAeadCipher({
    required this.key,
    required this.direction,
    required this.transcriptHash,
  }) {
    if (key.length != 32) {
      throw ArgumentError.value(key.length, 'key', 'AES key must be 32 bytes');
    }
    if (transcriptHash.length != 32) {
      throw ArgumentError.value(
        transcriptHash.length,
        'transcriptHash',
        'transcriptHash must be 32 bytes',
      );
    }
  }

  final Uint8List key;
  final int direction; // 1 = Central->Peripheral, 2 = Peripheral->Central
  final Uint8List transcriptHash;
  int _counter = 0;
  int _lastReceivedCounter = -1;

  @override
  String toString() => 'BleAeadCipher(dir: $direction, counter: $_counter)';

  /// Seals [plaintext] using AES-256-GCM with nonce = 4-byte direction || 8-byte counter, AAD = transcriptHash.
  Uint8List seal(List<int> plaintext) {
    final inBytes = plaintext is Uint8List
        ? plaintext
        : Uint8List.fromList(plaintext);
    final nonce = _buildNonce(direction, _counter++);
    final cipher = pc.GCMBlockCipher(pc.AESEngine());
    final params = pc.AEADParameters(
      pc.KeyParameter(key),
      128,
      nonce,
      transcriptHash,
    );
    cipher.init(true, params);

    final out = Uint8List(cipher.getOutputSize(inBytes.length));
    final len = cipher.processBytes(inBytes, 0, inBytes.length, out, 0);
    final finalLen = cipher.doFinal(out, len);
    final ciphertextWithTag = Uint8List.sublistView(out, 0, len + finalLen);

    // Prefix 8-byte counter so receiver verifies monotonically increasing order
    final result = BytesBuilder()
      ..add(nonce.sublist(4)) // 8-byte counter
      ..add(ciphertextWithTag);
    return result.toBytes();
  }

  /// Opens [payload] (8-byte counter + ciphertext + 16-byte tag) and verifies AAD.
  Uint8List open(List<int> payload) {
    if (payload.length < 8 + 16) {
      throw const FormatException('Ciphertext payload too short for AES-GCM');
    }

    final counterBytes = ByteData.sublistView(
      Uint8List.fromList(payload.sublist(0, 8)),
    );
    final counter = counterBytes.getUint64(0, Endian.big);

    if (counter <= _lastReceivedCounter) {
      throw FormatException(
        'Replay detected: counter $counter <= last seen $_lastReceivedCounter',
      );
    }

    final nonce = _buildNonce(direction, counter);
    final ciphertextWithTag = payload.sublist(8);
    final ctBytes = ciphertextWithTag is Uint8List
        ? ciphertextWithTag
        : Uint8List.fromList(ciphertextWithTag);

    final cipher = pc.GCMBlockCipher(pc.AESEngine());
    final params = pc.AEADParameters(
      pc.KeyParameter(key),
      128,
      nonce,
      transcriptHash,
    );
    cipher.init(false, params);

    try {
      final out = Uint8List(cipher.getOutputSize(ctBytes.length));
      final len = cipher.processBytes(ctBytes, 0, ctBytes.length, out, 0);
      final finalLen = cipher.doFinal(out, len);
      _lastReceivedCounter = counter;
      return Uint8List.sublistView(out, 0, len + finalLen);
    } on Object catch (e) {
      throw FormatException('GCM authentication tag verification failed: $e');
    }
  }

  Uint8List _buildNonce(int dir, int count) {
    final bd = ByteData(12);
    bd.setUint32(0, dir, Endian.big);
    bd.setUint64(4, count, Endian.big);
    return bd.buffer.asUint8List();
  }
}
