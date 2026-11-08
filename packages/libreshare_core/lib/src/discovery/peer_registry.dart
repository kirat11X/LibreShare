/// Live peer table shared by every discovery source (multicast, mDNS, subnet
/// scan, manual/QR, `POST /register`). Implements [PeerSink]; exposes the same
/// `devices`/`events`/`current` surface as [DeviceDiscovery].
///
/// Peers expire [expiry] (default 90 s, spec §4.2) after they were last seen.
/// Pure logic over an injectable [Clock]; the optional sweep [Timer] only
/// calls [sweep], so tests can drive expiry by moving a fake clock.
library;

import 'dart:async';
import 'dart:typed_data';

import '../clock.dart';
import '../model/device.dart';
import '../security/cert_factory.dart' show parseCertificate;
import '../security/contracts.dart';
import 'device_discovery.dart';

class PeerRegistry implements PeerSink {
  PeerRegistry({
    required this.selfDeviceId,
    this.clock = const SystemClock(),
    this.expiry = const Duration(seconds: 90),
    this.maxPeers = 1024,
    this.trust,
  }) {
    if (maxPeers <= 0) {
      throw ArgumentError.value(maxPeers, 'maxPeers', 'must be > 0');
    }
  }

  /// Own deviceId; [seen] ignores it so we never list ourselves.
  final String selfDeviceId;
  final Clock clock;
  final Duration expiry;

  /// Secure profile: the contacts' pinned fingerprints. Looked up at every
  /// [seen], so a pin made at run time (after a SAS) is honoured at once and
  /// beats any earlier trust-on-first-use memory (LSP-1 4.2 rule 7).
  final TrustStore? trust;

  /// Upper bound on tracked peers. When full, the least recently seen peer is
  /// evicted (and reported as [DeviceLost]) to make room.
  final int maxPeers;

  /// Most addresses remembered per peer in `info.addrs`.
  static const int maxAddrsPerPeer = 16;

  /// Bound on remembered fingerprints of peers that are no longer listed.
  static const int _maxFingerprintMemory = 4096;

  // Insertion-ordered: first-seen order, stable across updates.
  final Map<String, _Entry> _peers = {};

  // deviceId -> first non-empty fingerprint seen (trust-on-first-use baseline).
  // Outlives the peer's presence so a re-appearing peer with another
  // fingerprint is still flagged. Oldest entries are forgotten first.
  final Map<String, String> _knownFingerprints = {};

  // Fingerprint (uppercase hex) -> DER of a validated certificate seen in a TLS
  // handshake or a verified proof; lets the discovery verify `bye` signatures.
  final Map<String, Uint8List> _certs = {};
  static const int _maxCertMemory = 1024;

  // Per-source cap on top of the global one, so that a flood of distinct peers
  // from one address evicts only its own certificates (R4d). Bookkeeping is
  // bounded by [_certs]: one source entry per stored certificate, one counter
  // per source that holds at least one.
  static const int maxCertsPerSource = 64;
  static const String _unknownSource = '';
  final Map<String, String> _certSource = {};
  final Map<String, int> _certSourceCount = {};

  final StreamController<List<DiscoveredDevice>> _devices =
      StreamController<List<DiscoveredDevice>>.broadcast();
  final StreamController<DiscoveryEvent> _events =
      StreamController<DiscoveryEvent>.broadcast();

  Timer? _timer;
  bool _disposed = false;

  /// Snapshot of live peers; emits after every change. Not replayed to late
  /// listeners; read [current] for the present state.
  Stream<List<DiscoveredDevice>> get devices => _devices.stream;
  Stream<DiscoveryEvent> get events => _events.stream;

  /// Unmodifiable snapshot of live peers in first-seen order.
  List<DiscoveredDevice> get current =>
      List.unmodifiable([for (final e in _peers.values) e.device]);

  /// The live peer with [deviceId], or null.
  DiscoveredDevice? byId(String deviceId) => _peers[deviceId]?.device;

  /// Whether the periodic sweep timer is running.
  bool get isRunning => _timer != null;

  /// Starts the periodic [sweep] (every [sweepInterval]). Idempotent.
  void start({Duration sweepInterval = const Duration(seconds: 5)}) {
    if (_disposed || _timer != null) return;
    _timer = Timer.periodic(sweepInterval, (_) => sweep());
  }

  /// Stops the periodic sweep; the table and streams stay usable.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Stops the sweep and closes the streams. [seen] becomes a no-op.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    stop();
    unawaited(_devices.close());
    unawaited(_events.close());
    _peers.clear();
  }

  @override
  void seen(DeviceInfo info, String address, DiscoverySource source) {
    if (_disposed) return;
    final id = info.deviceId;
    if (id.isEmpty || id == selfDeviceId) return;

    final now = clock.now();
    final existing = _peers[id];

    // --- fingerprint (TOFU baseline; Inc 3 consumes fingerprintChanged) ---
    final fp = info.fingerprint.toUpperCase();
    final pinned = _pinnedFingerprint(id);
    if (pinned != null && _knownFingerprints[id] != pinned) {
      _remember(id, pinned); // the pin beats earlier TOFU memory
    }
    final baseline = pinned ?? _knownFingerprints[id];
    if (pinned != null && existing != null && fp != pinned) {
      // A pinned device is never overwritten by a datagram with an empty or a
      // different fingerprint (LSP-1 4.2 rule 7): the entry stays as it was.
      // Only a different non-empty fingerprint raises the warning flag.
      if (fp.isNotEmpty && !existing.fingerprintChanged) {
        existing.fingerprintChanged = true;
        _events.add(DeviceUpdated(existing.device));
        _emitSnapshot();
      }
      return;
    }
    var changed = false;
    var effective = info;
    if (fp.isNotEmpty) {
      if (baseline == null) {
        _remember(id, fp);
      } else if (baseline != fp) {
        changed = true;
      }
      if (fp != info.fingerprint) effective = _copy(effective, fingerprint: fp);
    } else if (baseline != null) {
      // A weaker source (mDNS carries only 16 hex, a probe may know nothing)
      // must not blank a fingerprint we already know, nor raise a flag.
      effective = _copy(
        effective,
        fingerprint: existing?.device.info.fingerprint ?? baseline,
      );
      changed = existing?.fingerprintChanged ?? false;
    }

    final keepManual =
        existing != null &&
        _exempt(existing.device.source) &&
        !_exempt(source) &&
        existing.device.address != address;

    // --- addresses: heard from a new place => keep the old ones as candidates
    if (keepManual) {
      effective = _copy(effective, addrs: existing.device.info.addrs);
    } else if (existing != null && existing.device.address != address) {
      effective = _copy(
        effective,
        addrs: _mergeAddrs(effective.addrs, existing.device),
      );
    }

    final device = DiscoveredDevice(
      info: effective,
      address: keepManual ? existing.device.address : address,
      lastSeen: now,
      source: keepManual ? existing.device.source : source,
    );

    if (existing == null) {
      final evicted = _makeRoom();
      _peers[id] = _Entry(device, changed);
      if (evicted != null) _events.add(DeviceLost(evicted));
      _events.add(DeviceFound(device));
    } else {
      existing
        ..device = device
        ..fingerprintChanged = changed;
      _events.add(DeviceUpdated(device));
    }
    _emitSnapshot();
  }

  /// Removes the live peer [deviceId] (e.g. after a verified `bye`), emitting
  /// [DeviceLost] and a fresh snapshot. The fingerprint baseline is kept.
  /// False when the peer is unknown, empty or ourselves, or after [dispose].
  bool remove(String deviceId) {
    if (_disposed || deviceId.isEmpty || deviceId == selfDeviceId) return false;
    final gone = _peers.remove(deviceId);
    if (gone == null) return false;
    _events.add(DeviceLost(gone.device));
    _emitSnapshot();
    return true;
  }

  /// Remembers [certDer] (a certificate learned from a TLS handshake or a
  /// verified `X-LS-Auth` proof) so that a `bye` of that fingerprint can be
  /// verified. True only for a valid LibreShare certificate (strict profile,
  /// valid self-signature); false, without throwing, for anything else.
  bool learnCertificate(Uint8List certDer) {
    if (_disposed) return false;
    try {
      final cert = parseCertificate(certDer, verifySelfSignature: true);
      final fp = cert.fingerprint.toUpperCase();
      _dropCert(fp);
      final source = _sourceOf(fp, cert.subjectCn);
      _certs[fp] = Uint8List.fromList(certDer);
      _certSource[fp] = source;
      _certSourceCount[source] = (_certSourceCount[source] ?? 0) + 1;
      while ((_certSourceCount[source] ?? 0) > maxCertsPerSource) {
        _dropCert(_certs.keys.firstWhere((k) => _certSource[k] == source));
      }
      while (_certs.length > _maxCertMemory) {
        _dropCert(_certs.keys.first);
      }
      return true;
    } on Object {
      return false;
    }
  }

  // Address of the listed peer that IS the certificate's owner: the entry whose
  // deviceId equals the certificate's subject CN and whose fingerprint is [fp].
  // Entries that merely claim [fp] under another deviceId do not count (a
  // fingerprint is public, so a claim must not steer the attribution). The
  // shared bucket is used when no such entry is listed.
  String _sourceOf(String fp, String? subjectCn) {
    if (subjectCn == null) return _unknownSource;
    final e = _peers[subjectCn];
    if (e == null || e.device.info.fingerprint.toUpperCase() != fp) {
      return _unknownSource;
    }
    return e.device.address;
  }

  void _dropCert(String fp) {
    if (_certs.remove(fp) == null) return;
    final source = _certSource.remove(fp);
    final n = (_certSourceCount[source] ?? 1) - 1;
    if (n <= 0) {
      _certSourceCount.remove(source);
    } else {
      _certSourceCount[source!] = n;
    }
  }

  /// The certificate learned for [fingerprint], or null.
  Uint8List? certificateFor(String fingerprint) =>
      _certs[fingerprint.toUpperCase()];

  String? _pinnedFingerprint(String id) {
    final t = trust;
    if (t == null) return null;
    try {
      final p = t.classify(id, '').pinnedFingerprint;
      return (p == null || p.isEmpty) ? null : p.toUpperCase();
    } on Object {
      return null; // a store that is not loaded must not break discovery
    }
  }

  /// True while the peer's current fingerprint differs from the first one this
  /// registry learned for that deviceId. Never true for a peer that announced
  /// no fingerprint (pre-TLS) or one we have not seen.
  bool fingerprintChanged(String deviceId) =>
      _peers[deviceId]?.fingerprintChanged ?? false;

  /// The fingerprint first learned for [deviceId] (the TOFU baseline), if any.
  String? knownFingerprint(String deviceId) => _knownFingerprints[deviceId];

  /// Adopts the peer's current fingerprint as the new baseline and clears
  /// [fingerprintChanged] (after the user confirmed the change). Returns false
  /// when the peer is unknown.
  bool acceptFingerprint(String deviceId) {
    final e = _peers[deviceId];
    if (e == null) return false;
    final fp = e.device.info.fingerprint;
    if (fp.isNotEmpty) _remember(deviceId, fp);
    e.fingerprintChanged = false;
    return true;
  }

  /// Removes peers not seen for at least [expiry], emitting [DeviceLost] for
  /// each. Returns how many were removed.
  int sweep() {
    if (_disposed || _peers.isEmpty) return 0;
    final now = clock.now();
    final expired = <String>[
      for (final entry in _peers.entries)
        if (!_exempt(entry.value.device.source) &&
            now.difference(entry.value.device.lastSeen) >= expiry)
          entry.key,
    ];
    for (final id in expired) {
      final gone = _peers.remove(id)!.device;
      _events.add(DeviceLost(gone));
    }
    if (expired.isNotEmpty) _emitSnapshot();
    return expired.length;
  }

  // Peers added by IP, link or QR have no announcer to keep them fresh; they
  // leave only through remove() (latest source wins).
  static bool _exempt(DiscoverySource s) =>
      s == DiscoverySource.manual || s == DiscoverySource.qr;

  // Evicts the least recently seen peer when the table is full.
  DiscoveredDevice? _makeRoom() {
    if (_peers.length < maxPeers) return null;
    // Sweepable sources go first; manual/QR peers only when nothing else is left.
    String? oldestId;
    DateTime? oldest;
    var oldestExempt = true;
    for (final entry in _peers.entries) {
      final t = entry.value.device.lastSeen;
      final exempt = _exempt(entry.value.device.source);
      final better =
          oldest == null ||
          (oldestExempt && !exempt) ||
          (oldestExempt == exempt && t.isBefore(oldest));
      if (better) {
        oldest = t;
        oldestId = entry.key;
        oldestExempt = exempt;
      }
    }
    return _peers.remove(oldestId)?.device;
  }

  void _remember(String id, String fp) {
    _knownFingerprints.remove(id); // re-insert last => most recent
    _knownFingerprints[id] = fp;
    while (_knownFingerprints.length > _maxFingerprintMemory) {
      _knownFingerprints.remove(_knownFingerprints.keys.first);
    }
  }

  void _emitSnapshot() {
    if (_devices.hasListener) _devices.add(current);
  }

  // Fresh announcement addresses first, then where we heard the peer before,
  // then whatever we knew; de-duplicated by ip and bounded.
  static List<DeviceAddress> _mergeAddrs(
    List<DeviceAddress> fresh,
    DiscoveredDevice old,
  ) {
    final merged = <DeviceAddress>[];
    final seenIps = <String>{};
    void add(DeviceAddress a) {
      if (merged.length < maxAddrsPerPeer && seenIps.add(a.ip)) merged.add(a);
    }

    fresh.forEach(add);
    final oldIface = old.info.addrs
        .where((a) => a.ip == old.address)
        .map((a) => a.iface)
        .firstOrNull;
    add(DeviceAddress(old.address, iface: oldIface ?? 'unknown'));
    old.info.addrs.forEach(add);
    return merged;
  }

  static DeviceInfo _copy(
    DeviceInfo i, {
    String? fingerprint,
    List<DeviceAddress>? addrs,
  }) => DeviceInfo(
    deviceId: i.deviceId,
    alias: i.alias,
    platform: i.platform,
    deviceType: i.deviceType,
    fingerprint: fingerprint ?? i.fingerprint,
    port: i.port,
    addrs: addrs ?? i.addrs,
    caps: i.caps,
    version: i.version,
  );
}

class _Entry {
  _Entry(this.device, this.fingerprintChanged);
  DiscoveredDevice device;
  bool fingerprintChanged;
}
