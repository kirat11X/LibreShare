/// Receive-mode vocabulary (design 01 section 1.1): what the user asked for
/// ([ReceiveMode], [ReceiveVisibility]), what is happening ([ReceiveState]),
/// what the environment says ([EnvEvent]) and what observers are told
/// ([ReceiveEvent]). Pure data; no I/O, no Flutter.
library;

/// What the user asked for (persisted).
sealed class ReceiveMode {
  const ReceiveMode();
}

/// Not receiving: listener closed, nothing announced as receivable.
final class ReceiveOff extends ReceiveMode {
  const ReceiveOff();

  @override
  bool operator ==(Object other) => other is ReceiveOff;

  @override
  int get hashCode => 0x0ff;

  @override
  String toString() => 'ReceiveOff';
}

/// Receive for a fixed window ("Everyone for 10 minutes"), then Off(expired).
final class ReceiveFor extends ReceiveMode {
  const ReceiveFor(this.duration);
  final Duration duration;

  @override
  bool operator ==(Object other) =>
      other is ReceiveFor && other.duration == duration;

  @override
  int get hashCode => Object.hash(0xf0, duration);

  @override
  String toString() => 'ReceiveFor(${duration.inSeconds}s)';
}

/// Receive until turned off (clamped by [ReceivePlatformCaps.maxContinuous]).
final class ReceiveAlways extends ReceiveMode {
  const ReceiveAlways();

  @override
  bool operator ==(Object other) => other is ReceiveAlways;

  @override
  int get hashCode => 0xa1;

  @override
  String toString() => 'ReceiveAlways';
}

/// Who may see this device while receiving.
enum ReceiveVisibility {
  /// Announced to everybody on the network (and replies to everybody).
  everyone,

  /// Only paired devices. Needs the trust store of Increment 3: until then
  /// [ReceiveController] refuses to switch to it and an engine treats a
  /// persisted value as "invisible" (fail closed).
  contacts,
}

/// What discovery does for the current state (design 01 section 1.4).
enum AnnouncePolicy {
  /// Nothing is announced as receivable (a send-only probe may still go out).
  none,

  /// Answer probes from trusted devices only (Contacts, Increment 3).
  replyToTrusted,

  /// Answer every probe, announce nothing by ourselves.
  replyToAll,

  /// Multicast announcements and the mDNS registration, plus replies.
  periodic,
}

enum OffReason {
  /// The user turned it off.
  user,

  /// A chosen window ended.
  expired,

  /// Receive mode was never enabled.
  neverEnabled,
}

enum PauseReason {
  /// The OS stopped the foreground service (Android `onTimeout`).
  platformTimeout,

  /// The process was killed by the system and restored later.
  osStopped,
  noNetwork,
  permissionMissing,
  batteryLow,
}

/// Runtime state (design 01 section 1.1).
sealed class ReceiveState {
  const ReceiveState();
}

/// Listener closed, nothing announced.
final class Off extends ReceiveState {
  const Off(this.reason);
  final OffReason reason;

  @override
  bool operator ==(Object other) => other is Off && other.reason == reason;

  @override
  int get hashCode => Object.hash('Off', reason);

  @override
  String toString() => 'Off($reason)';
}

/// The listener is being opened.
final class Starting extends ReceiveState {
  const Starting();

  @override
  bool operator ==(Object other) => other is Starting;

  @override
  int get hashCode => 0x57;

  @override
  String toString() => 'Starting';
}

/// Listener bound, announced according to [visibility].
final class On extends ReceiveState {
  const On(this.since, this.until, this.visibility);

  /// Wall-clock time the listener opened (display only).
  final DateTime since;

  /// Wall-clock end of the window (display only; expiry follows the monotonic
  /// scheduler); null means "until turned off".
  final DateTime? until;
  final ReceiveVisibility visibility;

  @override
  bool operator ==(Object other) =>
      other is On &&
      other.since == since &&
      other.until == until &&
      other.visibility == visibility;

  @override
  int get hashCode => Object.hash('On', since, until, visibility);

  @override
  String toString() => 'On(since: $since, until: $until, $visibility)';
}

/// The window ended while a transfer is active: new sessions get `409 BUSY`,
/// nothing is announced, the listener closes when the sessions are done or at
/// [deadline].
final class Draining extends ReceiveState {
  const Draining(this.deadline);
  final DateTime deadline;

  @override
  bool operator ==(Object other) =>
      other is Draining && other.deadline == deadline;

  @override
  int get hashCode => Object.hash('Draining', deadline);

  @override
  String toString() => 'Draining(deadline: $deadline)';
}

/// Involuntary stop; undo with one tap ([ReceiveController.resume]).
final class Paused extends ReceiveState {
  const Paused(this.reason);
  final PauseReason reason;

  @override
  bool operator ==(Object other) => other is Paused && other.reason == reason;

  @override
  int get hashCode => Object.hash('Paused', reason);

  @override
  String toString() => 'Paused($reason)';
}

/// The listener could not be opened.
final class Failed extends ReceiveState {
  const Failed(this.error);
  final Object error;

  @override
  bool operator ==(Object other) => other is Failed && other.error == error;

  @override
  int get hashCode => Object.hash('Failed', error);

  @override
  String toString() => 'Failed(${error.runtimeType})';
}

/// Why a state change happened.
enum ReceiveCause {
  turnOn,
  turnOff,
  resume,
  restore,
  expired,
  drained,
  drainTimeout,
  platformTimeout,
  network,
  battery,
  permission,
  visibility,
  bindFailed,
  shutdown,
}

/// Notifications that are not state changes (design 01 section 1.4). Kept apart
/// from `LsEvent` (sealed, orchestrator-owned) so the controller needs no
/// engine.
sealed class ReceiveEvent {
  const ReceiveEvent();
}

final class StateChanged extends ReceiveEvent {
  const StateChanged(this.previous, this.next, this.cause);
  final ReceiveState previous;
  final ReceiveState next;
  final ReceiveCause cause;

  @override
  String toString() => 'StateChanged($previous -> $next, $cause)';
}

/// Fired once, 15 minutes before a window ends (windows of 15 minutes or less
/// get none).
final class ExpiringSoon extends ReceiveEvent {
  const ExpiringSoon(this.remaining);
  final Duration remaining;

  @override
  String toString() => 'ExpiringSoon(${remaining.inMinutes} min)';
}

/// The window ended while sessions were active (the state is now [Draining]).
final class ExpiredWhileBusy extends ReceiveEvent {
  const ExpiredWhileBusy(this.activeSessions);
  final int activeSessions;

  @override
  String toString() => 'ExpiredWhileBusy($activeSessions)';
}

/// Hint the host passes to [ReceiveController.restore] about how the previous
/// process ended (Android reads `ApplicationExitInfo`).
enum ExitHint { unknown, userStopped }

/// Environment signals the host feeds into the controller.
sealed class EnvEvent {
  const EnvEvent();
}

final class NetworkUp extends EnvEvent {
  const NetworkUp();
}

final class NetworkDown extends EnvEvent {
  const NetworkDown();
}

/// Screen state is carried for completeness; the controller does not act on
/// it (the Android host releases its multicast lock itself).
final class ScreenOn extends EnvEvent {
  const ScreenOn();
}

final class ScreenOff extends EnvEvent {
  const ScreenOff();
}

final class BatteryLow extends EnvEvent {
  const BatteryLow();
}

final class BatteryOk extends EnvEvent {
  const BatteryOk();
}

final class PermissionLost extends EnvEvent {
  const PermissionLost();
}

final class PermissionGranted extends EnvEvent {
  const PermissionGranted();
}
