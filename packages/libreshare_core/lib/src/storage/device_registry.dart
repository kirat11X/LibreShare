/// The persisted contact book (docs/plans/inc3.md D1, section 4.1).
///
/// One JSON file, `<dir>/contacts.json`, written atomically (tmp + rename) and
/// loaded tolerantly: a corrupt file never crashes the app, it becomes an empty
/// registry and the original is kept as `contacts.json.corrupt-<n>` so nothing
/// is lost for good. The trust rules (what a pin may change) live in
/// `FileTrustStore`; this class is the storage layer under it.
///
/// File format (`v` = 1):
/// ```json
/// {"v": 1,
///  "contacts": [{"deviceId": "...", "fingerprint": "<64 uppercase hex>",
///                "alias": "...", "trust": "known|trusted",
///                "pinnedAt": "<UTC ISO 8601>", "hasPairKey": false}],
///  "blocked":  [{"fingerprint": "<64 uppercase hex>", "blockedAt": "<UTC ISO 8601>"}]}
/// ```
/// Unknown members, on the top level and inside each contact (`kPairRef`,
/// `peerAdvKey`, ... added by later increments), are preserved on rewrite.
///
/// Reads are synchronous against an immutable in-memory snapshot that is
/// replaced only after a change has reached the disk; every change goes
/// through [update], which runs one change at a time in call order.
///
/// Nothing here logs aliases, device ids or full fingerprints.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

import '../security/contracts.dart';
import 'file_secret_store.dart' show writeFileAtomically;

final Logger _log = Logger('libreshare.storage.registry');

/// Too many contacts (or blocked fingerprints) for the registry's bound.
class RegistryFullException implements Exception {
  const RegistryFullException(this.limit);
  final int limit;

  @override
  String toString() => 'RegistryFullException(limit=$limit)';
}

/// Longest alias kept, in Unicode code points.
const int kMaxAliasLength = 64;

/// A display name that is safe to store and show: control, bidi-override,
/// zero-width and other invisible format characters removed, surrounding
/// whitespace trimmed, at most [kMaxAliasLength] code points (never splitting
/// a surrogate pair). May return an empty string.
String sanitizeAlias(String raw) {
  final kept = <int>[];
  for (final r in raw.runes) {
    if (!_isStrippable(r)) kept.add(r);
  }
  var s = String.fromCharCodes(kept).trim();
  final runes = s.runes.toList();
  if (runes.length > kMaxAliasLength) {
    s = String.fromCharCodes(runes.take(kMaxAliasLength)).trimRight();
  }
  return s;
}

/// A device id is 1 to 128 UTF-16 units without control or invisible format
/// characters (LSP-1 only says "non-empty string"; production ids are UUIDs).
bool isValidDeviceId(String deviceId) =>
    deviceId.isNotEmpty &&
    deviceId.length <= 128 &&
    !deviceId.runes.any(_isStrippable);

bool _isStrippable(int r) =>
    r < 0x20 ||
    (r >= 0x7F && r <= 0x9F) ||
    r == 0xAD ||
    r == 0x061C ||
    r == 0x180E ||
    (r >= 0x200B && r <= 0x200F) ||
    (r >= 0x2028 && r <= 0x202E) ||
    (r >= 0x2060 && r <= 0x206F) ||
    (r >= 0xD800 && r <= 0xDFFF) ||
    r == 0xFEFF ||
    (r >= 0xFFF9 && r <= 0xFFFB) ||
    r == 0xFFFE ||
    r == 0xFFFF ||
    (r >= 0xE0000 && r <= 0xE007F);

/// One stored contact. [fingerprint] is 64 uppercase hex characters, [trust]
/// is [PeerTrust.known] or [PeerTrust.trusted] (blocking is a separate list),
/// [extra] holds members this version does not know, kept for round trips.
final class ContactRecord {
  ContactRecord({
    required this.deviceId,
    required this.fingerprint,
    required this.alias,
    required this.trust,
    required this.pinnedAt,
    this.hasPairKey = false,
    Map<String, Object?> extra = const {},
  }) : extra = Map.unmodifiable(extra);

  final String deviceId;
  final String fingerprint;
  final String alias;
  final PeerTrust trust;
  final DateTime pinnedAt;
  final bool hasPairKey;
  final Map<String, Object?> extra;

  ContactRecord copyWith({
    String? deviceId,
    String? fingerprint,
    String? alias,
    PeerTrust? trust,
    DateTime? pinnedAt,
    bool? hasPairKey,
    Map<String, Object?>? extra,
  }) => ContactRecord(
    deviceId: deviceId ?? this.deviceId,
    fingerprint: fingerprint ?? this.fingerprint,
    alias: alias ?? this.alias,
    trust: trust ?? this.trust,
    pinnedAt: pinnedAt ?? this.pinnedAt,
    hasPairKey: hasPairKey ?? this.hasPairKey,
    extra: extra ?? this.extra,
  );

  static const Set<String> _known = {
    'deviceId',
    'fingerprint',
    'alias',
    'trust',
    'pinnedAt',
    'hasPairKey',
  };

  Map<String, Object?> _toJson() => {
    'deviceId': deviceId,
    'fingerprint': fingerprint,
    'alias': alias,
    'trust': trust.name,
    'pinnedAt': pinnedAt.toUtc().toIso8601String(),
    'hasPairKey': hasPairKey,
    for (final e in extra.entries)
      if (!_known.contains(e.key)) e.key: e.value,
  };
}

/// Mutable copy of the registry handed to the function given to
/// [DeviceRegistry.update]. Edit it freely; nothing is stored unless the
/// function returns true and the result passes the registry's checks.
final class RegistryDraft {
  RegistryDraft._(this.contacts, this.blocked);

  /// By deviceId, in first-pinned order.
  final Map<String, ContactRecord> contacts;

  /// Blocked fingerprint (uppercase hex) -> when it was blocked.
  final Map<String, DateTime> blocked;
}

final class _State {
  _State(
    Map<String, ContactRecord> contacts,
    Map<String, DateTime> blocked,
    Map<String, Object?> topExtra,
  ) : contacts = Map.unmodifiable(contacts),
      blocked = Map.unmodifiable(blocked),
      topExtra = Map.unmodifiable(topExtra),
      byFingerprint = Map.unmodifiable({
        for (final c in contacts.values) c.fingerprint: c.deviceId,
      });

  static final _State empty = _State(const {}, const {}, const {});

  final Map<String, ContactRecord> contacts;
  final Map<String, DateTime> blocked;
  final Map<String, Object?> topExtra;
  final Map<String, String> byFingerprint;
}

class DeviceRegistry {
  /// File-backed registry in [directory] (created on the first write). Call
  /// [load] before use.
  DeviceRegistry(
    Directory directory, {
    this.fileName = 'contacts.json',
    this.maxContacts = defaultMaxContacts,
    this.maxBlocked = defaultMaxBlocked,
  }) : _directory = directory;

  /// A registry that never touches the disk (tests, ephemeral engines);
  /// already loaded.
  DeviceRegistry.inMemory({
    this.maxContacts = defaultMaxContacts,
    this.maxBlocked = defaultMaxBlocked,
  }) : _directory = null,
       fileName = 'contacts.json',
       _loaded = true;

  static const int defaultMaxContacts = 2000;
  static const int defaultMaxBlocked = 2000;
  static const int schemaVersion = 1;

  /// Larger files are treated as corrupt (2000 contacts are about 0.7 MB).
  static const int maxFileBytes = 4 * 1024 * 1024;

  static final RegExp _fingerprintRe = RegExp(r'^[0-9A-F]{64}$');

  final Directory? _directory;
  final String fileName;
  final int maxContacts;
  final int maxBlocked;

  _State _state = _State.empty;
  bool _loaded = false;
  int _writes = 0;
  Future<void> _tail = Future<void>.value();

  /// The backing file, or null for an in-memory registry.
  File? get file {
    final d = _directory;
    return d == null
        ? null
        : File('${d.path}${Platform.pathSeparator}$fileName');
  }

  bool get isLoaded => _loaded;

  /// Number of times the file was successfully rewritten (for tests).
  int get writeCount => _writes;

  /// Unmodifiable snapshot, in first-pinned order.
  List<ContactRecord> get records => List.unmodifiable(_state.contacts.values);

  ContactRecord? byDeviceId(String deviceId) => _state.contacts[deviceId];

  /// [fingerprint] must be uppercase hex.
  ContactRecord? byFingerprint(String fingerprint) {
    final id = _state.byFingerprint[fingerprint];
    return id == null ? null : _state.contacts[id];
  }

  /// [fingerprint] must be uppercase hex.
  bool isBlocked(String fingerprint) => _state.blocked.containsKey(fingerprint);

  List<String> get blockedFingerprints =>
      List.unmodifiable(_state.blocked.keys);

  DateTime? blockedAt(String fingerprint) => _state.blocked[fingerprint];

  Future<T> _serial<T>(Future<T> Function() op) {
    final next = _tail.then((_) => op());
    _tail = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  /// Reads the file. Idempotent. A missing file is an empty registry; a corrupt
  /// one is moved to `contacts.json.corrupt-<n>` and the registry starts empty
  /// (warning logged with the exception type only); a well-formed file with a
  /// few unusable entries keeps the usable ones and a copy of the original. An
  /// operating-system error while reading (for example permissions) is not
  /// corruption and is rethrown.
  Future<void> load() => _serial(_load);

  Future<void> _load() async {
    final f = file;
    if (f == null) return;
    final type = await FileSystemEntity.type(f.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      _state = _State.empty;
      _loaded = true;
      return;
    }
    List<int> bytes;
    _Parsed parsed;
    try {
      if (type != FileSystemEntityType.file) throw const FormatException();
      if (await f.length() > maxFileBytes) throw const FormatException();
      bytes = await f.readAsBytes();
      parsed = _Parsed.parse(
        jsonDecode(utf8.decode(bytes)),
        maxContacts,
        maxBlocked,
      );
    } on FileSystemException {
      rethrow;
    } on Object catch (e) {
      _log.warning(
        'contacts file unreadable (${e.runtimeType}); kept as a backup',
      );
      await _backup(f, bytes: null);
      _state = _State.empty;
      _loaded = true;
      return;
    }
    if (parsed.skipped > 0) {
      _log.warning(
        'contacts file had ${parsed.skipped} unusable entries; original kept as a backup',
      );
      await _backup(f, bytes: bytes);
    }
    _state = parsed.state;
    _loaded = true;
  }

  /// Moves (bytes == null) or copies [f] to the first free `<file>.corrupt-<n>`.
  /// A copy is skipped when an identical backup already exists, so repeated
  /// loads of the same file do not pile up backups.
  Future<void> _backup(File f, {required List<int>? bytes}) async {
    try {
      for (var n = 1; n <= 1000; n++) {
        final target = '${f.path}.corrupt-$n';
        final type = await FileSystemEntity.type(target, followLinks: false);
        if (type == FileSystemEntityType.notFound) {
          if (bytes == null) {
            if (await FileSystemEntity.isDirectory(f.path)) {
              await Directory(f.path).rename(target);
            } else {
              await f.rename(target);
            }
          } else {
            await f.copy(target);
          }
          return;
        }
        if (bytes != null && type == FileSystemEntityType.file) {
          final other = await File(target).readAsBytes();
          if (_sameBytes(other, bytes)) return;
        }
      }
      _log.warning('too many contacts backups; the original was not kept');
    } on Object catch (e) {
      _log.warning(
        'could not keep a backup of the contacts file: ${e.runtimeType}',
      );
    }
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Applies [change] to a draft copy and, if it returns true, checks the
  /// result, writes it atomically and only then makes it visible. Changes run
  /// one at a time in call order, so a check inside [change] cannot race
  /// another update. Throws [StateError] before [load], [RegistryFullException]
  /// over the bounds, and [StateError] for a draft that breaks an invariant
  /// (fingerprint not 64 uppercase hex, two contacts with one fingerprint, a
  /// map key that is not the record's deviceId, trust other than known or
  /// trusted); on any failure nothing changes. Returns false when [change]
  /// reported no change.
  Future<bool> update(bool Function(RegistryDraft draft) change) =>
      _serial(() async {
        if (!_loaded) {
          throw StateError('DeviceRegistry.update called before load()');
        }
        final draft = RegistryDraft._(
          Map.of(_state.contacts),
          Map.of(_state.blocked),
        );
        if (!change(draft)) return false;
        if (draft.contacts.length > maxContacts) {
          throw RegistryFullException(maxContacts);
        }
        if (draft.blocked.length > maxBlocked) {
          throw RegistryFullException(maxBlocked);
        }
        _checkInvariants(draft);
        final next = _State(draft.contacts, draft.blocked, _state.topExtra);
        if (_directory != null) await _write(next);
        _state = next;
        return true;
      });

  void _checkInvariants(RegistryDraft d) {
    final seen = <String>{};
    for (final e in d.contacts.entries) {
      final c = e.value;
      if (e.key != c.deviceId ||
          c.deviceId.isEmpty ||
          !_fingerprintRe.hasMatch(c.fingerprint) ||
          !seen.add(c.fingerprint) ||
          (c.trust != PeerTrust.known && c.trust != PeerTrust.trusted)) {
        throw StateError('contact registry invariant violated');
      }
    }
    for (final fp in d.blocked.keys) {
      if (!_fingerprintRe.hasMatch(fp)) {
        throw StateError('contact registry invariant violated');
      }
    }
  }

  Future<void> _write(_State s) async {
    final dir = _directory!;
    await dir.create(recursive: true);
    final json = <String, Object?>{
      for (final e in s.topExtra.entries)
        if (e.key != 'v' && e.key != 'contacts' && e.key != 'blocked')
          e.key: e.value,
      'v': schemaVersion,
      'contacts': [for (final c in s.contacts.values) c._toJson()],
      'blocked': [
        for (final e in s.blocked.entries)
          {
            'fingerprint': e.key,
            'blockedAt': e.value.toUtc().toIso8601String(),
          },
      ],
    };
    await writeFileAtomically(
      file!,
      utf8.encode(const JsonEncoder.withIndent('  ').convert(json)),
    );
    _writes++;
  }
}

final class _Parsed {
  _Parsed(this.state, this.skipped);

  final _State state;
  final int skipped;

  /// Throws [FormatException] when the document as a whole is unusable.
  static _Parsed parse(Object? root, int maxContacts, int maxBlocked) {
    if (root is! Map || root['v'] != DeviceRegistry.schemaVersion) {
      throw const FormatException();
    }
    final rawContacts = root['contacts'];
    final rawBlocked = root['blocked'];
    if ((rawContacts != null && rawContacts is! List) ||
        (rawBlocked != null && rawBlocked is! List)) {
      throw const FormatException();
    }

    var skipped = 0;
    final contacts = <String, ContactRecord>{};
    final fingerprints = <String>{};
    for (final raw in (rawContacts as List<Object?>?) ?? const <Object?>[]) {
      final c = _contact(raw);
      if (c == null ||
          contacts.containsKey(c.deviceId) ||
          fingerprints.contains(c.fingerprint) ||
          contacts.length >= maxContacts) {
        skipped++;
        continue;
      }
      contacts[c.deviceId] = c;
      fingerprints.add(c.fingerprint);
    }

    final blocked = <String, DateTime>{};
    for (final raw in (rawBlocked as List<Object?>?) ?? const <Object?>[]) {
      String? fp;
      var at = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
      if (raw is String) {
        fp = raw.toUpperCase();
      } else if (raw is Map && raw['fingerprint'] is String) {
        fp = (raw['fingerprint'] as String).toUpperCase();
        final parsed = raw['blockedAt'] is String
            ? DateTime.tryParse(raw['blockedAt'] as String)
            : null;
        if (parsed != null) at = parsed.toUtc();
      }
      if (fp == null ||
          !DeviceRegistry._fingerprintRe.hasMatch(fp) ||
          blocked.length >= maxBlocked) {
        skipped++;
        continue;
      }
      blocked.putIfAbsent(fp, () => at);
    }

    final topExtra = <String, Object?>{
      for (final e in root.entries)
        if (e.key is String &&
            e.key != 'v' &&
            e.key != 'contacts' &&
            e.key != 'blocked')
          e.key as String: e.value,
    };
    return _Parsed(_State(contacts, blocked, topExtra), skipped);
  }

  static ContactRecord? _contact(Object? raw) {
    if (raw is! Map) return null;
    final deviceId = raw['deviceId'];
    final fingerprint = raw['fingerprint'];
    final alias = raw['alias'];
    final trust = raw['trust'];
    final pinnedAt = raw['pinnedAt'];
    final hasPairKey = raw['hasPairKey'] ?? false;
    if (deviceId is! String || !isValidDeviceId(deviceId)) return null;
    if (fingerprint is! String) return null;
    final fp = fingerprint.toUpperCase();
    if (!DeviceRegistry._fingerprintRe.hasMatch(fp)) return null;
    if (alias is! String) return null;
    final PeerTrust level;
    if (trust == 'known') {
      level = PeerTrust.known;
    } else if (trust == 'trusted') {
      level = PeerTrust.trusted;
    } else {
      return null;
    }
    if (pinnedAt is! String) return null;
    final at = DateTime.tryParse(pinnedAt);
    if (at == null) return null;
    if (hasPairKey is! bool) return null;
    return ContactRecord(
      deviceId: deviceId,
      fingerprint: fp,
      alias: sanitizeAlias(alias),
      trust: level,
      pinnedAt: at.toUtc(),
      hasPairKey: hasPairKey,
      extra: {
        for (final e in raw.entries)
          if (e.key is String && !ContactRecord._known.contains(e.key))
            e.key as String: e.value,
      },
    );
  }
}
