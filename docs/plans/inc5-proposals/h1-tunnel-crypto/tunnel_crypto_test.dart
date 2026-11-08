import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libreshare_core/src/security/tunnel_crypto.dart';
import 'package:test/test.dart';

Uint8List _hexToBytes(String hex) {
  final result = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < result.length; i++) {
    result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return result;
}

void main() {
  group('TunnelCrypto constants & exception format', () {
    test('constants match contract', () {
      expect(kTunnelRootKeyBytes, 32);
      expect(kTunnelNonceBytes, 12);
      expect(kTunnelTagBytes, 16);
      expect(kTunnelOverheadBytes, 28);
      expect(kTunnelManifestFileIndex, 0xFFFFFFFF);
      expect(kTunnelMaxSealsPerKey, 1 << 24);
    });

    test(
      'TunnelCryptoException toString contains only error.name, never secrets',
      () {
        for (final err in TunnelCryptoError.values) {
          final ex = TunnelCryptoException(err);
          expect(ex.toString(), 'TunnelCryptoException(${err.name})');
          expect(ex.error, err);
        }
      },
    );

    test('TunnelKeys toString is redacted', () {
      final keys = TunnelKeys.fromRootKey(Uint8List(32));
      expect(keys.toString(), 'TunnelKeys(redacted)');
    });
  });

  group('TunnelKeys initialization and derivation', () {
    test('rootKey must be exactly 32 bytes', () {
      expect(
        () => TunnelKeys.fromRootKey(Uint8List(31)),
        throwsA(
          isA<TunnelCryptoException>().having(
            (e) => e.error,
            'error',
            TunnelCryptoError.badKeyLength,
          ),
        ),
      );
      expect(
        () => TunnelKeys.fromRootKey(Uint8List(33)),
        throwsA(
          isA<TunnelCryptoException>().having(
            (e) => e.error,
            'error',
            TunnelCryptoError.badKeyLength,
          ),
        ),
      );
      expect(
        () => TunnelKeys.fromRootKey(Uint8List(0)),
        throwsA(
          isA<TunnelCryptoException>().having(
            (e) => e.error,
            'error',
            TunnelCryptoError.badKeyLength,
          ),
        ),
      );
    });

    test('shareId returns a fresh copy of 16 bytes on each call', () {
      final keys = TunnelKeys.fromRootKey(Uint8List(32));
      final sid1 = keys.shareId;
      final sid2 = keys.shareId;
      expect(sid1.length, 16);
      expect(sid2.length, 16);
      expect(sid1, equals(sid2));
      expect(identical(sid1, sid2), isFalse);
      sid1[0] ^= 0xFF;
      expect(keys.shareId[0], isNot(sid1[0]));
    });

    test('initial sealCount is 0 and default maxSeals is 2^24', () {
      final keys = TunnelKeys.fromRootKey(Uint8List(32));
      expect(keys.sealCount, 0);
    });
  });

  const String _kVectorsJson = r'''{
  "root_key_hex": "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
  "share_id_hex": "948a346d449a3b385f37a6ebed1af756",
  "k_man_hex": "e5c06a21ada4f0acb117c961bbd4a0381f14b4bc518f1c9166b6bc8e1b24ea1f",
  "k_data_hex": "b8335c8a043811c1092b543ddc54bd36f551e6035b291a0474aa00aae015a7c0",
  "k_ack_hex": "3a5ebaa68b21bdf98f345953d7686cc00ee255e3541906ed0cef7b304ca5091d",
  "claim_hex": "6465666768696a6b6c6d6e6f70717273",
  "sas": "390324",
  "manifest": {
    "nonce_hex": "0a0b0c0d0e0f101112131415",
    "plaintext_hex": "74657374206d616e6966657374207061796c6f6164",
    "aad_hex": "4c53503101948a346d449a3b385f37a6ebed1af756ffffffff00000000000000000000000000000015",
    "sealed_hex": "0a0b0c0d0e0f1011121314151277c4381afa4c762a9d87681767ae37af93e4f99ea57848c1cb69711431c7755b589b7a1f"
  },
  "chunk": {
    "file_index": 0,
    "chunk_index": 1,
    "nonce_hex": "1415161718191a1b1c1d1e1f",
    "plaintext_hex": "74657374206368756e6b207061796c6f6164207769746820736f6d6520617262697472617279206279746573",
    "aad_hex": "4c53503102948a346d449a3b385f37a6ebed1af756000000000000000000000001000000000000002c",
    "sealed_hex": "1415161718191a1b1c1d1e1f858b8e9b262ca65312cc3429bd63f261e3b2c99193aa65953d04a3c8e926bd7afa0f17f54f81296289915e94b89e721074e2cea45a3ab8f72bbd8572"
  },
  "ack": {
    "file_index": 0,
    "chunk_index": 1,
    "nonce_hex": "1e1f20212223242526272829",
    "plaintext_hex": "61636b3a6f6b",
    "aad_hex": "4c53503103948a346d449a3b385f37a6ebed1af7560000000000000000000000010000000000000006",
    "sealed_hex": "1e1f2021222324252627282977d9205f1e3a418b61d6bbff62dbbaf3b28efaad5889"
  }
}''';

  group('Known-answer vectors', () {
    late Map<String, dynamic> vectors;

    setUpAll(() {
      final file = File('test/conformance/fixtures/tunnel_crypto_vectors.json');
      if (file.existsSync()) {
        vectors = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      } else {
        vectors = jsonDecode(_kVectorsJson) as Map<String, dynamic>;
      }
    });

    test(
      'shareId matches vector derived by independent python3 implementation',
      () {
        final rootKey = _hexToBytes(vectors['root_key_hex'] as String);
        final keys = TunnelKeys.fromRootKey(rootKey);
        expect(
          keys.shareId,
          equals(_hexToBytes(vectors['share_id_hex'] as String)),
        );
      },
    );

    test('SAS matches vector', () {
      final rootKey = _hexToBytes(vectors['root_key_hex'] as String);
      final keys = TunnelKeys.fromRootKey(rootKey);
      final claim = _hexToBytes(vectors['claim_hex'] as String);
      expect(keys.sas(claim), equals(vectors['sas'] as String));
    });

    test('manifest sealWithNonce matches python3 vector and opens cleanly', () {
      final rootKey = _hexToBytes(vectors['root_key_hex'] as String);
      final keys = TunnelKeys.fromRootKey(rootKey);
      final manVec = vectors['manifest'] as Map<String, dynamic>;
      final nonce = _hexToBytes(manVec['nonce_hex'] as String);
      final plain = _hexToBytes(manVec['plaintext_hex'] as String);
      final expectedSealed = _hexToBytes(manVec['sealed_hex'] as String);

      final sealed = keys.sealWithNonce(TunnelPurpose.manifest, plain, nonce);
      expect(sealed, equals(expectedSealed));

      final opened = keys.open(TunnelPurpose.manifest, sealed);
      expect(opened, equals(plain));
    });

    test('chunk sealWithNonce matches python3 vector and opens cleanly', () {
      final rootKey = _hexToBytes(vectors['root_key_hex'] as String);
      final keys = TunnelKeys.fromRootKey(rootKey);
      final chunkVec = vectors['chunk'] as Map<String, dynamic>;
      final nonce = _hexToBytes(chunkVec['nonce_hex'] as String);
      final plain = _hexToBytes(chunkVec['plaintext_hex'] as String);
      final expectedSealed = _hexToBytes(chunkVec['sealed_hex'] as String);

      final sealed = keys.sealWithNonce(
        TunnelPurpose.chunk,
        plain,
        nonce,
        fileIndex: chunkVec['file_index'] as int,
        chunkIndex: chunkVec['chunk_index'] as int,
      );
      expect(sealed, equals(expectedSealed));

      final opened = keys.open(
        TunnelPurpose.chunk,
        sealed,
        fileIndex: chunkVec['file_index'] as int,
        chunkIndex: chunkVec['chunk_index'] as int,
      );
      expect(opened, equals(plain));
    });

    test('ack sealWithNonce matches python3 vector and opens cleanly', () {
      final rootKey = _hexToBytes(vectors['root_key_hex'] as String);
      final keys = TunnelKeys.fromRootKey(rootKey);
      final ackVec = vectors['ack'] as Map<String, dynamic>;
      final nonce = _hexToBytes(ackVec['nonce_hex'] as String);
      final plain = _hexToBytes(ackVec['plaintext_hex'] as String);
      final expectedSealed = _hexToBytes(ackVec['sealed_hex'] as String);

      final sealed = keys.sealWithNonce(
        TunnelPurpose.ack,
        plain,
        nonce,
        fileIndex: ackVec['file_index'] as int,
        chunkIndex: ackVec['chunk_index'] as int,
      );
      expect(sealed, equals(expectedSealed));

      final opened = keys.open(
        TunnelPurpose.ack,
        sealed,
        fileIndex: ackVec['file_index'] as int,
        chunkIndex: ackVec['chunk_index'] as int,
      );
      expect(opened, equals(plain));
    });
  });

  group('Index validation rules (badInput)', () {
    late TunnelKeys keys;

    setUp(() {
      keys = TunnelKeys.fromRootKey(Uint8List(32));
    });

    test('manifest: fileIndex or chunkIndex non-null throws badInput', () {
      expect(
        () => keys.seal(TunnelPurpose.manifest, [1, 2, 3], fileIndex: 0),
        throwsA(
          isA<TunnelCryptoException>().having(
            (e) => e.error,
            'error',
            TunnelCryptoError.badInput,
          ),
        ),
      );
      expect(
        () => keys.seal(TunnelPurpose.manifest, [1, 2, 3], chunkIndex: 0),
        throwsA(
          isA<TunnelCryptoException>().having(
            (e) => e.error,
            'error',
            TunnelCryptoError.badInput,
          ),
        ),
      );
      expect(
        () => keys.open(TunnelPurpose.manifest, Uint8List(30), fileIndex: 0),
        throwsA(
          isA<TunnelCryptoException>().having(
            (e) => e.error,
            'error',
            TunnelCryptoError.badInput,
          ),
        ),
      );
    });

    test('chunk: missing fileIndex or chunkIndex throws badInput', () {
      expect(
        () => keys.seal(TunnelPurpose.chunk, [1, 2, 3], fileIndex: 0),
        throwsA(
          isA<TunnelCryptoException>().having(
            (e) => e.error,
            'error',
            TunnelCryptoError.badInput,
          ),
        ),
      );
      expect(
        () => keys.seal(TunnelPurpose.chunk, [1, 2, 3], chunkIndex: 0),
        throwsA(
          isA<TunnelCryptoException>().having(
            (e) => e.error,
            'error',
            TunnelCryptoError.badInput,
          ),
        ),
      );
      expect(
        () => keys.seal(TunnelPurpose.chunk, [1, 2, 3]),
        throwsA(
          isA<TunnelCryptoException>().having(
            (e) => e.error,
            'error',
            TunnelCryptoError.badInput,
          ),
        ),
      );
    });

    test('chunk: out of range fileIndex (>= 10000 or < 0) throws badInput', () {
      expect(
        () => keys.seal(
          TunnelPurpose.chunk,
          [1, 2, 3],
          fileIndex: -1,
          chunkIndex: 0,
        ),
        throwsA(
          isA<TunnelCryptoException>().having(
            (e) => e.error,
            'error',
            TunnelCryptoError.badInput,
          ),
        ),
      );
      expect(
        () => keys.seal(
          TunnelPurpose.chunk,
          [1, 2, 3],
          fileIndex: 10000,
          chunkIndex: 0,
        ),
        throwsA(
          isA<TunnelCryptoException>().having(
            (e) => e.error,
            'error',
            TunnelCryptoError.badInput,
          ),
        ),
      );
      expect(
        () => keys.seal(
          TunnelPurpose.chunk,
          [1, 2, 3],
          fileIndex: 0,
          chunkIndex: -1,
        ),
        throwsA(
          isA<TunnelCryptoException>().having(
            (e) => e.error,
            'error',
            TunnelCryptoError.badInput,
          ),
        ),
      );
    });

    test(
      'ack: allows standard chunk range and (0xFFFFFFFF, 0) for final ack',
      () {
        final sealedFinal = keys.seal(
          TunnelPurpose.ack,
          [1, 2, 3],
          fileIndex: 0xFFFFFFFF,
          chunkIndex: 0,
        );
        expect(
          keys.open(
            TunnelPurpose.ack,
            sealedFinal,
            fileIndex: 0xFFFFFFFF,
            chunkIndex: 0,
          ),
          [1, 2, 3],
        );

        // Invalid ack indices
        expect(
          () => keys.seal(
            TunnelPurpose.ack,
            [1, 2, 3],
            fileIndex: 0xFFFFFFFF,
            chunkIndex: 1,
          ),
          throwsA(
            isA<TunnelCryptoException>().having(
              (e) => e.error,
              'error',
              TunnelCryptoError.badInput,
            ),
          ),
        );
        expect(
          () => keys.seal(
            TunnelPurpose.ack,
            [1, 2, 3],
            fileIndex: 10000,
            chunkIndex: 0,
          ),
          throwsA(
            isA<TunnelCryptoException>().having(
              (e) => e.error,
              'error',
              TunnelCryptoError.badInput,
            ),
          ),
        );
      },
    );

    test('open with sealed.length < 28 throws badInput', () {
      expect(
        () => keys.open(TunnelPurpose.manifest, Uint8List(27)),
        throwsA(
          isA<TunnelCryptoException>().having(
            (e) => e.error,
            'error',
            TunnelCryptoError.badInput,
          ),
        ),
      );
      expect(
        () => keys.open(
          TunnelPurpose.chunk,
          Uint8List(0),
          fileIndex: 0,
          chunkIndex: 0,
        ),
        throwsA(
          isA<TunnelCryptoException>().having(
            (e) => e.error,
            'error',
            TunnelCryptoError.badInput,
          ),
        ),
      );
    });

    test('sas with claim length != 16 throws badInput', () {
      expect(
        () => keys.sas(Uint8List(15)),
        throwsA(
          isA<TunnelCryptoException>().having(
            (e) => e.error,
            'error',
            TunnelCryptoError.badInput,
          ),
        ),
      );
      expect(
        () => keys.sas(Uint8List(17)),
        throwsA(
          isA<TunnelCryptoException>().having(
            (e) => e.error,
            'error',
            TunnelCryptoError.badInput,
          ),
        ),
      );
    });
  });

  group('Tamper and Cross-Purpose Refusal (authenticationFailed)', () {
    late TunnelKeys keysA;
    late TunnelKeys keysB;

    setUp(() {
      keysA = TunnelKeys.fromRootKey(
        Uint8List.fromList(List.generate(32, (i) => i)),
      );
      keysB = TunnelKeys.fromRootKey(
        Uint8List.fromList(List.generate(32, (i) => i ^ 0xFF)),
      );
    });

    test(
      'tampering any byte of sealed message throws authenticationFailed',
      () {
        final plain = Uint8List.fromList(utf8.encode('super secret payload'));
        final sealed = keysA.seal(
          TunnelPurpose.chunk,
          plain,
          fileIndex: 1,
          chunkIndex: 2,
        );

        for (var i = 0; i < sealed.length; i++) {
          final tampered = Uint8List.fromList(sealed);
          tampered[i] ^= 0x01;
          expect(
            () => keysA.open(
              TunnelPurpose.chunk,
              tampered,
              fileIndex: 1,
              chunkIndex: 2,
            ),
            throwsA(
              isA<TunnelCryptoException>().having(
                (e) => e.error,
                'error',
                TunnelCryptoError.authenticationFailed,
              ),
            ),
            reason: 'byte index $i was tampered',
          );
        }
      },
    );

    test('wrong key throws authenticationFailed', () {
      final plain = utf8.encode('hello');
      final sealed = keysA.seal(TunnelPurpose.manifest, plain);
      expect(
        () => keysB.open(TunnelPurpose.manifest, sealed),
        throwsA(
          isA<TunnelCryptoException>().having(
            (e) => e.error,
            'error',
            TunnelCryptoError.authenticationFailed,
          ),
        ),
      );
    });

    test('wrong purpose throws authenticationFailed', () {
      final plain = utf8.encode('hello');
      final sealedChunk = keysA.seal(
        TunnelPurpose.chunk,
        plain,
        fileIndex: 0,
        chunkIndex: 0,
      );
      expect(
        () => keysA.open(
          TunnelPurpose.ack,
          sealedChunk,
          fileIndex: 0,
          chunkIndex: 0,
        ),
        throwsA(
          isA<TunnelCryptoException>().having(
            (e) => e.error,
            'error',
            TunnelCryptoError.authenticationFailed,
          ),
        ),
      );
    });

    test('replayed chunk under different fileIndex or chunkIndex throws authenticationFailed', () {
      final plain = utf8.encode('chunk data');
      final sealed = keysA.seal(
        TunnelPurpose.chunk,
        plain,
        fileIndex: 0,
        chunkIndex: 0,
      );

      // Wrong fileIndex
      expect(
        () => keysA.open(
          TunnelPurpose.chunk,
          sealed,
          fileIndex: 1,
          chunkIndex: 0,
        ),
        throwsA(
          isA<TunnelCryptoException>().having(
            (e) => e.error,
            'error',
            TunnelCryptoError.authenticationFailed,
          ),
        ),
      );

      // Wrong chunkIndex
      expect(
        () => keysA.open(
          TunnelPurpose.chunk,
          sealed,
          fileIndex: 0,
          chunkIndex: 1,
        ),
        throwsA(
          isA<TunnelCryptoException>().having(
            (e) => e.error,
            'error',
            TunnelCryptoError.authenticationFailed,
          ),
        ),
      );
    });
  });

  group('Seal counter and cap', () {
    test('seal increments sealCount, open does not', () {
      final keys = TunnelKeys.fromRootKey(Uint8List(32));
      expect(keys.sealCount, 0);

      final s1 = keys.seal(TunnelPurpose.manifest, [1]);
      expect(keys.sealCount, 1);

      final s2 = keys.seal(
        TunnelPurpose.chunk,
        [2],
        fileIndex: 0,
        chunkIndex: 0,
      );
      expect(keys.sealCount, 2);

      keys.open(TunnelPurpose.manifest, s1);
      keys.open(TunnelPurpose.chunk, s2, fileIndex: 0, chunkIndex: 0);
      expect(keys.sealCount, 2);
    });

    test('seal cap reached throws sealCapReached and stops further seals', () {
      final keys = TunnelKeys.fromRootKey(Uint8List(32), maxSeals: 3);
      expect(keys.sealCount, 0);

      keys.seal(TunnelPurpose.manifest, [1]);
      keys.seal(TunnelPurpose.manifest, [2]);
      keys.seal(TunnelPurpose.manifest, [3]);
      expect(keys.sealCount, 3);

      expect(
        () => keys.seal(TunnelPurpose.manifest, [4]),
        throwsA(
          isA<TunnelCryptoException>().having(
            (e) => e.error,
            'error',
            TunnelCryptoError.sealCapReached,
          ),
        ),
      );
      expect(keys.sealCount, 3);

      // open still works after cap reached
      final s = keys.sealWithNonce(TunnelPurpose.manifest, [4], Uint8List(12));
      expect(keys.open(TunnelPurpose.manifest, s), [4]);
    });
  });

  group('Immutability and input safety', () {
    test('seal and open do not mutate inputs', () {
      final keys = TunnelKeys.fromRootKey(Uint8List(32));
      final plain = Uint8List.fromList([10, 20, 30, 40]);
      final plainCopy = Uint8List.fromList(plain);

      final sealed = keys.seal(TunnelPurpose.manifest, plain);
      expect(plain, equals(plainCopy));

      final sealedCopy = Uint8List.fromList(sealed);
      final opened = keys.open(TunnelPurpose.manifest, sealed);
      expect(sealed, equals(sealedCopy));
      expect(opened, equals(plain));
    });
  });
}
