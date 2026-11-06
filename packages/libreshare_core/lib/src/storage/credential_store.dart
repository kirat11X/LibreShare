/// Owns the device identity lifecycle (docs/plans/inc3.md D3, D6, D7).
///
/// Layout, all under the caller's directories:
///   `<directory>/identity.json`   certificate + metadata, plain atomic JSON (not secret)
///   [SecretStore] `identity.key`  PKCS#8 PEM of the private key (the only secret)
///
/// The rule that matters: an identity that existed is never silently
/// replaced. If `identity.json` exists but the key is missing, unreadable or
/// does not belong to it, or if the metadata is corrupt, [loadOrCreate] throws
/// [IdentityLostException]; peers would otherwise see KEY_CHANGED for no
/// reason the user can understand. Only the explicit [createNewIdentity]
/// replaces an identity (rotation, D7, and recovery after IdentityLost).
///
/// The certificate's expiry is not parsed here (this layer holds no X.509
/// code). The generator uses a 3650-day validity (D2), and the store persists
/// `createdAt`; the UI warns by age ([StoredIdentity.age]), for example from
/// nine years on, which is the "below 1 year left" warning of D3.
///
/// Crash safety of a (re)creation: the new key is staged as `identity.key.next`
/// first, `identity.json` (the commit point) is written second, `identity.key`
/// third. A crash between the steps is completed by the next load; it never
/// leaves the user without an identity or with a half-replaced one.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';

import '../clock.dart';
import '../security/contracts.dart';
import 'file_secret_store.dart' show writeFileAtomically;

final Logger _log = Logger('libreshare.storage.credential');

/// Creates a key pair and self-signed certificate for [deviceId]. Production
/// wiring passes P1's `generateIdentityFor` (the positional adapter); tests pass a fake with fixed bytes.
typedef IdentityGenerator =
    ({DeviceIdentity identity, Uint8List privateKeyPem}) Function(
      String deviceId,
    );

/// Optional cryptographic check that [privateKeyPem] is the key of
/// [identity]'s certificate (sign and verify). Without it, binding is checked
/// by the SHA-256 recorded in `identity.json` when the identity was created.
typedef KeyMatchVerifier = bool Function(
  DeviceIdentity identity,
  Uint8List privateKeyPem,
);

/// Why an existing identity cannot be used.
enum IdentityLostReason {
  /// The key is stored but `identity.json` is gone.
  metadataMissing,

  /// `identity.json` is unreadable, malformed, from a newer schema, or
  /// inconsistent (fingerprint is not the hash of the certificate).
  metadataCorrupt,

  /// `identity.json` exists, the key store has no key.
  keyMissing,

  /// The key store failed when asked for the key.
  keyUnreadable,

  /// A key exists but is not the one this certificate was created with.
  keyMismatch,
}

class IdentityLostException implements Exception {
  const IdentityLostException(this.reason, {this.shortFingerprint});

  final IdentityLostReason reason;

  /// First 16 hex characters of the lost identity's fingerprint, when known.
  final String? shortFingerprint;

  @override
  String toString() =>
      'IdentityLostException(${reason.name}'
      '${shortFingerprint == null ? '' : ', fp=$shortFingerprint'})';
}

final class StoredIdentity {
  const StoredIdentity({
    required this.identity,
    required this.privateKeyPem,
    required this.createdAt,
    this.created = false,
  });

  final DeviceIdentity identity;

  /// PKCS#8 PEM. Hand it to the identity provider; never log or persist it.
  final Uint8List privateKeyPem;

  /// UTC time the identity was generated (persisted).
  final DateTime createdAt;

  /// True when this call generated the identity (first run or replacement).
  final bool created;

  /// How old the identity is at [now]; never negative.
  Duration age(DateTime now) {
    final d = now.toUtc().difference(createdAt);
    return d.isNegative ? Duration.zero : d;
  }
}

class CredentialStore {
  CredentialStore({
    required this.directory,
    required this.secrets,
    this.clock = const SystemClock(),
    this.verifyKeyMatchesCertificate,
  });

  static const String identityFileName = 'identity.json';
  static const String keyName = 'identity.key';
  static const String stagedKeyName = 'identity.key.next';
  static const int schemaVersion = 1;

  /// Where `identity.json` lives (created on first write).
  final Directory directory;
  final SecretStore secrets;
  final Clock clock;
  final KeyMatchVerifier? verifyKeyMatchesCertificate;

  static const int _maxMetaBytes = 64 * 1024;
  static final RegExp _fingerprintRe = RegExp(r'^[0-9A-F]{64}$');
  static final RegExp _digestRe = RegExp(r'^[0-9a-f]{64}$');
  static final RegExp _pemRe = RegExp(
    r'^-----BEGIN CERTIFICATE-----([A-Za-z0-9+/=\s]+)-----END CERTIFICATE-----$',
  );

  Future<void> _tail = Future<void>.value();

  File get _file =>
      File('${directory.path}${Platform.pathSeparator}$identityFileName');

  Future<T> _serial<T>(Future<T> Function() op) {
    final next = _tail.then((_) => op());
    _tail = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  /// The stored identity, or null if none was ever created (neither
  /// `identity.json` nor a key). Throws [IdentityLostException] when one
  /// existed and cannot be used. Never creates or repairs anything except
  /// finishing an interrupted rotation.
  Future<StoredIdentity?> load() => _serial(_load);

  /// First run: generates with [generate], persists, returns it (`created`).
  /// Later runs: returns the stored identity; [deviceId] is then ignored (the
  /// stored one wins) and [generate] is not called. Throws
  /// [IdentityLostException] instead of regenerating (see the library doc).
  Future<StoredIdentity> loadOrCreate({
    required IdentityGenerator generate,
    required String deviceId,
  }) => _serial(() async {
    final existing = await _load();
    if (existing != null) return existing;
    return _create(generate, deviceId);
  });

  /// The only way to replace an identity: rotation ("Reset identity") or
  /// recovery after [IdentityLostException]. Reuses the stored device id unless
  /// [deviceId] is given (peers then see KEY_CHANGED, not a new device); when
  /// no readable identity exists [deviceId] is required.
  ///
  /// If this throws after `identity.json` was written, the next [load] completes
  /// the replacement; if it throws earlier, the old identity is untouched.
  Future<StoredIdentity> createNewIdentity({
    required IdentityGenerator generate,
    String? deviceId,
  }) => _serial(() async {
    var id = deviceId;
    if (id == null) {
      try {
        id = (await _readMeta())?.deviceId;
      } on IdentityLostException {
        id = null;
      }
    }
    if (id == null || id.isEmpty) {
      throw ArgumentError(
        'deviceId is required when no readable identity exists',
      );
    }
    return _create(generate, id);
  });

  // ---- internals ------------------------------------------------------

  Future<StoredIdentity?> _load() async {
    final meta = await _readMeta();
    if (meta == null) {
      Uint8List? stray;
      try {
        stray = await secrets.get(keyName);
      } on Object catch (e) {
        throw _lost(IdentityLostReason.keyUnreadable, null, e);
      }
      if (stray != null) throw _lost(IdentityLostReason.metadataMissing);
      return null;
    }

    Uint8List? key;
    try {
      key = await secrets.get(keyName);
    } on Object catch (e) {
      throw _lost(IdentityLostReason.keyUnreadable, meta, e);
    }
    if (key == null || !meta.matches(key)) {
      final staged = await _readStaged();
      if (staged != null && meta.matches(staged)) {
        // A replacement was committed but its key never reached identity.key.
        key = staged;
        try {
          await secrets.put(keyName, staged);
          await _dropStaged();
          _log.info('completed an interrupted identity replacement');
        } on Object catch (e) {
          _log.warning('could not finish the replacement: ${e.runtimeType}');
        }
      } else {
        throw _lost(
          key == null
              ? IdentityLostReason.keyMissing
              : IdentityLostReason.keyMismatch,
          meta,
        );
      }
    } else {
      await _dropStaged();
    }

    final identity = meta.toIdentity();
    if (!_keyVerifies(identity, key)) {
      throw _lost(IdentityLostReason.keyMismatch, meta);
    }
    return StoredIdentity(
      identity: identity,
      privateKeyPem: key,
      createdAt: meta.createdAt,
    );
  }

  bool _keyVerifies(DeviceIdentity identity, Uint8List key) {
    final verify = verifyKeyMatchesCertificate;
    if (verify == null) return true;
    try {
      return verify(identity, key);
    } on Object {
      return false;
    }
  }

  IdentityLostException _lost(
    IdentityLostReason reason, [
    _Meta? meta,
    Object? cause,
  ]) {
    _log.severe(
      'device identity lost: ${reason.name}'
      '${cause == null ? '' : ' (${cause.runtimeType})'}',
    );
    return IdentityLostException(
      reason,
      shortFingerprint: meta == null ? null : shortFp(meta.fingerprint),
    );
  }

  Future<Uint8List?> _readStaged() async {
    try {
      return await secrets.get(stagedKeyName);
    } on Object {
      return null;
    }
  }

  Future<void> _dropStaged() async {
    try {
      await secrets.delete(stagedKeyName);
    } on Object catch (e) {
      _log.fine('staged key not removed: ${e.runtimeType}');
    }
  }

  /// Null when `identity.json` does not exist; throws metadataCorrupt when it
  /// exists and cannot be trusted.
  Future<_Meta?> _readMeta() async {
    final file = _file;
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    try {
      if (type != FileSystemEntityType.file) throw const FormatException();
      if (await file.length() > _maxMetaBytes) throw const FormatException();
      final root = jsonDecode(utf8.decode(await file.readAsBytes()));
      if (root is! Map<String, Object?>) throw const FormatException();
      return _Meta.parse(root);
    } on Object catch (e) {
      throw _lost(IdentityLostReason.metadataCorrupt, null, e);
    }
  }

  void _validate(
    ({DeviceIdentity identity, Uint8List privateKeyPem}) g,
    String deviceId,
  ) {
    final id = g.identity;
    final der = _derFromPem(id.certPem);
    final ok =
        id.deviceId == deviceId &&
        _fingerprintRe.hasMatch(id.fingerprint) &&
        id.fingerprint == _fingerprintOf(id.certDer) &&
        der != null &&
        _sameBytes(der, id.certDer) &&
        g.privateKeyPem.isNotEmpty &&
        g.privateKeyPem.length <= 64 * 1024 &&
        _keyVerifies(id, g.privateKeyPem);
    if (!ok) {
      throw StateError('identity generator returned an inconsistent identity');
    }
  }

  Future<StoredIdentity> _create(
    IdentityGenerator generate,
    String deviceId,
  ) async {
    final generated = generate(deviceId);
    _validate(generated, deviceId);
    final identity = generated.identity;
    final key = Uint8List.fromList(generated.privateKeyPem);
    final createdAt = clock.now().toUtc();

    await secrets.put(stagedKeyName, key);
    await directory.create(recursive: true);
    await writeFileAtomically(
      _file,
      utf8.encode(
        const JsonEncoder.withIndent('  ').convert({
          'v': schemaVersion,
          'deviceId': identity.deviceId,
          'fingerprint': identity.fingerprint,
          'certPem': identity.certPem,
          'createdAt': createdAt.toIso8601String(),
          'keySha256': _digestOf(key),
        }),
      ),
    );
    await secrets.put(keyName, key);
    await _dropStaged();

    _log.info('created device identity fp=${shortFp(identity.fingerprint)}');
    return StoredIdentity(
      identity: identity,
      privateKeyPem: key,
      createdAt: createdAt,
      created: true,
    );
  }

  static String _fingerprintOf(List<int> der) =>
      sha256.convert(der).toString().toUpperCase();

  static String _digestOf(List<int> bytes) => sha256.convert(bytes).toString();

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static Uint8List? _derFromPem(String pem) {
    final m = _pemRe.firstMatch(pem.trim());
    if (m == null) return null;
    try {
      final der = base64.decode(m.group(1)!.replaceAll(RegExp(r'\s'), ''));
      return der.isEmpty ? null : der;
    } on FormatException {
      return null;
    }
  }
}

/// Parsed, validated `identity.json`.
final class _Meta {
  _Meta._({
    required this.deviceId,
    required this.fingerprint,
    required this.certPem,
    required this.certDer,
    required this.createdAt,
    required this.keySha256,
  });

  final String deviceId;
  final String fingerprint;
  final String certPem;
  final Uint8List certDer;
  final DateTime createdAt;
  final String keySha256;

  /// Throws [FormatException] on anything unexpected.
  factory _Meta.parse(Map<String, Object?> j) {
    if (j['v'] != CredentialStore.schemaVersion) throw const FormatException();
    final deviceId = j['deviceId'];
    final fingerprint = j['fingerprint'];
    final certPem = j['certPem'];
    final createdAt = j['createdAt'];
    final keySha256 = j['keySha256'];
    if (deviceId is! String || deviceId.isEmpty || deviceId.length > 256) {
      throw const FormatException();
    }
    if (fingerprint is! String ||
        !CredentialStore._fingerprintRe.hasMatch(fingerprint)) {
      throw const FormatException();
    }
    if (certPem is! String) throw const FormatException();
    if (createdAt is! String) throw const FormatException();
    if (keySha256 is! String ||
        !CredentialStore._digestRe.hasMatch(keySha256)) {
      throw const FormatException();
    }
    final der = CredentialStore._derFromPem(certPem);
    if (der == null || CredentialStore._fingerprintOf(der) != fingerprint) {
      throw const FormatException();
    }
    return _Meta._(
      deviceId: deviceId,
      fingerprint: fingerprint,
      certPem: certPem,
      certDer: der,
      createdAt: DateTime.parse(createdAt).toUtc(),
      keySha256: keySha256,
    );
  }

  bool matches(Uint8List key) => CredentialStore._digestOf(key) == keySha256;

  DeviceIdentity toIdentity() => DeviceIdentity(
    deviceId: deviceId,
    fingerprint: fingerprint,
    certDer: certDer,
    certPem: certPem,
  );
}
