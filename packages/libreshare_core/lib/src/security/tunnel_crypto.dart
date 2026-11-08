import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:pointycastle/export.dart';

import 'crypto_primitives.dart';

const int kTunnelRootKeyBytes = 32;
const int kTunnelNonceBytes = 12;
const int kTunnelTagBytes = 16;
const int kTunnelOverheadBytes = 28; // nonce + tag
const int kTunnelManifestFileIndex = 0xFFFFFFFF;
const int kTunnelMaxSealsPerKey = 1 << 24;

enum TunnelPurpose {
  manifest(1),
  chunk(2),
  ack(3);

  const TunnelPurpose(this.wireValue);
  final int wireValue;
}

enum TunnelCryptoError {
  badKeyLength,
  badInput,
  authenticationFailed,
  sealCapReached,
}

/// toString is exactly 'TunnelCryptoException(`error.name`)': never any key, nonce, plaintext or length.
final class TunnelCryptoException implements Exception {
  const TunnelCryptoException(this.error);
  final TunnelCryptoError error;

  @override
  String toString() => 'TunnelCryptoException(${error.name})';
}

final class TunnelKeys {
  final Uint8List _shareId;
  final Uint8List _kMan;
  final Uint8List _kData;
  final Uint8List _kAck;
  final Uint8List _rootKey;
  final Random _nonceSource;
  final int maxSeals;
  int _sealCount = 0;

  /// rootKey must be exactly 32 bytes, else TunnelCryptoException(badKeyLength).
  TunnelKeys.fromRootKey(
    List<int> rootKey, {
    Random? nonceSource,
    this.maxSeals = kTunnelMaxSealsPerKey,
  }) : _rootKey = Uint8List.fromList(rootKey),
       _nonceSource = nonceSource ?? Random.secure(),
       _shareId = hkdfSha256(
         ikm: rootKey,
         salt: utf8.encode('LSP1-TUN-v1'),
         info: utf8.encode('sid'),
         length: 16,
       ),
       _kMan = hkdfSha256(
         ikm: rootKey,
         salt: utf8.encode('LSP1-TUN-v1'),
         info: utf8.encode('manifest'),
         length: 32,
       ),
       _kData = hkdfSha256(
         ikm: rootKey,
         salt: utf8.encode('LSP1-TUN-v1'),
         info: utf8.encode('data'),
         length: 32,
       ),
       _kAck = hkdfSha256(
         ikm: rootKey,
         salt: utf8.encode('LSP1-TUN-v1'),
         info: utf8.encode('ack'),
         length: 32,
       ) {
    if (rootKey.length != kTunnelRootKeyBytes) {
      throw const TunnelCryptoException(TunnelCryptoError.badKeyLength);
    }
  }

  Uint8List get shareId => Uint8List.fromList(_shareId);

  int get sealCount => _sealCount;

  Uint8List _keyFor(TunnelPurpose purpose) {
    switch (purpose) {
      case TunnelPurpose.manifest:
        return _kMan;
      case TunnelPurpose.chunk:
        return _kData;
      case TunnelPurpose.ack:
        return _kAck;
    }
  }

  void _checkIndices(TunnelPurpose purpose, int? fileIndex, int? chunkIndex) {
    switch (purpose) {
      case TunnelPurpose.manifest:
        if (fileIndex != null || chunkIndex != null) {
          throw const TunnelCryptoException(TunnelCryptoError.badInput);
        }
      case TunnelPurpose.chunk:
        if (fileIndex == null || chunkIndex == null) {
          throw const TunnelCryptoException(TunnelCryptoError.badInput);
        }
        if (fileIndex < 0 || fileIndex >= 10000) {
          throw const TunnelCryptoException(TunnelCryptoError.badInput);
        }
        if (chunkIndex < 0 || chunkIndex > 9007199254740991) {
          throw const TunnelCryptoException(TunnelCryptoError.badInput);
        }
      case TunnelPurpose.ack:
        if (fileIndex == null || chunkIndex == null) {
          throw const TunnelCryptoException(TunnelCryptoError.badInput);
        }
        final isFinalAck = fileIndex == 0xFFFFFFFF && chunkIndex == 0;
        final isStandard =
            fileIndex >= 0 &&
            fileIndex < 10000 &&
            chunkIndex >= 0 &&
            chunkIndex <= 9007199254740991;
        if (!isFinalAck && !isStandard) {
          throw const TunnelCryptoException(TunnelCryptoError.badInput);
        }
    }
  }

  Uint8List _buildAad(
    TunnelPurpose purpose,
    int? fileIndex,
    int? chunkIndex,
    int plaintextLen,
  ) {
    final aad = Uint8List(41);
    final bd = ByteData.sublistView(aad);
    // "LSP1"
    aad[0] = 0x4C;
    aad[1] = 0x53;
    aad[2] = 0x50;
    aad[3] = 0x31;
    // purpose
    aad[4] = purpose.wireValue;
    // shareId (16 bytes)
    aad.setRange(5, 21, _shareId);
    // fileIndex (u32be)
    final fIdx = purpose == TunnelPurpose.manifest
        ? kTunnelManifestFileIndex
        : fileIndex!;
    bd.setUint32(21, fIdx);
    // chunkIndex (u64be)
    final cIdx = purpose == TunnelPurpose.manifest ? 0 : chunkIndex!;
    bd.setUint64(25, cIdx);
    // plaintextLen (u64be)
    bd.setUint64(33, plaintextLen);
    return aad;
  }

  static Uint8List _aesGcmSeal(
    Uint8List key,
    Uint8List nonce,
    Uint8List aad,
    List<int> plaintext,
  ) {
    final cipher = GCMBlockCipher(AESEngine());
    final params = AEADParameters(KeyParameter(key), 128, nonce, aad);
    cipher.init(true, params);
    final inBytes = Uint8List.fromList(plaintext);
    final out = Uint8List(cipher.getOutputSize(inBytes.length));
    final len = cipher.processBytes(inBytes, 0, inBytes.length, out, 0);
    final finalLen = cipher.doFinal(out, len);
    final totalCiphertextLen = len + finalLen;

    final res = Uint8List(kTunnelNonceBytes + totalCiphertextLen);
    res.setRange(0, kTunnelNonceBytes, nonce);
    res.setRange(
      kTunnelNonceBytes,
      res.length,
      Uint8List.sublistView(out, 0, totalCiphertextLen),
    );
    return res;
  }

  static Uint8List _aesGcmOpen(Uint8List key, Uint8List aad, List<int> sealed) {
    final nonce = Uint8List.fromList(sealed.sublist(0, kTunnelNonceBytes));
    final ciphertextAndTag = Uint8List.fromList(
      sealed.sublist(kTunnelNonceBytes),
    );
    final cipher = GCMBlockCipher(AESEngine());
    final params = AEADParameters(KeyParameter(key), 128, nonce, aad);
    cipher.init(false, params);
    final out = Uint8List(cipher.getOutputSize(ciphertextAndTag.length));
    try {
      final len = cipher.processBytes(
        ciphertextAndTag,
        0,
        ciphertextAndTag.length,
        out,
        0,
      );
      final finalLen = cipher.doFinal(out, len);
      return Uint8List.fromList(out.sublist(0, len + finalLen));
    } catch (_) {
      throw const TunnelCryptoException(TunnelCryptoError.authenticationFailed);
    }
  }

  Uint8List seal(
    TunnelPurpose purpose,
    List<int> plaintext, {
    int? fileIndex,
    int? chunkIndex,
  }) {
    _checkIndices(purpose, fileIndex, chunkIndex);
    if (_sealCount >= maxSeals) {
      throw const TunnelCryptoException(TunnelCryptoError.sealCapReached);
    }
    _sealCount++;
    final nonce = Uint8List(kTunnelNonceBytes);
    for (var i = 0; i < kTunnelNonceBytes; i++) {
      nonce[i] = _nonceSource.nextInt(256);
    }
    final aad = _buildAad(purpose, fileIndex, chunkIndex, plaintext.length);
    return _aesGcmSeal(_keyFor(purpose), nonce, aad, plaintext);
  }

  Uint8List open(
    TunnelPurpose purpose,
    List<int> sealed, {
    int? fileIndex,
    int? chunkIndex,
  }) {
    _checkIndices(purpose, fileIndex, chunkIndex);
    if (sealed.length < kTunnelOverheadBytes) {
      throw const TunnelCryptoException(TunnelCryptoError.badInput);
    }
    final plaintextLen = sealed.length - kTunnelOverheadBytes;
    final aad = _buildAad(purpose, fileIndex, chunkIndex, plaintextLen);
    return _aesGcmOpen(_keyFor(purpose), aad, sealed);
  }

  String sas(List<int> claim) {
    if (claim.length != 16) {
      throw const TunnelCryptoException(TunnelCryptoError.badInput);
    }
    final info = Uint8List(3 + 16);
    info[0] = 0x73; // 's'
    info[1] = 0x61; // 'a'
    info[2] = 0x73; // 's'
    info.setRange(3, 19, claim);

    final raw = hkdfSha256(
      ikm: _rootKey,
      salt: utf8.encode('LSP1-TUN-v1'),
      info: info,
      length: 4,
    );
    final bd = ByteData.sublistView(raw);
    final val = bd.getUint32(0) % 1000000;
    return val.toString().padLeft(6, '0');
  }

  @visibleForTesting
  Uint8List sealWithNonce(
    TunnelPurpose purpose,
    List<int> plaintext,
    List<int> nonce12, {
    int? fileIndex,
    int? chunkIndex,
  }) {
    _checkIndices(purpose, fileIndex, chunkIndex);
    if (nonce12.length != kTunnelNonceBytes) {
      throw const TunnelCryptoException(TunnelCryptoError.badInput);
    }
    final nonce = Uint8List.fromList(nonce12);
    final aad = _buildAad(purpose, fileIndex, chunkIndex, plaintext.length);
    return _aesGcmSeal(_keyFor(purpose), nonce, aad, plaintext);
  }

  @override
  String toString() => 'TunnelKeys(redacted)';
}
