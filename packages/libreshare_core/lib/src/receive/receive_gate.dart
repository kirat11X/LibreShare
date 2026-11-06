/// What [ReceiveController] drives (design 01 section 1.4). Implemented by
/// `LibreShareEngine`; tests use a recording fake.
library;

import 'receive_state.dart';

abstract interface class ReceiveGate {
  /// Binds the API listener (port fallback, FR-01) and returns the bound port.
  /// Idempotent while open. Throws if no port can be bound.
  Future<int> openListener();

  /// Closes the listener. [graceful] lets in-flight requests finish (bounded);
  /// otherwise connections are dropped at once.
  Future<void> closeListener({required bool graceful});

  /// Tells discovery what to announce (multicast + mDNS) and whom to answer.
  void setAnnounce(AnnouncePolicy policy);

  /// While false, `POST /sessions` answers `409 BUSY` (the Draining state).
  void setAcceptingSessions(bool accepting);

  /// Sessions that are pending or in progress.
  int get activeSessions;

  /// Emits [activeSessions] whenever it changes.
  Stream<int> get activeSessionCount;
}
