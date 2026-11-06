/// Events emitted by the engine (spec §3: core emits a `Stream` of LsEvent).
library;

import '../monitor/channel_event.dart';

sealed class LsEvent {
  const LsEvent();
}

class SessionCreated extends LsEvent {
  const SessionCreated(this.sessionId, {required this.outgoing});
  final String sessionId;
  final bool outgoing;
}

class FileProgress extends LsEvent {
  const FileProgress(
    this.sessionId,
    this.fileId,
    this.bytesDone,
    this.bytesTotal,
  );
  final String sessionId, fileId;
  final int bytesDone, bytesTotal;
}

class FileSaved extends LsEvent {
  const FileSaved(this.sessionId, this.fileId, this.path);
  final String sessionId, fileId, path;
}

class SessionFinished extends LsEvent {
  const SessionFinished(this.sessionId, {required this.success, this.reason});
  final String sessionId;
  final bool success;
  final String? reason;
}

/// Both nonces are known: show [code] (six digits, e.g. `482913`) on both devices and ask the
/// users to compare. Emitted on the sender and on the receiver. [I3]
class SasReady extends LsEvent {
  const SasReady(this.sessionId, this.code, {required this.outgoing});
  final String sessionId;
  final String code;
  final bool outgoing;
}

/// A known device presented a different key than the one we pinned. [I3]
class PeerKeyChanged extends LsEvent {
  const PeerKeyChanged({
    required this.deviceId,
    required this.pinnedFingerprint,
    required this.presentedFingerprint,
  });
  final String deviceId, pinnedFingerprint, presentedFingerprint;
}

/// Too many wrong PINs from many sources: PIN checks are locked and the PIN was rotated. [I3]
class PinBruteForceSuspected extends LsEvent {
  const PinBruteForceSuspected();
}

/// The contact list changed (pinned, replaced, blocked, removed). [I3]
class ContactChanged extends LsEvent {
  const ContactChanged(this.deviceId);
  final String deviceId;
}

/// The same device (by fingerprint) had [rejectCount] sessions rejected by the user within the
/// suggestion window: the UI may offer "Block this device". Never blocks by itself. [I3]
class BlockSuggested extends LsEvent {
  const BlockSuggested({
    required this.deviceId,
    required this.fingerprint,
    required this.alias,
    required this.rejectCount,
  });
  final String deviceId;

  /// Full fingerprint (UI/CLI may show 16 hex at most; never log it in full).
  final String fingerprint;
  final String alias;
  final int rejectCount;
}

/// Emitted when connection ladder candidates change state or switch tiers (Increment 4).
class ChannelStateChanged extends LsEvent {
  const ChannelStateChanged(this.event);
  final ChannelEvent event;
}
