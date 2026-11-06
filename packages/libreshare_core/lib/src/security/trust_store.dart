/// Pinned contacts and blocked fingerprints (docs/plans/inc3.md D1, D3, D7).
///
/// [RegistryTrustStore] keeps the rules; [FileTrustStore] persists to
/// `contacts.json` through [DeviceRegistry], [InMemoryTrustStore] keeps
/// everything in memory (same semantics, for other packages' tests).
///
/// The rules, in one place:
///  * `classify` / `classifyFingerprint` are synchronous and read the committed
///    in-memory view; they never throw for unknown peers (a store that was never
///    loaded throws [StateError]: that is a wiring bug, not an unknown peer).
///  * A known deviceId presenting a different fingerprint is reported with
///    `keyChanged: true`, the old trust level and the pinned fingerprint. It is
///    never replaced on its own: [pin] with a different fingerprint throws
///    [KeyChangedException] unless `replace: true` (the explicit "accept the new
///    key" action).
///  * A blocked fingerprint is `blocked` whatever deviceId shows it. A block is
///    a separate list: it outlives [remove], and [unblock] restores the contact's
///    stored trust.
///  * Without `replace`, [pin] never lowers trust (the stronger of old and new
///    wins); `replace: true` or [setTrust] sets it exactly. A contact's trust
///    never changes by classification alone.
///  * A fingerprint belongs to one deviceId ([FingerprintInUseException]); a
///    deviceId showing a fingerprint pinned for another device is `unknown`.
///  * Fingerprints are accepted in any case (exactly 64 hex characters) and kept
///    uppercase. Aliases are sanitised ([sanitizeAlias]).
///
/// Logging: short fingerprints (16 hex) and counts only; never aliases, device
/// ids or full fingerprints.
library;

import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';

import '../clock.dart';
import '../storage/device_registry.dart';
import 'contracts.dart';

final Logger _log = Logger('libreshare.security.trust');

/// [RegistryTrustStore.pin] was asked to pin another fingerprint for a deviceId
/// that already has one, without `replace: true`. Nothing was changed.
class KeyChangedException implements Exception {
  const KeyChangedException(this.deviceId);
  final String deviceId;

  @override
  String toString() => 'KeyChangedException(deviceId=$deviceId)';
}

/// The fingerprint is already pinned for a different deviceId.
class FingerprintInUseException implements Exception {
  const FingerprintInUseException();

  @override
  String toString() => 'FingerprintInUseException';
}

class RegistryTrustStore implements TrustStore {
  RegistryTrustStore(this.registry, {this.clock = const SystemClock()});

  final DeviceRegistry registry;
  final Clock clock;

  final StreamController<void> _changes = StreamController<void>.broadcast();

  static final RegExp _hex64 = RegExp(r'^[0-9A-Fa-f]{64}$');

  /// Reads the contacts file (a no-op for in-memory stores). Required before
  /// any other call on a file-backed store.
  Future<void> load() => registry.load();

  bool get isLoaded => registry.isLoaded;

  void _requireLoaded() {
    if (!registry.isLoaded) {
      throw StateError('TrustStore used before load()');
    }
  }

  static String? _normalise(String fingerprint) =>
      _hex64.hasMatch(fingerprint) ? fingerprint.toUpperCase() : null;

  static String _requireFingerprint(String fingerprint) =>
      _normalise(fingerprint) ??
      (throw ArgumentError('fingerprint must be 64 hexadecimal characters'));

  static void _requirePinLevel(PeerTrust trust) {
    if (trust != PeerTrust.known && trust != PeerTrust.trusted) {
      throw ArgumentError('trust must be known or trusted');
    }
  }

  static PeerTrust _stronger(PeerTrust a, PeerTrust b) =>
      (a == PeerTrust.trusted || b == PeerTrust.trusted)
      ? PeerTrust.trusted
      : PeerTrust.known;

  PeerTrust _effective(ContactRecord c) =>
      registry.isBlocked(c.fingerprint) ? PeerTrust.blocked : c.trust;

  void _emit() {
    if (!_changes.isClosed) _changes.add(null);
  }

  // ---- TrustStore ------------------------------------------------------

  @override
  PeerTrustInfo classify(String deviceId, String fingerprint) {
    _requireLoaded();
    final fp = _normalise(fingerprint);
    if (fp != null && registry.isBlocked(fp)) {
      final holder = registry.byFingerprint(fp);
      return PeerTrustInfo(
        trust: PeerTrust.blocked,
        alias: holder?.alias,
        hasPairKey: holder?.hasPairKey ?? false,
      );
    }
    final c = registry.byDeviceId(deviceId);
    if (c == null) return const PeerTrustInfo.unknown();
    if (fp == c.fingerprint) {
      return PeerTrustInfo(
        trust: c.trust,
        alias: c.alias,
        hasPairKey: c.hasPairKey,
      );
    }
    return PeerTrustInfo(
      trust: _effective(c),
      keyChanged: true,
      pinnedFingerprint: c.fingerprint,
      alias: c.alias,
      hasPairKey: c.hasPairKey,
    );
  }

  @override
  PeerTrustInfo classifyFingerprint(String fingerprint) {
    _requireLoaded();
    final fp = _normalise(fingerprint);
    if (fp == null) return const PeerTrustInfo.unknown();
    final c = registry.byFingerprint(fp);
    if (registry.isBlocked(fp)) {
      return PeerTrustInfo(
        trust: PeerTrust.blocked,
        alias: c?.alias,
        hasPairKey: c?.hasPairKey ?? false,
      );
    }
    if (c == null) return const PeerTrustInfo.unknown();
    return PeerTrustInfo(
      trust: c.trust,
      alias: c.alias,
      hasPairKey: c.hasPairKey,
    );
  }

  /// Pins [fingerprint] for [deviceId] at [trust] (known or trusted).
  ///
  /// New deviceId: added. Same fingerprint again: the alias is updated (an empty
  /// alias keeps the old one) and trust becomes the stronger of old and new,
  /// or exactly [trust] with `replace: true`; unchanged data is not a change.
  /// Different fingerprint: [KeyChangedException] unless [replace], which swaps
  /// the key, sets [trust] exactly, restarts `pinnedAt` and clears the pair-key
  /// flag (the old K_pair belonged to the old key; the caller deletes the
  /// secret).
  ///
  /// Throws [ArgumentError] for a malformed fingerprint or device id or a trust
  /// other than known/trusted, [FingerprintInUseException], and
  /// [RegistryFullException]; on any throw nothing changes.
  @override
  Future<void> pin({
    required String deviceId,
    required String fingerprint,
    required String alias,
    required PeerTrust trust,
    bool replace = false,
  }) async {
    _requireLoaded();
    final fp = _requireFingerprint(fingerprint);
    if (!isValidDeviceId(deviceId)) {
      throw ArgumentError(
        'device id must be 1 to 128 characters without control characters',
      );
    }
    _requirePinLevel(trust);
    final cleanAlias = sanitizeAlias(alias);

    final changed = await registry.update((d) {
      final holder = d.contacts.values
          .where((c) => c.fingerprint == fp)
          .firstOrNull;
      if (holder != null && holder.deviceId != deviceId) {
        throw const FingerprintInUseException();
      }
      final old = d.contacts[deviceId];
      if (old == null) {
        d.contacts[deviceId] = ContactRecord(
          deviceId: deviceId,
          fingerprint: fp,
          alias: cleanAlias.isEmpty
              ? deviceId.substring(0, deviceId.length < 8 ? deviceId.length : 8)
              : cleanAlias,
          trust: trust,
          pinnedAt: clock.now().toUtc(),
        );
        return true;
      }
      if (old.fingerprint != fp) {
        if (!replace) {
          _log.warning(
            'refused to replace pinned key fp=${shortFp(old.fingerprint)} '
            'with fp=${shortFp(fp)}',
          );
          throw KeyChangedException(deviceId);
        }
        d.contacts[deviceId] = old.copyWith(
          fingerprint: fp,
          alias: cleanAlias.isEmpty ? old.alias : cleanAlias,
          trust: trust,
          pinnedAt: clock.now().toUtc(),
          hasPairKey: false,
        );
        return true;
      }
      final nextTrust = replace ? trust : _stronger(old.trust, trust);
      final nextAlias = cleanAlias.isEmpty ? old.alias : cleanAlias;
      if (nextTrust == old.trust && nextAlias == old.alias) return false;
      d.contacts[deviceId] = old.copyWith(alias: nextAlias, trust: nextTrust);
      return true;
    });
    if (changed) {
      _log.info('pinned fp=${shortFp(fp)} trust=${trust.name}');
      _emit();
    }
  }

  /// Blocks [fingerprint] (any case) for every deviceId. Idempotent. Throws
  /// [RegistryFullException] when the block list is full.
  @override
  Future<void> block(String fingerprint) async {
    _requireLoaded();
    final fp = _requireFingerprint(fingerprint);
    final changed = await registry.update((d) {
      if (d.blocked.containsKey(fp)) return false;
      d.blocked[fp] = clock.now().toUtc();
      return true;
    });
    if (changed) {
      _log.info('blocked fp=${shortFp(fp)}');
      _emit();
    }
  }

  /// Lifts a block; a contact with that fingerprint gets its stored trust back.
  @override
  Future<void> unblock(String fingerprint) async {
    _requireLoaded();
    final fp = _requireFingerprint(fingerprint);
    final changed = await registry.update((d) => d.blocked.remove(fp) != null);
    if (changed) {
      _log.info('unblocked fp=${shortFp(fp)}');
      _emit();
    }
  }

  /// Forgets the contact. Blocks are kept. Unknown ids are a no-op.
  @override
  Future<void> remove(String deviceId) async {
    _requireLoaded();
    final changed = await registry.update(
      (d) => d.contacts.remove(deviceId) != null,
    );
    if (changed) {
      _log.info('removed a contact');
      _emit();
    }
  }

  /// Sets the stored trust of an existing contact exactly (the explicit
  /// promote/demote action). [trust] must be known or trusted; an unknown
  /// [deviceId] is a [StateError].
  @override
  Future<void> setTrust(String deviceId, PeerTrust trust) async {
    _requireLoaded();
    _requirePinLevel(trust);
    final changed = await registry.update((d) {
      final old = _existing(d, deviceId);
      if (old.trust == trust) return false;
      d.contacts[deviceId] = old.copyWith(trust: trust);
      return true;
    });
    if (changed) {
      _log.info('trust changed to ${trust.name}');
      _emit();
    }
  }

  /// Records whether a K_pair exists for the contact (the secret itself lives
  /// in the SecretStore as `kpair/<deviceId>`). Unknown [deviceId]: [StateError].
  @override
  Future<void> setPairKey(String deviceId, bool present) async {
    _requireLoaded();
    final changed = await registry.update((d) {
      final old = _existing(d, deviceId);
      if (old.hasPairKey == present) return false;
      d.contacts[deviceId] = old.copyWith(hasPairKey: present);
      return true;
    });
    if (changed) _emit();
  }

  static ContactRecord _existing(RegistryDraft d, String deviceId) {
    final c = d.contacts[deviceId];
    if (c == null) throw StateError('unknown contact');
    return c;
  }

  /// Snapshot in first-pinned order. A contact whose fingerprint is blocked
  /// reports [PeerTrust.blocked].
  @override
  List<Contact> get contacts {
    _requireLoaded();
    return List.unmodifiable([
      for (final c in registry.records)
        Contact(
          deviceId: c.deviceId,
          fingerprint: c.fingerprint,
          alias: c.alias,
          trust: _effective(c),
          pinnedAt: c.pinnedAt,
          hasPairKey: c.hasPairKey,
        ),
    ]);
  }

  /// Blocked fingerprints (uppercase), oldest first.
  List<String> get blockedFingerprints {
    _requireLoaded();
    return registry.blockedFingerprints;
  }

  /// Fires after every committed change, never for no-ops or refusals.
  @override
  Stream<void> get changes => _changes.stream;

  /// Ends the `changes` stream. The store keeps working, silently. Idempotent.
  Future<void> close() async {
    if (!_changes.isClosed) await _changes.close();
  }
}

/// Contacts in `<directory>/contacts.json`.
class FileTrustStore extends RegistryTrustStore {
  /// Wraps [registry]; call [load] before use (or use [open]).
  FileTrustStore(super.registry, {super.clock});

  /// Creates the store for [directory] and loads it.
  static Future<FileTrustStore> open(
    Directory directory, {
    Clock clock = const SystemClock(),
    int maxContacts = DeviceRegistry.defaultMaxContacts,
  }) async {
    final store = FileTrustStore(
      DeviceRegistry(directory, maxContacts: maxContacts),
      clock: clock,
    );
    await store.load();
    return store;
  }
}

/// Same rules as [FileTrustStore], nothing on disk; ready to use immediately.
class InMemoryTrustStore extends RegistryTrustStore {
  InMemoryTrustStore({
    super.clock,
    int maxContacts = DeviceRegistry.defaultMaxContacts,
  }) : super(DeviceRegistry.inMemory(maxContacts: maxContacts));
}
