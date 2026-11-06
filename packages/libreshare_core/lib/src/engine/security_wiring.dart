/// The secure profile's persistent state around one directory: the device identity (created once,
/// reloaded, never silently regenerated), the contact list, the PIN guard and the secret store
/// (docs/plans/inc3.md D3, D5, D6, D7).
///
/// Layout, all under [directory]:
///   `identity.json`   certificate and metadata (public)
///   `*.secret`        the private key and any `kpair/<deviceId>` (mode 0600, directory 0700)
///   `contacts.json`   pinned and blocked fingerprints
///
/// One [SecurityWiring] feeds one `LibreShareEngine`: the same identity and trust store reach the
/// TLS listener, the receiver, the pairing service, discovery and every client. The engine does not
/// close it; the owner calls [close].
///
/// Nothing here logs or prints key material, PINs or full fingerprints.
library;

import 'dart:async';
import 'dart:io';

import 'package:uuid/uuid.dart';

import '../security/cert_factory.dart' show generateIdentityFor;
import '../security/contracts.dart';
import '../security/key_identity.dart';
import '../security/pin_guard.dart';
import '../security/trust_store.dart';
import '../storage/credential_store.dart';
import '../storage/file_secret_store.dart';

class SecurityWiring {
  SecurityWiring._({
    required this.directory,
    required this.identity,
    required this.trust,
    required this.pinGuard,
    required this.secrets,
    required this.config,
  });

  /// Opens (or creates, on the very first run) the identity in [directory], loads the contacts
  /// and builds the PIN guard.
  ///
  /// * No identity yet: a key pair and certificate are generated for [deviceId] (a random UUID when
  ///   null). An identity that exists is reloaded and its stored device id wins over [deviceId].
  /// * Throws [IdentityLostException] (and changes nothing) when an identity existed and its key
  ///   or metadata is gone or damaged. Only an explicit [rotateIdentity] replaces an identity.
  /// * [pin] is the PIN for a fixed or window [pinPolicy] (null: a random one); a malformed one is
  ///   an [ArgumentError] that does not contain it. It is kept in memory only.
  static Future<SecurityWiring> open({
    required Directory directory,
    String? deviceId,
    PinPolicy pinPolicy = const PinPolicy.off(),
    String? pin,
    ConsentPolicy? consent,
    bool allowInsecurePeers = false,
  }) async {
    // Cheap validation first: a bad PIN must not leave an identity behind.
    final handle = _BruteForceHandle();
    final guard = PinGuard(
      policy: pinPolicy,
      pin: pin,
      onBruteForce: handle.fire,
    );

    await directory.create(recursive: true);
    final secrets = FileSecretStore(directory);
    final credentials = CredentialStore(directory: directory, secrets: secrets);
    final stored = await credentials.loadOrCreate(
      generate: generateIdentityFor,
      deviceId: deviceId ?? const Uuid().v4(),
    );
    final KeyIdentity identity;
    try {
      identity = KeyIdentity(
        deviceId: stored.identity.deviceId,
        certDer: stored.identity.certDer,
        privateKeyPem: stored.privateKeyPem,
      );
    } on KeyIdentityException {
      // The files disagree with each other: the identity is unusable, not replaceable here.
      throw IdentityLostException(
        IdentityLostReason.keyMismatch,
        shortFingerprint: shortFp(stored.identity.fingerprint),
      );
    }
    final trust = await FileTrustStore.open(directory);
    final config = SecurityConfig.tls(
      identity: identity,
      trust: trust,
      pin: pinPolicy,
      consent: consent ?? const ConsentPolicy(),
      allowInsecurePeers: allowInsecurePeers,
    );
    return SecurityWiring._(
      directory: directory,
      identity: identity,
      trust: trust,
      pinGuard: guard,
      secrets: secrets,
      config: config,
    ).._bruteForce = handle;
  }

  /// "Reset identity" (D7, `ls identity rotate`): a new key and certificate for the same device
  /// id. Peers will see KEY_CHANGED until they remove or re-confirm the contact. Throws
  /// [IdentityLostException] when the stored identity cannot be read (nothing is changed then).
  static Future<DeviceIdentity> rotateIdentity(Directory directory) async {
    await directory.create(recursive: true);
    final secrets = FileSecretStore(directory);
    final credentials = CredentialStore(directory: directory, secrets: secrets);
    // load() throws IdentityLostException for a damaged identity and returns null for none.
    final current = await credentials.load();
    if (current == null) {
      throw StateError('there is no identity to rotate');
    }
    final next = await credentials.createNewIdentity(
      generate: generateIdentityFor,
    );
    return next.identity;
  }

  final Directory directory;

  /// This device's identity and signing key.
  final KeyIdentity identity;

  /// Pinned and blocked contacts, persisted in `contacts.json`.
  final FileTrustStore trust;

  /// PIN enforcement for the receiver (a guard that enforces nothing when the policy is off).
  final PinGuard pinGuard;

  /// Secret store (private key, `kpair/<deviceId>`).
  final FileSecretStore secrets;

  /// What the server, receiver, sender, clients and discovery are configured with.
  final SecurityConfig config;

  _BruteForceHandle? _bruteForce;

  /// Called when the PIN guard locks all PIN checks (global brute-force limit).
  set onBruteForce(void Function()? callback) =>
      _bruteForce?.callback = callback;

  /// Ends the contact change stream. Idempotent; the files stay.
  Future<void> close() => trust.close();
}

/// Lets the engine hook the guard's callback after the guard was built.
class _BruteForceHandle {
  void Function()? callback;
  void fire() => callback?.call();
}
