# Card F3 Proposal Report: Notifications Logic & Seam

## 1. Summary of Work Delivered
Card F3 (U2) implements notification service abstraction, Riverpod event mapping, and fake test harness:
- `notification_service.dart`: Abstract interface `NotificationService`, model records, and default `NoOpNotificationService`.
- `notification_provider.dart`: Maps engine events (`ReceiveSessionPending`, `TransferProgress`, `TransferFinished`) to notification operations.
- `notifications_test.dart`: Comprehensive unit tests verifying single-notification invariants, action handling (Accept/Reject), progress throttling, and secret sanitization.
- `apply-notes.md`: Dependency request for `flutter_local_notifications` (BSD-3-Clause) and Android setup.
- `patch.diff`: Unified diff for easy application to `apps/libreshare_app/`.

## 2. Security Invariants
1. **Single Notification Source of Truth**: Exactly ONE notification is posted per incoming session.
2. **Session ID Consistency**: Action payloads use the identical `sessionId` as the in-app consent dialog. The in-app dialog remains the authoritative state source.
3. **Zero Secret Leakage**: Notification titles, bodies, and payloads never include PINs, secrets (`s=`), private keys, or raw authentication tokens.
4. **Clean File Truncation**: File lists and paths are defensively truncated to avoid notification buffer overflows.
