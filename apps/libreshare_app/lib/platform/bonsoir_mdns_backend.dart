/// mDNS / DNS-SD for the engine, over the `bonsoir` plugin (spec section 1:
/// Android NSD, Bonjour, Windows, Linux/Avahi).
///
/// Service type `_libreshare._tcp`; the TXT record (`id`, `fp` = 16 hex, `v`,
/// `pf`, spec section 4.1) is built by the engine and passed through
/// unchanged.
///
/// Fail-soft contract: **nothing in here throws into the app.** Without the OS
/// daemon (Linux without `avahi-daemon`, Windows without Bonjour/DNS-SD
/// service, a plugin that is not registered) [advertise] and [browse] log one
/// warning, flip [availability] to [MdnsAvailability.unavailable] and keep
/// retrying at [retryInterval]; multicast UDP stays the primary discovery path
/// (design 01 section 2.3).
///
/// bonsoir is wrapped behind the tiny [MdnsGateway] interface so everything
/// above it is unit-tested with a fake; [BonsoirGateway] is the thin real
/// adapter.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';
import 'package:libreshare_core/libreshare_core.dart';

import 'platform_log.dart';

/// DNS-SD service type (spec section 4.1).
const String kMdnsServiceType = '_libreshare._tcp';

/// What the backend knows about the OS mDNS daemon.
enum MdnsAvailability {
  /// Nothing was attempted yet, or nothing is wanted right now.
  unknown,

  /// Everything that was asked for is running.
  available,

  /// The daemon is missing/unreachable (or a running registration failed);
  /// retries continue in the background.
  unavailable,
}

// ------------------------------------------------------------------ gateway

/// One registered `_libreshare._tcp` service.
abstract interface class MdnsBroadcastHandle {
  /// Registers the service; completes once the OS accepted the request.
  Future<void> start();

  /// Failures after [start] (daemon went away, name collision unresolved).
  Stream<Object> get errors;

  /// Unregisters. Must be safe to call after a failed [start].
  Future<void> stop();
}

sealed class MdnsDiscoveryNotice {
  const MdnsDiscoveryNotice();
}

/// A service instance appeared (not resolved yet).
final class MdnsServiceFound extends MdnsDiscoveryNotice {
  const MdnsServiceFound(this.name);
  final String name;
}

/// A service instance resolved to addresses and a port.
final class MdnsServiceResolved extends MdnsDiscoveryNotice {
  const MdnsServiceResolved(this.peer);
  final MdnsPeer peer;
}

final class MdnsServiceLost extends MdnsDiscoveryNotice {
  const MdnsServiceLost(this.name);
  final String name;
}

final class MdnsServiceResolveFailed extends MdnsDiscoveryNotice {
  const MdnsServiceResolveFailed();
}

/// One running `_libreshare._tcp` browse.
abstract interface class MdnsDiscoveryHandle {
  Future<void> start();

  /// Found / resolved / lost notices; stream *errors* mean the browse died.
  Stream<MdnsDiscoveryNotice> get notices;

  /// Asks the OS to resolve a previously found instance.
  Future<void> resolve(String instanceName);

  Future<void> stop();
}

/// The only surface of `bonsoir` this app uses.
abstract interface class MdnsGateway {
  MdnsBroadcastHandle createBroadcast({
    required String name,
    required String type,
    required int port,
    required Map<String, String> txt,
  });

  MdnsDiscoveryHandle createDiscovery(String type);
}

// ------------------------------------------------------------------ backend

class BonsoirMdnsBackend implements MdnsBackend {
  /// [gateway] defaults to the real bonsoir adapter. [startTimeout] bounds a
  /// hung D-Bus / plugin call; [retryInterval] (`null` = never) is how often a
  /// failed registration or browse is retried.
  BonsoirMdnsBackend({
    MdnsGateway? gateway,
    this.startTimeout = const Duration(seconds: 8),
    this.retryInterval = const Duration(seconds: 30),
  }) : _gateway = gateway ?? const BonsoirGateway();

  static const PlatformLog _log = PlatformLog('mdns');

  final MdnsGateway _gateway;
  final Duration startTimeout;
  final Duration? retryInterval;

  final StreamController<bool> _availabilityChanges =
      StreamController<bool>.broadcast();
  MdnsAvailability _availability = MdnsAvailability.unknown;
  String? _unavailableReason;
  bool _disposed = false;
  Future<void> _tail = Future<void>.value();
  Timer? _retryTimer;

  // Advertising state.
  MdnsService? _wantedService;
  MdnsBroadcastHandle? _broadcast;
  StreamSubscription<Object>? _broadcastErrors;
  Object? _broadcastFailure;

  // Browsing state.
  StreamController<MdnsPeer>? _peers;
  MdnsDiscoveryHandle? _discovery;
  StreamSubscription<MdnsDiscoveryNotice>? _discoveryNotices;
  Object? _browseFailure;

  // ------------------------------------------------------------ availability

  MdnsAvailability get availability => _availability;

  /// `false` only once an attempt actually failed ("the OS daemon is missing");
  /// `true` before the first attempt.
  bool get isAvailable => _availability != MdnsAvailability.unavailable;

  /// Emits the new [isAvailable] whenever it flips.
  Stream<bool> get availabilityChanges => _availabilityChanges.stream;

  /// Human-readable hint for diagnostics ("Can't see devices?"), or `null`.
  String? get unavailableReason => _unavailableReason;

  void _recomputeAvailability() {
    final failure = _broadcastFailure ?? _browseFailure;
    final running = _broadcast != null || _discovery != null;
    final next = failure != null
        ? MdnsAvailability.unavailable
        : running
        ? MdnsAvailability.available
        : MdnsAvailability.unknown;
    _unavailableReason = failure == null ? null : _describe(failure);
    if (next == _availability) return;
    final wasAvailable = isAvailable;
    _availability = next;
    if (wasAvailable != isAvailable && !_availabilityChanges.isClosed) {
      _availabilityChanges.add(isAvailable);
    }
    _log.info('mDNS ${next.name}');
  }

  static String _describe(Object failure) {
    final hint = Platform.isLinux
        ? 'avahi-daemon is not running or not reachable'
        : 'the system DNS-SD service is not available';
    return '$hint (${failure.runtimeType})';
  }

  // ------------------------------------------------------------- MdnsBackend

  @override
  Future<void> advertise(MdnsService service) => _enqueue(() async {
    if (_disposed) return;
    _wantedService = service;
    await _stopBroadcast();
    await _startBroadcast();
    _syncRetryTimer();
  });

  @override
  Future<void> stopAdvertising() => _enqueue(() async {
    _wantedService = null;
    _broadcastFailure = null;
    await _stopBroadcast();
    _recomputeAvailability();
    _syncRetryTimer();
  });

  @override
  Stream<MdnsPeer> browse() {
    // A new browse replaces an old one (the old stream is closed and its
    // discovery stopped before the new one starts: both are queued in order).
    final previous = _peers;
    if (previous != null) {
      unawaited(
        _enqueue(() async {
          await _stopDiscoveryHandle();
          if (!previous.isClosed) await previous.close();
        }),
      );
    }
    late final StreamController<MdnsPeer> controller;
    controller = StreamController<MdnsPeer>(
      onListen: () => unawaited(_enqueue(() => _startDiscovery(controller))),
      onCancel: () => unawaited(
        _enqueue(() async {
          if (identical(_peers, controller)) await _teardownBrowse();
        }),
      ),
    );
    _peers = controller;
    return controller.stream;
  }

  @override
  Future<void> stopBrowsing() => _enqueue(() async {
    await _teardownBrowse();
    _syncRetryTimer();
  });

  /// Stops everything and releases the stream controllers. The backend must not
  /// be used afterwards.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    await _enqueue(() async {
      _wantedService = null;
      await _stopBroadcast();
      await _teardownBrowse();
    });
    await _availabilityChanges.close();
  }

  /// Re-attempts whatever failed. Runs on the retry timer; exposed for tests.
  @visibleForTesting
  Future<void> retryNow() => _enqueue(() async {
    if (_disposed) return;
    if (_wantedService != null && _broadcast == null) {
      await _startBroadcast();
    }
    final peers = _peers;
    if (peers != null && !peers.isClosed && _discovery == null) {
      await _startDiscovery(peers);
    }
    _syncRetryTimer();
  });

  // ------------------------------------------------------------- broadcasting

  Future<void> _startBroadcast() async {
    final service = _wantedService;
    if (service == null || _disposed) return;
    MdnsBroadcastHandle? handle;
    try {
      handle = _gateway.createBroadcast(
        name: sanitizeInstanceName(service.name),
        type: kMdnsServiceType,
        port: service.port,
        txt: cleanTxt(service.txt),
      );
      _broadcast = handle;
      await handle.start().timeout(startTimeout);
      _broadcastErrors = handle.errors.listen(
        (e) => _onBroadcastFailure(handle!, e),
        onError: (Object e) => _onBroadcastFailure(handle!, e),
      );
      _broadcastFailure = null;
      _log.info('advertising $kMdnsServiceType on port ${service.port}');
    } on Object catch (e) {
      _log.warning('mDNS advertise failed; multicast discovery still works', e);
      _broadcastFailure = e;
      _broadcast = null;
      if (handle != null) await _safeStop(handle.stop);
    }
    _recomputeAvailability();
  }

  void _onBroadcastFailure(MdnsBroadcastHandle handle, Object error) {
    if (!identical(_broadcast, handle)) return;
    _log.warning('mDNS registration failed', error);
    unawaited(
      _enqueue(() async {
        if (!identical(_broadcast, handle)) return;
        _broadcastFailure = error;
        await _stopBroadcast();
        _recomputeAvailability();
        _syncRetryTimer();
      }),
    );
  }

  Future<void> _stopBroadcast() async {
    final handle = _broadcast;
    _broadcast = null;
    await _broadcastErrors?.cancel();
    _broadcastErrors = null;
    if (handle != null) await _safeStop(handle.stop);
  }

  // ----------------------------------------------------------------- browsing

  Future<void> _startDiscovery(StreamController<MdnsPeer> controller) async {
    if (_disposed || !identical(_peers, controller) || controller.isClosed) {
      return;
    }
    if (_discovery != null) return;
    MdnsDiscoveryHandle? handle;
    try {
      handle = _gateway.createDiscovery(kMdnsServiceType);
      _discovery = handle;
      _discoveryNotices = handle.notices.listen(
        (n) => _onNotice(handle!, controller, n),
        onError: (Object e) => _onBrowseFailure(handle!, e),
      );
      await handle.start().timeout(startTimeout);
      _browseFailure = null;
      _log.info('browsing $kMdnsServiceType');
    } on Object catch (e) {
      _log.warning('mDNS browse failed; multicast discovery still works', e);
      _browseFailure = e;
      _discovery = null;
      await _discoveryNotices?.cancel();
      _discoveryNotices = null;
      if (handle != null) await _safeStop(handle.stop);
    }
    _recomputeAvailability();
    _syncRetryTimer();
  }

  void _onNotice(
    MdnsDiscoveryHandle handle,
    StreamController<MdnsPeer> controller,
    MdnsDiscoveryNotice notice,
  ) {
    switch (notice) {
      case MdnsServiceFound(:final name):
        unawaited(
          handle.resolve(name).catchError((Object e) {
            _log.fine('resolve failed', e);
          }),
        );
      case MdnsServiceResolved(:final peer):
        if (!controller.isClosed && controller.hasListener) {
          controller.add(peer);
        }
      case MdnsServiceLost() || MdnsServiceResolveFailed():
        break;
    }
  }

  void _onBrowseFailure(MdnsDiscoveryHandle handle, Object error) {
    if (!identical(_discovery, handle)) return;
    _log.warning('mDNS browse failed', error);
    unawaited(
      _enqueue(() async {
        if (!identical(_discovery, handle)) return;
        _browseFailure = error;
        await _stopDiscoveryHandle();
        _recomputeAvailability();
        _syncRetryTimer();
      }),
    );
  }

  Future<void> _stopDiscoveryHandle() async {
    final handle = _discovery;
    _discovery = null;
    await _discoveryNotices?.cancel();
    _discoveryNotices = null;
    if (handle != null) await _safeStop(handle.stop);
  }

  Future<void> _teardownBrowse() async {
    await _stopDiscoveryHandle();
    _browseFailure = null;
    await _closePeers();
    _recomputeAvailability();
  }

  Future<void> _closePeers() async {
    final peers = _peers;
    _peers = null;
    if (peers != null && !peers.isClosed) await peers.close();
  }

  // ------------------------------------------------------------------ helpers

  Future<void> _safeStop(Future<void> Function() stop) async {
    try {
      await stop().timeout(startTimeout);
    } on Object catch (e) {
      // After a failed start (daemon missing) a stop is expected to fail too.
      _log.fine('mDNS stop failed', e);
    }
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final next = _tail.then((_) async {
      try {
        await action();
      } on Object catch (e) {
        _log.warning('mDNS operation failed', e);
      }
    });
    _tail = next;
    return next;
  }

  void _syncRetryTimer() {
    final period = retryInterval;
    final needsRetry =
        !_disposed &&
        period != null &&
        ((_wantedService != null && _broadcast == null) ||
            (_peers != null && _discovery == null));
    if (!needsRetry) {
      _retryTimer?.cancel();
      _retryTimer = null;
    } else {
      _retryTimer ??= Timer.periodic(period, (_) => unawaited(retryNow()));
    }
  }

  /// DNS-SD instance names are one DNS label: at most 63 UTF-8 bytes, no
  /// control characters, no trailing dot (bonsoir does not enforce this).
  @visibleForTesting
  static String sanitizeInstanceName(String name) {
    var cleaned = name.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '').trim();
    while (cleaned.endsWith('.')) {
      cleaned = cleaned.substring(0, cleaned.length - 1).trimRight();
    }
    final out = StringBuffer();
    var bytes = 0;
    for (final rune in cleaned.runes) {
      final width = utf8.encode(String.fromCharCode(rune)).length;
      if (bytes + width > 63) break;
      bytes += width;
      out.writeCharCode(rune);
    }
    final result = out.toString().trimRight();
    return result.isEmpty ? 'LibreShare' : result;
  }

  /// TXT must not be empty (bonsoir issue 83) and keys must be non-empty.
  @visibleForTesting
  static Map<String, String> cleanTxt(Map<String, String> txt) {
    final cleaned = {
      for (final e in txt.entries)
        if (e.key.isNotEmpty) e.key: e.value,
    };
    return cleaned.isEmpty ? BonsoirService.defaultAttributes : cleaned;
  }

  /// Builds a peer from raw resolver output, or `null` when it is unusable
  /// (no address / port yet). IPv4 addresses first: the rest of the stack is
  /// IPv4 (design: engine prefers IPv4 as well).
  @visibleForTesting
  static MdnsPeer? peerFrom({
    required String name,
    required List<String> addresses,
    required int port,
    required Map<String, String> txt,
  }) {
    final unique = <String>{
      for (final a in addresses)
        if (a.trim().isNotEmpty) a.trim(),
    }.toList();
    if (unique.isEmpty || port < 1 || port > 65535) return null;
    bool isV4(String a) =>
        InternetAddress.tryParse(a)?.type == InternetAddressType.IPv4;
    final ordered = [...unique.where(isV4), ...unique.where((a) => !isV4(a))];
    return MdnsPeer(
      name: name,
      addresses: List.unmodifiable(ordered),
      port: port,
      txt: Map.unmodifiable(txt),
    );
  }
}

// ------------------------------------------------------------ real adapter

/// Thin adapter over the `bonsoir` plugin. Not unit-tested (needs the native
/// side); everything with logic lives in [BonsoirMdnsBackend].
class BonsoirGateway implements MdnsGateway {
  const BonsoirGateway();

  @override
  MdnsBroadcastHandle createBroadcast({
    required String name,
    required String type,
    required int port,
    required Map<String, String> txt,
  }) => _BonsoirBroadcastHandle(
    BonsoirBroadcast(
      printLogs: false,
      service: BonsoirService(
        name: name,
        type: type,
        port: port,
        attributes: txt,
      ),
    ),
  );

  @override
  MdnsDiscoveryHandle createDiscovery(String type) =>
      _BonsoirDiscoveryHandle(BonsoirDiscovery(printLogs: false, type: type));
}

class _BonsoirBroadcastHandle implements MdnsBroadcastHandle {
  _BonsoirBroadcastHandle(this._broadcast);

  final BonsoirBroadcast _broadcast;
  final StreamController<Object> _errors = StreamController<Object>.broadcast();
  StreamSubscription<BonsoirBroadcastEvent>? _events;

  @override
  Stream<Object> get errors => _errors.stream;

  @override
  Future<void> start() async {
    await _broadcast.initialize();
    _events = _broadcast.eventStream?.listen(
      (_) {},
      onError: (Object e) {
        if (!_errors.isClosed) _errors.add(e);
      },
    );
    await _broadcast.start();
  }

  @override
  Future<void> stop() async {
    await _events?.cancel();
    _events = null;
    try {
      await _broadcast.stop();
    } finally {
      await _errors.close();
    }
  }
}

class _BonsoirDiscoveryHandle implements MdnsDiscoveryHandle {
  _BonsoirDiscoveryHandle(this._discovery);

  final BonsoirDiscovery _discovery;
  final StreamController<MdnsDiscoveryNotice> _notices =
      StreamController<MdnsDiscoveryNotice>.broadcast();
  final Map<String, BonsoirService> _found = {};
  StreamSubscription<BonsoirDiscoveryEvent>? _events;

  @override
  Stream<MdnsDiscoveryNotice> get notices => _notices.stream;

  @override
  Future<void> start() async {
    await _discovery.initialize();
    _events = _discovery.eventStream?.listen(
      _onEvent,
      onError: (Object e) {
        if (!_notices.isClosed) _notices.addError(e);
      },
    );
    await _discovery.start();
  }

  void _onEvent(BonsoirDiscoveryEvent event) {
    if (_notices.isClosed) return;
    switch (event) {
      case BonsoirDiscoveryServiceFoundEvent(:final service):
        _found[service.name] = service;
        _notices.add(MdnsServiceFound(service.name));
      case BonsoirDiscoveryServiceResolvedEvent(:final service) ||
          BonsoirDiscoveryServiceUpdatedEvent(:final service):
        _found[service.name] = service;
        final peer = BonsoirMdnsBackend.peerFrom(
          name: service.name,
          addresses: service.hostAddresses,
          port: service.port,
          txt: service.attributes,
        );
        if (peer != null) _notices.add(MdnsServiceResolved(peer));
      case BonsoirDiscoveryServiceLostEvent(:final service):
        _found.remove(service.name);
        _notices.add(MdnsServiceLost(service.name));
      case BonsoirDiscoveryServiceResolveFailedEvent():
        _notices.add(const MdnsServiceResolveFailed());
      default:
        break;
    }
  }

  @override
  Future<void> resolve(String instanceName) async {
    final service = _found[instanceName];
    if (service == null) return;
    await service.resolve(_discovery.serviceResolver);
  }

  @override
  Future<void> stop() async {
    await _events?.cancel();
    _events = null;
    try {
      await _discovery.stop();
    } finally {
      await _notices.close();
    }
  }
}
