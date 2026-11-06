/// Every transfer the UI knows about, both directions: the live progress
/// (per file and overall, speed, ETA), the incoming consent requests and the
/// final outcome. Fed by the engine's `events` (incoming sessions) and by the
/// per-send event stream of the engine's [OutgoingSend] handle (outgoing
/// sessions).
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:libreshare_core/libreshare_core.dart';

import '../services/file_picker_service.dart';
import '../services/paths.dart';
import 'engine_provider.dart';
import 'platform_providers.dart';

enum TransferDirection { outgoing, incoming }

enum TransferPhase {
  /// Outgoing: hashing / finding the device.
  preparing,

  /// Incoming: the user has to accept or reject.
  awaitingConsent,

  /// Outgoing: the other side has not answered yet.
  waiting,
  transferring,
  completed,
  failed,
  cancelled,
  rejected,
}

class TransferFile {
  const TransferFile({
    required this.id,
    required this.name,
    required this.size,
    this.done = 0,
    this.savedPath,
  });

  final String id;
  final String name;
  final int size;
  final int done;

  /// Incoming files: where the finished file was saved.
  final String? savedPath;

  double get fraction =>
      size <= 0 ? (done > 0 ? 1 : 0) : (done / size).clamp(0, 1);

  bool get isDone => size <= 0 ? savedPath != null : done >= size;

  TransferFile copyWith({int? done, String? savedPath}) => TransferFile(
    id: id,
    name: name,
    size: size,
    done: done ?? this.done,
    savedPath: savedPath ?? this.savedPath,
  );
}

class TransferView {
  const TransferView({
    required this.key,
    required this.direction,
    required this.phase,
    required this.peerAlias,
    required this.peerPlatform,
    required this.peerAddress,
    required this.files,
    required this.createdAt,
    this.sessionId,
    this.failure,
    this.localFileError = false,
    this.finishedAt,
    this.consentDeadline,
    this.speed = 0,
    this.wasTransferring = false,
    this.sasCode,
    this.keyChanged = false,
    this.insecurePeer = false,
    this.refusal,
    this.pinRequired = false,
  });

  /// Stable id for routing. The session id for incoming transfers, a local
  /// counter for outgoing ones (the session id does not exist yet).
  final String key;
  final String? sessionId;
  final TransferDirection direction;
  final TransferPhase phase;
  final String peerAlias;
  final String peerPlatform;
  final String peerAddress;
  final List<TransferFile> files;
  final FailureReason? failure;
  final bool localFileError;
  final DateTime createdAt;
  final DateTime? finishedAt;

  /// Incoming: when the request expires unanswered.
  final DateTime? consentDeadline;

  /// Bytes per second over the last few seconds.
  final double speed;

  /// Data had started to move before the transfer ended (tells "could not
  /// reach" from "connection lost").
  final bool wasTransferring;

  /// Verification code (e.g. `482913`) for Increment 3 SAS verification.
  final String? sasCode;

  /// Whether the peer presented a security key different from the pinned one.
  final bool keyChanged;

  /// Whether the peer does not support secure transfer (legacy plaintext).
  final bool insecurePeer;

  /// Wire refusal code if the peer refused with an LsErrorCode.
  final LsErrorCode? refusal;

  /// Whether a 6-digit PIN is required to proceed.
  final bool pinRequired;

  bool get isOutgoing => direction == TransferDirection.outgoing;

  bool get isFinished =>
      phase == TransferPhase.completed ||
      phase == TransferPhase.failed ||
      phase == TransferPhase.cancelled ||
      phase == TransferPhase.rejected;

  bool get isActive => !isFinished;

  int get bytesTotal => files.fold(0, (a, f) => a + f.size);

  int get bytesDone =>
      files.fold(0, (a, f) => a + (f.done > f.size ? f.size : f.done));

  double get fraction {
    final total = bytesTotal;
    if (total <= 0) return phase == TransferPhase.completed ? 1 : 0;
    return (bytesDone / total).clamp(0, 1);
  }

  Duration? get eta {
    if (phase != TransferPhase.transferring || speed < 1) return null;
    final left = bytesTotal - bytesDone;
    if (left <= 0) return Duration.zero;
    return Duration(seconds: (left / speed).ceil());
  }

  /// Incoming: the folder the files landed in.
  String? get savedFolder {
    final path = files.map((f) => f.savedPath).whereType<String>().firstOrNull;
    return path == null ? null : parentDir(path);
  }

  List<String> get savedPaths =>
      files.map((f) => f.savedPath).whereType<String>().toList();

  TransferView copyWith({
    TransferPhase? phase,
    String? sessionId,
    List<TransferFile>? files,
    FailureReason? failure,
    bool? localFileError,
    DateTime? finishedAt,
    double? speed,
    bool? wasTransferring,
    String? sasCode,
    bool? keyChanged,
    bool? insecurePeer,
    LsErrorCode? refusal,
    bool? pinRequired,
  }) => TransferView(
    key: key,
    direction: direction,
    phase: phase ?? this.phase,
    peerAlias: peerAlias,
    peerPlatform: peerPlatform,
    peerAddress: peerAddress,
    files: files ?? this.files,
    createdAt: createdAt,
    sessionId: sessionId ?? this.sessionId,
    failure: failure ?? this.failure,
    localFileError: localFileError ?? this.localFileError,
    finishedAt: finishedAt ?? this.finishedAt,
    consentDeadline: consentDeadline,
    speed: speed ?? this.speed,
    wasTransferring: wasTransferring ?? this.wasTransferring,
    sasCode: sasCode ?? this.sasCode,
    keyChanged: keyChanged ?? this.keyChanged,
    insecurePeer: insecurePeer ?? this.insecurePeer,
    refusal: refusal ?? this.refusal,
    pinRequired: pinRequired ?? this.pinRequired,
  );
}

class TransfersNotifier extends Notifier<List<TransferView>> {
  // Kept across engine restarts (build runs again, the instance stays).
  List<TransferView> _items = const [];
  final Map<String, OutgoingSend> _sends = {};
  // What a PIN retry needs (the PIN itself is never kept).
  final Map<String, (DiscoveredDevice, List<PickedFile>)> _retryInfo = {};
  final Map<String, String> _sessionToKey = {};
  final Map<String, List<(DateTime, int)>> _samples = {};
  int _seq = 0;

  static const Duration _speedWindow = Duration(seconds: 4);

  Clock get _clock => ref.read(clockProvider);

  @override
  List<TransferView> build() {
    final engine = ref.watch(engineOrNullProvider);
    if (engine != null) {
      final sub = engine.events.listen(_onEngineEvent);
      ref.onDispose(() => unawaited(sub.cancel()));
    }
    return _items;
  }

  void _set(List<TransferView> next) {
    _items = next;
    if (ref.mounted) state = next;
  }

  TransferView? find(String key) =>
      _items.where((t) => t.key == key).firstOrNull;

  void _replace(String key, TransferView Function(TransferView) f) {
    var changed = false;
    final next = [
      for (final t in _items)
        if (t.key == key)
          () {
            changed = true;
            return f(t);
          }()
        else
          t,
    ];
    if (changed) _set(next);
  }

  // ------------------------------------------------------------ outgoing

  /// Starts sending [picked] to [device]. Returns the key of the new transfer
  /// (route `/transfer/<key>`).
  String startSend(DiscoveredDevice device, List<PickedFile> picked) {
    final engine = ref.read(engineOrNullProvider);
    if (engine == null) throw StateError('engine not running');
    if (picked.isEmpty) throw ArgumentError('nothing to send');
    final key = 'out-${++_seq}';

    // The sender sorts smallest first (ties by input order) and numbers the
    // files f1, f2, ...; mirror that so progress events can be named.
    final order = List<int>.generate(picked.length, (i) => i)
      ..sort((a, b) {
        final c = picked[a].size.compareTo(picked[b].size);
        return c != 0 ? c : a.compareTo(b);
      });
    final files = [
      for (var i = 0; i < order.length; i++)
        TransferFile(
          id: 'f${i + 1}',
          name: picked[order[i]].name,
          size: picked[order[i]].size,
        ),
    ];

    final view = TransferView(
      key: key,
      direction: TransferDirection.outgoing,
      phase: TransferPhase.preparing,
      peerAlias: device.info.alias,
      peerPlatform: device.info.platform,
      peerAddress: device.address,
      files: files,
      createdAt: _clock.now(),
    );
    _set([view, ..._items]);

    final send = engine.beginSendTo(device, [
      for (final p in picked) File(p.path),
    ]);
    _sends[key] = send;
    _retryInfo[key] = (device, List.of(picked));
    unawaited(_drive(key, send));
    return key;
  }

  /// Sends again to the same device after a `pinRequired` refusal, with [pin]
  /// (6 digits). The failed view keeps its key and goes back to preparing; the
  /// PIN is only passed on to the engine, never stored or logged.
  bool retryWithPin(String key, String pin) {
    final engine = ref.read(engineOrNullProvider);
    final info = _retryInfo[key];
    final old = find(key);
    if (engine == null || info == null || old == null) return false;
    // Only a finished view that asks for a PIN (the one the dialog opens for).
    if (!old.isFinished || !old.pinRequired || _sends.containsKey(key)) {
      return false;
    }
    if (!RegExp(r'^[0-9]{6}$').hasMatch(pin)) return false;
    _replace(
      key,
      (_) => TransferView(
        key: key,
        direction: TransferDirection.outgoing,
        phase: TransferPhase.preparing,
        peerAlias: old.peerAlias,
        peerPlatform: old.peerPlatform,
        peerAddress: old.peerAddress,
        files: [for (final f in old.files) f.copyWith(done: 0)],
        createdAt: _clock.now(),
      ),
    );
    final OutgoingSend send;
    try {
      send = engine.beginSendTo(info.$1, [
        for (final p in info.$2) File(p.path),
      ], pin: pin);
    } on Object {
      _replace(key, (_) => old); // back to the finished view; dismiss works
      return false;
    }
    _sends[key] = send;
    unawaited(_drive(key, send));
    return true;
  }

  Future<void> _drive(String key, OutgoingSend send) async {
    // A failure is applied below, together with the peer's refusal code;
    // applying SessionFinished first would show a generic failure text.
    final sub = send.events.listen((e) {
      if (e is SessionFinished && !e.success) return;
      _applyEvent(key, e);
    });
    SendResult? result;
    var localFileError = false;
    var insecurePeer = false;
    var keyChanged = false;
    try {
      result = await send.result;
      // Every event of this send was delivered before the backstop below.
      await sub.asFuture<void>().timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
    } on FileSystemException {
      // A picked file vanished or is unreadable: no session ever existed.
      localFileError = true;
    } on InsecurePeerException {
      insecurePeer = true;
    } on PeerFingerprintMismatchException {
      keyChanged = true;
    } on Object {
      result = null;
    } finally {
      await sub.cancel();
      _sends.remove(key);
    }
    if (!ref.mounted) return;
    final current = find(key);
    if (current == null) return;
    // SessionFinished normally got here first; this is the backstop.
    _finish(
      key,
      success: result?.isSuccess ?? false,
      reason: result?.failureReason ?? FailureReason.protocolError,
      localFileError: localFileError,
      insecurePeer: insecurePeer,
      keyChanged: keyChanged,
      refusal: result?.refusal,
      pinRequired: result?.refusal == LsErrorCode.pinRequired,
    );
  }

  /// Cancel (either direction). Outgoing: tells the peer and stops uploading.
  Future<void> cancel(String key) async {
    final t = find(key);
    if (t == null || t.isFinished) return;
    final send = _sends[key];
    if (send != null) {
      unawaited(send.cancel());
      return;
    }
    final sid = t.sessionId;
    final engine = ref.read(engineOrNullProvider);
    if (sid != null && engine != null) {
      try {
        await engine.receiver.cancel(sid);
      } on Object {
        // already over
      }
    }
  }

  // ------------------------------------------------------------ incoming

  void _onEngineEvent(LsEvent e) {
    if (e is SessionCreated) {
      if (!e.outgoing) _onIncoming(e.sessionId);
      return;
    }
    if (e is SasReady) {
      final k =
          _sessionToKey[e.sessionId] ??
          _items.where((t) => t.sessionId == e.sessionId).firstOrNull?.key;
      if (k != null) _applyEvent(k, e);
      return;
    }
    if (e is PeerKeyChanged) {
      final target = _items.where((t) => !t.isFinished).firstOrNull;
      if (target != null) {
        _replace(target.key, (v) => v.copyWith(keyChanged: true));
      }
      return;
    }
    final sid = switch (e) {
      FileProgress(:final sessionId) => sessionId,
      FileSaved(:final sessionId) => sessionId,
      SessionFinished(:final sessionId) => sessionId,
      SessionCreated() => '',
      SasReady() ||
      PeerKeyChanged() ||
      PinBruteForceSuspected() ||
      ChannelStateChanged() => '',
      ContactChanged() || BlockSuggested() => '',
    };
    final key = _sessionToKey[sid];
    if (key != null) _applyEvent(key, e);
  }

  void _onIncoming(String sessionId) {
    final engine = ref.read(engineOrNullProvider);
    if (engine == null) return;
    final req = engine.receiver.requestFor(sessionId);
    if (req == null) return;
    final sender = req.sender;
    final heard = engine.currentDevices
        .where((d) => d.id == sender.deviceId)
        .firstOrNull;
    final now = _clock.now();
    final view = TransferView(
      key: sessionId,
      sessionId: sessionId,
      direction: TransferDirection.incoming,
      phase: TransferPhase.awaitingConsent,
      peerAlias: sender.alias,
      peerPlatform: sender.platform,
      peerAddress: heard?.address ?? sender.addrs.firstOrNull?.ip ?? '',
      files: [
        for (final f in req.files)
          TransferFile(id: f.fileId, name: f.fileName, size: f.size),
      ],
      createdAt: now,
      consentDeadline: now.add(engine.permissionTimeout),
    );
    _sessionToKey[sessionId] = sessionId;
    _set([view, ..._items]);
  }

  /// Consent granted for the incoming transfer [key].
  Future<void> acceptIncoming(String key) async {
    final t = find(key);
    final engine = ref.read(engineOrNullProvider);
    if (t == null ||
        engine == null ||
        t.phase != TransferPhase.awaitingConsent) {
      return;
    }
    try {
      await engine.receiver.accept(t.sessionId!);
      _replace(
        key,
        (v) => v.phase == TransferPhase.awaitingConsent
            ? v.copyWith(
                phase: TransferPhase.transferring,
                wasTransferring: true,
              )
            : v,
      );
    } on Object {
      // expired or cancelled meanwhile: SessionFinished tells the outcome
    }
  }

  /// Consent refused (or the countdown ran out).
  Future<void> rejectIncoming(String key) async {
    final t = find(key);
    final engine = ref.read(engineOrNullProvider);
    if (t == null ||
        engine == null ||
        t.phase != TransferPhase.awaitingConsent) {
      return;
    }
    try {
      await engine.receiver.reject(t.sessionId!);
    } on Object {
      // already decided
    }
  }

  // --------------------------------------------------------------- events

  void _applyEvent(String key, LsEvent e) {
    if (!ref.mounted) return;
    switch (e) {
      case SessionCreated(:final sessionId, :final outgoing):
        if (!outgoing) return;
        // Not entered in _sessionToKey: the engine's own event stream also
        // carries this send's events, and they are taken from the handle.
        _replace(
          key,
          (v) => v.phase == TransferPhase.preparing
              ? v.copyWith(sessionId: sessionId, phase: TransferPhase.waiting)
              : v.copyWith(sessionId: sessionId),
        );
      case FileProgress(:final fileId, :final bytesDone):
        _progress(key, fileId, bytesDone);
      case FileSaved(:final fileId, :final path):
        _replace(
          key,
          (v) => v.copyWith(
            files: [
              for (final f in v.files)
                f.id == fileId ? f.copyWith(savedPath: path) : f,
            ],
          ),
        );
      case SessionFinished(:final success, :final reason):
        _finish(key, success: success, reason: FailureReason.fromWire(reason));
      case SasReady(:final code):
        _replace(key, (v) => v.copyWith(sasCode: code));
      case PeerKeyChanged():
        _replace(key, (v) => v.copyWith(keyChanged: true));
      case PinBruteForceSuspected() ||
          ContactChanged() ||
          BlockSuggested() ||
          ChannelStateChanged():
        break;
    }
  }

  void _progress(String key, String fileId, int bytesDone) {
    final now = _clock.now();
    _replace(key, (v) {
      if (v.isFinished) return v;
      final files = [
        for (final f in v.files)
          f.id == fileId && bytesDone > f.done
              ? f.copyWith(done: bytesDone)
              : f,
      ];
      final next = v.copyWith(
        files: files,
        phase: v.phase == TransferPhase.awaitingConsent
            ? v.phase
            : TransferPhase.transferring,
        wasTransferring: v.phase == TransferPhase.awaitingConsent
            ? v.wasTransferring
            : true,
      );
      final speed = _sample(key, now, next.bytesDone);
      return next.copyWith(speed: speed);
    });
  }

  /// Rolling speed over [_speedWindow]; keeps the last value when samples are
  /// too close together to say anything.
  double _sample(String key, DateTime now, int bytes) {
    final list = _samples.putIfAbsent(key, () => []);
    list.add((now, bytes));
    while (list.length > 2 && now.difference(list.first.$1) > _speedWindow) {
      list.removeAt(0);
    }
    final first = list.first;
    final dt = now.difference(first.$1).inMicroseconds / 1e6;
    if (dt < 0.25) return find(key)?.speed ?? 0;
    return (bytes - first.$2) / dt;
  }

  void _finish(
    String key, {
    required bool success,
    FailureReason? reason,
    bool localFileError = false,
    bool insecurePeer = false,
    bool keyChanged = false,
    LsErrorCode? refusal,
    bool pinRequired = false,
  }) {
    _samples.remove(key);
    _replace(key, (v) {
      final effectivePinRequired =
          pinRequired || (refusal == LsErrorCode.pinRequired) || v.pinRequired;
      if (v.isFinished) {
        return v.copyWith(
          refusal: refusal ?? v.refusal,
          pinRequired: effectivePinRequired,
          insecurePeer: insecurePeer || v.insecurePeer,
          keyChanged: keyChanged || v.keyChanged,
        );
      }
      final phase = success
          ? TransferPhase.completed
          : switch (reason) {
              FailureReason.cancelled => TransferPhase.cancelled,
              FailureReason.rejected => TransferPhase.rejected,
              _ => TransferPhase.failed,
            };
      return v.copyWith(
        phase: phase,
        failure: success ? null : (reason ?? FailureReason.protocolError),
        localFileError: localFileError,
        insecurePeer: insecurePeer || v.insecurePeer,
        keyChanged: keyChanged || v.keyChanged,
        refusal: refusal ?? v.refusal,
        pinRequired: effectivePinRequired,
        finishedAt: _clock.now(),
        speed: 0,
        files: success
            ? [for (final f in v.files) f.copyWith(done: f.size)]
            : null,
      );
    });
  }

  /// Removes a finished transfer from the list.
  void dismiss(String key) {
    final t = find(key);
    if (t == null || !t.isFinished) return;
    _sessionToKey.removeWhere((_, k) => k == key);
    _retryInfo.remove(key);
    _set([
      for (final x in _items)
        if (x.key != key) x,
    ]);
  }
}

final transfersProvider =
    NotifierProvider<TransfersNotifier, List<TransferView>>(
      TransfersNotifier.new,
    );

/// One transfer by key (null if unknown or dismissed).
final transferProvider = Provider.family<TransferView?, String>(
  (ref, key) => ref.watch(
    transfersProvider.select((l) => l.where((t) => t.key == key).firstOrNull),
  ),
);

/// Incoming requests that wait for Accept / Reject.
final incomingRequestsProvider = Provider<List<TransferView>>(
  (ref) => [
    for (final t in ref.watch(transfersProvider))
      if (t.direction == TransferDirection.incoming &&
          t.phase == TransferPhase.awaitingConsent)
        t,
  ],
);
