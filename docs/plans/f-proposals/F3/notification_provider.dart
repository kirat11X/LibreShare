/// Riverpod bridge connecting engine events to platform notification services (Card F3 / U2).
///
/// Security invariants:
/// 1. Exactly ONE notification posted per incoming session.
/// 2. Action uses the SAME session id as the in-app dialog (the dialog remains single source of truth).
/// 3. Never leak PIN, private keys, or full fingerprint into notification titles or bodies.
/// 4. Truncate long file names cleanly.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:libreshare_core/libreshare_core.dart';

import '../platform/notifications/notification_service.dart';
import '../services/format.dart';
import 'engine_provider.dart';
import 'platform_providers.dart';
import 'transfers_provider.dart';

/// Provider for the platform [NotificationService]. Defaults to [NoOpNotificationService].
final notificationServiceProvider = Provider<NotificationService>((ref) {
  return const NoOpNotificationService();
});

/// Configurable throttle interval for progress notifications (default: 500 ms).
final notificationThrottleDurationProvider = Provider<Duration>((ref) {
  return const Duration(milliseconds: 500);
});

/// Types of notifications tracked in state.
enum NotificationType { incoming, progress, completed, failed }

/// Metadata of an active or recent notification managed by [NotificationNotifier].
class ActiveNotification {
  const ActiveNotification({
    required this.sessionId,
    required this.type,
    this.peerName,
    this.fileCount,
    this.totalBytes,
    this.progress,
    this.speed,
    this.reason,
  });

  final String sessionId;
  final NotificationType type;
  final String? peerName;
  final int? fileCount;
  final int? totalBytes;
  final double? progress;
  final String? speed;
  final String? reason;
}

/// State maintained by [NotificationNotifier].
class NotificationState {
  const NotificationState({this.activeNotifications = const {}});

  final Map<String, ActiveNotification> activeNotifications;

  NotificationState copyWith({
    Map<String, ActiveNotification>? activeNotifications,
  }) => NotificationState(
    activeNotifications: activeNotifications ?? this.activeNotifications,
  );
}

/// Truncate long file names or titles cleanly, preserving the file extension when possible.
String truncateFileName(String name, {int maxLength = 32}) {
  if (name.length <= maxLength) return name;
  final dotIndex = name.lastIndexOf('.');
  if (dotIndex > 0 && dotIndex < name.length - 1) {
    final ext = name.substring(dotIndex);
    if (ext.length < maxLength ~/ 2) {
      final keepBase = maxLength - ext.length - 1; // 1 for '…'
      if (keepBase > 0) {
        return '${name.substring(0, keepBase)}…$ext';
      }
    }
  }
  return '${name.substring(0, maxLength - 1)}…';
}

/// Scrub text of sensitive patterns: full 64-character SHA-256 fingerprints,
/// private keys, pairing secrets, and PIN numbers.
String sanitizeNotificationText(String text) {
  var sanitized = text;
  // Never leak full 64-hex fingerprints
  sanitized = sanitized.replaceAll(
    RegExp(r'\b[0-9a-fA-F]{64}\b'),
    '[fingerprint]',
  );
  // Never leak PEM / private key blocks
  sanitized = sanitized.replaceAll(
    RegExp(r'-----BEGIN[ A-Z_-]+KEY-----[\s\S]*?-----END[ A-Z_-]+KEY-----'),
    '[redacted key]',
  );
  // Never leak pairing secrets (s=...)
  sanitized = sanitized.replaceAll(
    RegExp(r's=[a-zA-Z0-9_\-]+'),
    's=[redacted]',
  );
  // Never leak 6-digit PIN numbers
  sanitized = sanitized.replaceAll(
    RegExp(r'(?<=\bpin[:=\s]*)\b\d{6}\b', caseSensitive: false),
    '[pin]',
  );
  return sanitized;
}

/// Riverpod Notifier coordinating engine transfer events and notification dispatch.
class NotificationNotifier extends Notifier<NotificationState> {
  final Set<String> _notifiedIncomingSessions = <String>{};
  final Map<String, DateTime> _lastProgressTimestamp = <String, DateTime>{};
  final Map<String, int> _sessionFileCount = <String, int>{};
  final Map<String, int> _lastBytesDone = <String, int>{};

  NotificationService get _service => ref.read(notificationServiceProvider);
  Clock get _clock => ref.read(clockProvider);
  Duration get _throttleDuration =>
      ref.watch(notificationThrottleDurationProvider);

  @override
  NotificationState build() {
    final service = ref.watch(notificationServiceProvider);
    final engine = ref.watch(engineOrNullProvider);

    final actionSub = service.actions.listen(handleAction);
    ref.onDispose(() => unawaited(actionSub.cancel()));

    if (engine != null) {
      final engineSub = engine.events.listen(_onEngineEvent);
      ref.onDispose(() => unawaited(engineSub.cancel()));
    }

    return const NotificationState();
  }

  /// Dispatches an action (Accept or Reject) using the EXACT same session ID as the dialog.
  Future<void> handleAction(NotificationAction action) async {
    final transfers = ref.read(transfersProvider.notifier);
    switch (action.type) {
      case NotificationActionType.accept:
        await transfers.acceptIncoming(action.sessionId);
        await cancel(action.sessionId);
      case NotificationActionType.reject:
        await transfers.rejectIncoming(action.sessionId);
        await cancel(action.sessionId);
    }
  }

  /// Cancels notifications associated with [sessionId].
  Future<void> cancel(String sessionId) async {
    await _service.cancel(sessionId);
    if (!ref.mounted) return;
    final next = Map<String, ActiveNotification>.from(
      state.activeNotifications,
    );
    next.remove(sessionId);
    state = state.copyWith(activeNotifications: next);
  }

  void _onEngineEvent(LsEvent e) {
    switch (e) {
      case SessionCreated(:final sessionId, :final outgoing):
        if (!outgoing) {
          unawaited(_onIncomingSession(sessionId));
        }
      case FileProgress(:final sessionId, :final bytesDone, :final bytesTotal):
        unawaited(_onFileProgress(sessionId, bytesDone, bytesTotal));
      case FileSaved():
        break;
      case SessionFinished(:final sessionId, :final success, :final reason):
        unawaited(_onSessionFinished(sessionId, success, reason));
      case SasReady() ||
          PeerKeyChanged() ||
          PinBruteForceSuspected() ||
          ContactChanged() ||
          BlockSuggested():
        break;
    }
  }

  Future<void> _onIncomingSession(String sessionId) async {
    // Security invariant: Exactly ONE notification posted per incoming session.
    if (_notifiedIncomingSessions.contains(sessionId)) return;
    _notifiedIncomingSessions.add(sessionId);

    final engine = ref.read(engineOrNullProvider);
    String peerName = 'Unknown device';
    int fileCount = 1;
    int totalBytes = 0;

    if (engine != null) {
      final req = engine.receiver.requestFor(sessionId);
      if (req != null) {
        final alias = req.sender.alias.trim();
        if (alias.isNotEmpty) {
          peerName = sanitizeNotificationText(
            truncateFileName(alias, maxLength: 40),
          );
        }
        fileCount = req.files.length;
        totalBytes = req.totalSize;
        _sessionFileCount[sessionId] = fileCount;
      }
    }

    await _service.showIncomingRequest(
      sessionId: sessionId,
      peerName: peerName,
      fileCount: fileCount,
      totalBytes: totalBytes,
    );

    if (!ref.mounted) return;
    final next = Map<String, ActiveNotification>.from(
      state.activeNotifications,
    );
    next[sessionId] = ActiveNotification(
      sessionId: sessionId,
      type: NotificationType.incoming,
      peerName: peerName,
      fileCount: fileCount,
      totalBytes: totalBytes,
    );
    state = state.copyWith(activeNotifications: next);
  }

  Future<void> _onFileProgress(
    String sessionId,
    int bytesDone,
    int bytesTotal,
  ) async {
    final now = _clock.now();
    final lastTime = _lastProgressTimestamp[sessionId];
    final isFirst = lastTime == null;
    final isComplete = bytesTotal > 0 && bytesDone >= bytesTotal;
    final elapsed = isFirst ? Duration.zero : now.difference(lastTime);

    // Throttle progress notifications
    if (!isFirst && !isComplete && elapsed < _throttleDuration) {
      return;
    }
    _lastProgressTimestamp[sessionId] = now;

    final fraction = bytesTotal <= 0
        ? 0.0
        : (bytesDone / bytesTotal).clamp(0.0, 1.0);

    // Speed calculation
    double speedBytesPerSec = 0.0;
    final lastBytes = _lastBytesDone[sessionId] ?? 0;
    if (!isFirst && elapsed.inMilliseconds > 0) {
      final deltaBytes = bytesDone - lastBytes;
      if (deltaBytes > 0) {
        speedBytesPerSec = (deltaBytes / elapsed.inMilliseconds) * 1000.0;
      }
    }
    _lastBytesDone[sessionId] = bytesDone;

    final speedText = formatSpeed(speedBytesPerSec);

    await _service.showProgress(
      sessionId: sessionId,
      progress: fraction,
      speed: speedText,
    );

    if (!ref.mounted) return;
    final next = Map<String, ActiveNotification>.from(
      state.activeNotifications,
    );
    next[sessionId] = ActiveNotification(
      sessionId: sessionId,
      type: NotificationType.progress,
      progress: fraction,
      speed: speedText,
    );
    state = state.copyWith(activeNotifications: next);
  }

  Future<void> _onSessionFinished(
    String sessionId,
    bool success,
    String? reason,
  ) async {
    _lastProgressTimestamp.remove(sessionId);
    _lastBytesDone.remove(sessionId);

    if (success) {
      final fileCount = _sessionFileCount.remove(sessionId) ?? 1;
      await _service.showCompleted(sessionId: sessionId, fileCount: fileCount);
      if (!ref.mounted) return;
      final next = Map<String, ActiveNotification>.from(
        state.activeNotifications,
      );
      next[sessionId] = ActiveNotification(
        sessionId: sessionId,
        type: NotificationType.completed,
        fileCount: fileCount,
      );
      state = state.copyWith(activeNotifications: next);
    } else {
      _sessionFileCount.remove(sessionId);
      if (reason == 'rejected' || reason == 'cancelled') {
        await cancel(sessionId);
      } else {
        final safeReason = sanitizeNotificationText(
          reason ?? 'Transfer failed',
        );
        await _service.showFailed(sessionId: sessionId, reason: safeReason);
        if (!ref.mounted) return;
        final next = Map<String, ActiveNotification>.from(
          state.activeNotifications,
        );
        next[sessionId] = ActiveNotification(
          sessionId: sessionId,
          type: NotificationType.failed,
          reason: safeReason,
        );
        state = state.copyWith(activeNotifications: next);
      }
    }
  }
}

final notificationProvider =
    NotifierProvider<NotificationNotifier, NotificationState>(
      NotificationNotifier.new,
    );
