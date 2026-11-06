/// Security contracts shared by every Increment 3 module (orchestrator-owned; docs/plans/inc3.md
/// sections 2 and 5). Implementations live elsewhere:
///   IdentityProvider -> security/key_identity.dart (P1)      SecretStore -> storage/file_secret_store.dart (P2)
///   TrustStore       -> security/trust_store.dart (P2)       SecurityConfig is consumed by engine/api_server/api_client.
/// Nothing here may import Flutter. Nothing here may log key material, PINs, nonces or full
/// fingerprints (16 hex characters is the most a log line may carry; see [shortFp]).
library;

import 'dart:typed_data';

/// Domain-separation labels. Every signature or MAC in the protocol starts with exactly one of
/// these followed by a NUL byte, so a signature made for one purpose can never verify for another
/// (docs/plans/inc3.md D1, D4, D12, D13). Values are part of the wire format: change = protocol change.
abstract final class SigDomain {
  static const String auth = 'LSP1-AUTH-v1';
  static const String sasCommit = 'LSP1-SAS-C';
  static const String sasValue = 'LSP1-SAS-V';
  static const String bye = 'LSP1-BYE';
  static const String pairRequest = 'LSP1-PAIR-REQ';
  static const String pairAck = 'LSP1-PAIR-ACK';
  static const String pairInfo = 'LSP-R1 pair';
}

/// First 16 hex characters of a fingerprint: the only form allowed in logs and event text.
String shortFp(String fingerprint) =>
    fingerprint.length <= 16 ? fingerprint : fingerprint.substring(0, 16);

/// Public side of this device's identity (key pair + self-signed certificate).
final class DeviceIdentity {
  const DeviceIdentity({
    required this.deviceId,
    required this.fingerprint,
    required this.certDer,
    required this.certPem,
  });

  /// Stable UUID, also the certificate's CN.
  final String deviceId;

  /// Uppercase hex SHA-256 of [certDer] (64 characters). LSP-1 section 0.2.
  final String fingerprint;
  final Uint8List certDer;
  final String certPem;
}

/// This device's identity plus the operations that need the private key. The key never leaves
/// the provider except through [privateKeyPem], which only the TLS listener may call.
abstract interface class IdentityProvider {
  DeviceIdentity get identity;

  /// ECDSA P-256 over `domain + NUL + message`, returned as raw r||s (64 bytes).
  Uint8List sign(String domain, List<int> message);

  /// PKCS#8 PEM of the private key, for `SecurityContext.usePrivateKeyBytes` only.
  /// Callers must not store or log it.
  Uint8List privateKeyPem();
}

/// Async byte store for secrets (private key, PIN, K_pair). Keys are short ASCII names such as
/// `identity.key` or `kpair/<deviceId>`. Values are opaque bytes. Implementations must be atomic
/// (a crash never leaves a half-written value) and must not log keys or values.
///
/// An unreadable store throws `SecretStoreException`; a missing or corrupt value reads as null.
abstract interface class SecretStore {
  Future<Uint8List?> get(String key);
  Future<void> put(String key, Uint8List value);
  Future<void> delete(String key);
}

/// A peer that has completed the proof check on a request: who it is cryptographically.
final class AuthenticatedPeer {
  const AuthenticatedPeer({
    required this.fingerprint,
    required this.certDer,
    this.deviceId,
  });

  /// Uppercase hex SHA-256 of [certDer].
  final String fingerprint;
  final Uint8List certDer;

  /// CN of the certificate; null if the certificate carries none we accept.
  final String? deviceId;
}

/// How much we trust a (deviceId, fingerprint) pair. `keyChanged` is an overlay flag on
/// [PeerTrustInfo], not a level.
enum PeerTrust {
  /// Never seen.
  unknown,

  /// Pinned after a SAS-confirmed or accepted first contact.
  known,

  /// Paired by QR or explicitly marked a contact: may auto-accept and skip the PIN.
  trusted,

  /// Refused outright.
  blocked,
}

final class PeerTrustInfo {
  const PeerTrustInfo({
    required this.trust,
    this.keyChanged = false,
    this.pinnedFingerprint,
    this.alias,
    this.hasPairKey = false,
  });

  const PeerTrustInfo.unknown() : this(trust: PeerTrust.unknown);

  final PeerTrust trust;

  /// True when the deviceId is known but presented a different fingerprint than the pinned one.
  final bool keyChanged;

  /// The pinned fingerprint for the deviceId (set when [keyChanged]).
  final String? pinnedFingerprint;
  final String? alias;

  /// Whether a K_pair exists for this contact (Increment 6 uses it).
  final bool hasPairKey;
}

/// Pinned contacts. Implemented over the credential store (docs/plans/inc3.md D3).
abstract interface class TrustStore {
  /// Classifies what a peer showed us. Never throws for unknown peers.
  PeerTrustInfo classify(String deviceId, String fingerprint);

  /// Looks a contact up by fingerprint alone (used before the deviceId is known to be trustworthy).
  PeerTrustInfo classifyFingerprint(String fingerprint);

  /// Pins [fingerprint] for [deviceId]. Replaces an older pin only when [replace] is true
  /// (the explicit "accept the new key" action). Throws `KeyChangedException` when the deviceId
  /// is pinned with another fingerprint and [replace] is false, `FingerprintInUseException` when
  /// the fingerprint belongs to another deviceId, `RegistryFullException` at the contact cap and
  /// `ArgumentError` for a malformed fingerprint (all declared with the implementation in
  /// security/trust_store.dart and storage/device_registry.dart). Without [replace] the stronger
  /// of the old and new trust is kept.
  Future<void> pin({
    required String deviceId,
    required String fingerprint,
    required String alias,
    required PeerTrust trust,
    bool replace = false,
  });

  Future<void> block(String fingerprint);

  /// Lifts a block (the block list outlives [remove]).
  Future<void> unblock(String fingerprint);
  Future<void> remove(String deviceId);

  /// Changes a contact's trust level ([PeerTrust.known] or [PeerTrust.trusted]).
  Future<void> setTrust(String deviceId, PeerTrust trust);

  /// Records whether a K_pair secret exists for the contact (the caller writes/deletes the
  /// `kpair/<deviceId>` secret itself).
  Future<void> setPairKey(String deviceId, bool present);

  /// Snapshot of all contacts, for the UI and `ls contacts list`.
  List<Contact> get contacts;

  /// Fires after every change.
  Stream<void> get changes;
}

final class Contact {
  const Contact({
    required this.deviceId,
    required this.fingerprint,
    required this.alias,
    required this.trust,
    required this.pinnedAt,
    this.hasPairKey = false,
  });

  final String deviceId;
  final String fingerprint;
  final String alias;
  final PeerTrust trust;
  final DateTime pinnedAt;
  final bool hasPairKey;
}

enum PinMode {
  /// No PIN (default).
  off,

  /// One user-set PIN, persisted.
  fixed,

  /// A new PIN for every Receive window.
  window,
}

final class PinPolicy {
  const PinPolicy({
    this.mode = PinMode.off,
    this.oneTime = false,
    this.exemptContacts = true,
  });

  const PinPolicy.off() : this();

  final PinMode mode;

  /// A PIN is consumed by one authorised session.
  final bool oneTime;

  /// Trusted contacts do not need the PIN.
  final bool exemptContacts;

  bool get enabled => mode != PinMode.off;
}

final class ConsentPolicy {
  const ConsentPolicy({
    this.autoAcceptTrusted = false,
    this.maxPendingPerIp = 3,
    this.maxPendingTotal = 8,
  });

  /// Sessions from [PeerTrust.trusted] contacts are accepted without a prompt (default off).
  final bool autoAcceptTrusted;
  final int maxPendingPerIp;
  final int maxPendingTotal;
}

/// PIN enforcement seam between the HTTP layer / receiver and the throttling guard
/// (security/pin_guard.dart, agent P3). The receiver calls [check] at step 9 of the POST /sessions
/// check order (after the trust checks, before the storage check).
abstract interface class PinVerifier {
  /// True while a PIN is being enforced.
  bool get enforced;

  /// Throws `LsException`: `pinRequired` (401, none given), `pinInvalid` (401, wrong, expired or
  /// consumed; counts as a strike), `blocked` (403, source blocked or PIN checks locked).
  /// [exempt] = the caller is a trusted contact and the policy exempts contacts.
  void check({
    required String remoteAddress,
    required String? pin,
    required bool exempt,
  });

  /// Called after a session that needed the PIN was authorised (consumes it when `oneTime`).
  void consume();
}

/// How a device secures its traffic. Library constructors default to [SecurityConfig.plaintext]
/// (the Increment 1 loopback profile, used by the legacy tests); the app is always secure.
final class SecurityConfig {
  const SecurityConfig.plaintext()
    : identity = null,
      trust = null,
      pin = const PinPolicy.off(),
      consent = const ConsentPolicy(),
      allowInsecurePeers = false;

  const SecurityConfig.tls({
    required IdentityProvider this.identity,
    required TrustStore this.trust,
    this.pin = const PinPolicy.off(),
    this.consent = const ConsentPolicy(),
    this.allowInsecurePeers = false,
  });

  final IdentityProvider? identity;
  final TrustStore? trust;
  final PinPolicy pin;
  final ConsentPolicy consent;

  /// Lets a secure sender talk to a legacy (no fingerprint) receiver: CLI `--allow-insecure` only.
  final bool allowInsecurePeers;

  bool get isSecure => identity != null;
}

/// What the receiver's UI/CLI needs to show a consent prompt for one incoming session.
final class IncomingSessionInfo {
  const IncomingSessionInfo({
    required this.sessionId,
    this.peer,
    this.trust = PeerTrust.unknown,
    this.keyChanged = false,
    this.sasRequired = false,
    this.sasCode,
  });

  final String sessionId;
  final AuthenticatedPeer? peer;
  final PeerTrust trust;
  final bool keyChanged;

  /// True when the sender could not authenticate us and sent a SAS commitment: the human
  /// comparison is mandatory and Accept stays disabled until [sasCode] is non-null.
  final bool sasRequired;

  /// Six digits, e.g. `482913` (display as `482 913`). Null until both nonces are known.
  final String? sasCode;
}
