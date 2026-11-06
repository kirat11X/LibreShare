/// Notification service abstraction and models for LibreShare (Card F3 / U2).
///
/// Provides a platform-agnostic interface for posting incoming transfer
/// consent prompts, progress updates, completion alerts, and failure notices.
library;

import 'dart:async';

/// Notification action types triggered by user interaction (e.g. action buttons).
enum NotificationActionType { accept, reject }

/// An action triggered by the user from a system notification.
class NotificationAction {
  const NotificationAction({required this.sessionId, required this.type});

  const NotificationAction.accept(this.sessionId)
    : type = NotificationActionType.accept;

  const NotificationAction.reject(this.sessionId)
    : type = NotificationActionType.reject;

  final String sessionId;
  final NotificationActionType type;

  bool get isAccept => type == NotificationActionType.accept;
  bool get isReject => type == NotificationActionType.reject;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NotificationAction &&
          runtimeType == other.runtimeType &&
          sessionId == other.sessionId &&
          type == other.type;

  @override
  int get hashCode => Object.hash(sessionId, type);

  @override
  String toString() => 'NotificationAction($sessionId, $type)';
}

/// Abstract contract for platform-specific notification services.
abstract interface class NotificationService {
  /// Shows an incoming transfer consent notification with Accept and Reject actions.
  Future<void> showIncomingRequest({
    required String sessionId,
    required String peerName,
    required int fileCount,
    required int totalBytes,
  });

  /// Updates or shows an ongoing transfer progress notification.
  Future<void> showProgress({
    required String sessionId,
    required double progress,
    required String speed,
  });

  /// Shows a notification indicating that transfer of [fileCount] files completed.
  Future<void> showCompleted({
    required String sessionId,
    required int fileCount,
  });

  /// Shows a failure notification explaining [reason] (sanitized).
  Future<void> showFailed({required String sessionId, required String reason});

  /// Dismisses or cancels active notifications associated with [sessionId].
  Future<void> cancel(String sessionId);

  /// Stream of notification actions (Accept, Reject) triggered by the user.
  Stream<NotificationAction> get actions;

  /// Entry point invoked when a platform notification action is tapped.
  void onAction(NotificationAction action);
}

/// Safe no-op implementation of [NotificationService].
class NoOpNotificationService implements NotificationService {
  const NoOpNotificationService();

  @override
  Future<void> showIncomingRequest({
    required String sessionId,
    required String peerName,
    required int fileCount,
    required int totalBytes,
  }) async {}

  @override
  Future<void> showProgress({
    required String sessionId,
    required double progress,
    required String speed,
  }) async {}

  @override
  Future<void> showCompleted({
    required String sessionId,
    required int fileCount,
  }) async {}

  @override
  Future<void> showFailed({
    required String sessionId,
    required String reason,
  }) async {}

  @override
  Future<void> cancel(String sessionId) async {}

  @override
  Stream<NotificationAction> get actions => const Stream.empty();

  @override
  void onAction(NotificationAction action) {}
}

/// Record of an incoming request call for test verification.
class IncomingRequestCall {
  const IncomingRequestCall({
    required this.sessionId,
    required this.peerName,
    required this.fileCount,
    required this.totalBytes,
  });

  final String sessionId;
  final String peerName;
  final int fileCount;
  final int totalBytes;
}

/// Record of a progress call for test verification.
class ProgressCall {
  const ProgressCall({
    required this.sessionId,
    required this.progress,
    required this.speed,
  });

  final String sessionId;
  final double progress;
  final String speed;
}

/// Record of a completed call for test verification.
class CompletedCall {
  const CompletedCall({required this.sessionId, required this.fileCount});

  final String sessionId;
  final int fileCount;
}

/// Record of a failed call for test verification.
class FailedCall {
  const FailedCall({required this.sessionId, required this.reason});

  final String sessionId;
  final String reason;
}

/// Fake implementation of [NotificationService] for unit and widget testing.
class FakeNotificationService implements NotificationService {
  FakeNotificationService();

  final List<IncomingRequestCall> incomingRequests = [];
  final List<ProgressCall> progressUpdates = [];
  final List<CompletedCall> completedCalls = [];
  final List<FailedCall> failedCalls = [];
  final List<String> cancelledSessions = [];

  final StreamController<NotificationAction> _actionController =
      StreamController<NotificationAction>.broadcast();
  void Function(NotificationAction action)? actionCallback;

  @override
  Stream<NotificationAction> get actions => _actionController.stream;

  @override
  void onAction(NotificationAction action) {
    _actionController.add(action);
    actionCallback?.call(action);
  }

  /// Convenience helper to trigger an action in tests.
  void triggerAction(NotificationAction action) => onAction(action);

  @override
  Future<void> showIncomingRequest({
    required String sessionId,
    required String peerName,
    required int fileCount,
    required int totalBytes,
  }) async {
    incomingRequests.add(
      IncomingRequestCall(
        sessionId: sessionId,
        peerName: peerName,
        fileCount: fileCount,
        totalBytes: totalBytes,
      ),
    );
  }

  @override
  Future<void> showProgress({
    required String sessionId,
    required double progress,
    required String speed,
  }) async {
    progressUpdates.add(
      ProgressCall(sessionId: sessionId, progress: progress, speed: speed),
    );
  }

  @override
  Future<void> showCompleted({
    required String sessionId,
    required int fileCount,
  }) async {
    completedCalls.add(
      CompletedCall(sessionId: sessionId, fileCount: fileCount),
    );
  }

  @override
  Future<void> showFailed({
    required String sessionId,
    required String reason,
  }) async {
    failedCalls.add(FailedCall(sessionId: sessionId, reason: reason));
  }

  @override
  Future<void> cancel(String sessionId) async {
    cancelledSessions.add(sessionId);
  }

  void clear() {
    incomingRequests.clear();
    progressUpdates.clear();
    completedCalls.clear();
    failedCalls.clear();
    cancelledSessions.clear();
  }

  Future<void> dispose() async {
    await _actionController.close();
  }
}
