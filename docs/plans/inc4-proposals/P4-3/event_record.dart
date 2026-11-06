// ignore_for_file: depend_on_referenced_packages
/// Structured persistent event record models for LibreShare (Increment 4, Task P4-3).
///
/// Encapsulates persistent events for connection ladder transitions, channel state,
/// transfer session lifecycle, and diagnostic errors.
///
/// Security Invariants:
/// 1. ZERO SECRET LEAKS: Records MUST NEVER contain PINs, bearer tokens, private keys,
///    passwords, SAS nonces, or long secret payloads.
/// 2. FINGERPRINT TRUNCATION: Fingerprints stored in events or messages must be truncated
///    to <= 16 hex characters (`shortFp`) to prevent fingerprint harvesting.
/// 3. IMMUTABILITY & SERDE: Clean JSON round-tripping for JSONL append storage.
library;

import 'dart:convert';
import 'dart:math';

import 'package:libreshare_core/libreshare_core.dart';

import '../wave0/channel_event.dart';
import '../wave0/session_record.dart';

/// Severity level of an event record.
enum EventLevel {
  debug('debug'),
  info('info'),
  warning('warning'),
  error('error'),
  securityAlert('security_alert');

  const EventLevel(this.wire);
  final String wire;

  static EventLevel fromWire(String wire) {
    for (final level in EventLevel.values) {
      if (level.wire == wire) return level;
    }
    throw ArgumentError.value(wire, 'wire', 'Unknown event level');
  }
}

/// Set of forbidden keys that must never appear in an EventRecord.
const Set<String> kForbiddenSecretKeys = {
  'pin',
  'token',
  'secret',
  'privatekey',
  'private_key',
  'nonce',
  'sascommit',
  'sas_commit',
  'keyb64',
  'password',
  'authheader',
  'x-ls-auth',
  'bearer',
  'authorization',
  'shared_secret',
  'private',
  'master_key',
  'credential',
};

/// Regex patterns that identify secret values in messages or payload attributes.
final List<RegExp> _kSecretValuePatterns = [
  // PEM private keys
  RegExp(r'-----BEGIN[ A-Z0-9_-]*PRIVATE KEY-----', caseSensitive: false),
  // Explicit PIN or SAS numeric codes (e.g. pin=123456 or pin: 123456)
  RegExp(r'\b(?:pin|code)\s*[:=]\s*\d{4,8}\b', caseSensitive: false),
  // Explicit token / secret / password assignment
  RegExp(
    r'\b(?:token|secret|password)\s*[:=]\s*[^\s,;]{6,}\b',
    caseSensitive: false,
  ),
  // Bearer tokens
  RegExp(r'Bearer\s+[A-Za-z0-9._~+/-]{16,}', caseSensitive: false),
];

/// Validates that [map] contains no forbidden secret keys and no secret values.
void assertNoSecretKeys(Map<String, Object?> map) {
  for (final entry in map.entries) {
    final keyLower = entry.key.toLowerCase();
    if (kForbiddenSecretKeys.contains(keyLower)) {
      throw ArgumentError(
        'Security violation: EventRecord must never contain secret key: "${entry.key}"',
      );
    }
    for (final forbidden in kForbiddenSecretKeys) {
      if (keyLower.contains(forbidden)) {
        throw ArgumentError(
          'Security violation: EventRecord key "${entry.key}" contains forbidden term: "$forbidden"',
        );
      }
    }
    _assertNoSecretValue(entry.value, keyContext: entry.key);
  }
}

/// Validates that [value] does not contain secret patterns.
void _assertNoSecretValue(Object? value, {String? keyContext}) {
  if (value == null) return;
  if (value is String) {
    for (final pattern in _kSecretValuePatterns) {
      if (pattern.hasMatch(value)) {
        throw ArgumentError(
          'Security violation: EventRecord field ${keyContext != null ? "($keyContext) " : ""}contains secret pattern: $pattern',
        );
      }
    }
    // High-entropy or long secret check: if a string without whitespace is > 96 chars,
    // ensure it is not an unauthorized raw key/secret payload.
    // (A 64-char hex string is allowed for sha256 digests).
    if (value.length > 96 &&
        !value.contains(' ') &&
        !value.contains('/') &&
        !value.contains(':')) {
      throw ArgumentError(
        'Security violation: EventRecord field ${keyContext != null ? "($keyContext) " : ""}contains long opaque secret candidate (${value.length} chars)',
      );
    }
  } else if (value is Map) {
    assertNoSecretKeys(value.cast<String, Object?>());
  } else if (value is List) {
    for (final item in value) {
      _assertNoSecretValue(item, keyContext: keyContext);
    }
  }
}

/// Validates an entire event's text and structure for secret leaks.
void assertNoSecretsInEvent({
  required String type,
  required String message,
  String? sessionId,
  required Map<String, Object?> data,
}) {
  _assertNoSecretValue(type, keyContext: 'type');
  _assertNoSecretValue(message, keyContext: 'message');
  if (sessionId != null) {
    _assertNoSecretValue(sessionId, keyContext: 'sessionId');
  }
  assertNoSecretKeys(data);
}

/// Helper to truncate fingerprints to at most 16 hex characters per Decision D6 / Rule 3.
String shortFingerprint(String fingerprint) {
  final clean = fingerprint.replaceAll(':', '').toLowerCase();
  return clean.length > 16 ? clean.substring(0, 16) : clean;
}

/// Persistent record of a single event in the LibreShare monitor and diagnostics log.
class EventRecord {
  const EventRecord({
    required this.id,
    required this.timestamp,
    required this.type,
    this.level = EventLevel.info,
    this.sessionId,
    required this.message,
    this.data = const {},
  }) : assert(id.length > 0, 'id must not be empty'),
       assert(type.length > 0, 'type must not be empty'),
       assert(message.length > 0, 'message must not be empty');

  /// Unique event identifier.
  final String id;

  /// UTC timestamp when the event occurred.
  final DateTime timestamp;

  /// Categorical event type (e.g. 'channel_active', 'session_finished', 'error').
  final String type;

  /// Severity level of the event.
  final EventLevel level;

  /// Optional transfer session ID bound to this event.
  final String? sessionId;

  /// Human-readable event description.
  final String message;

  /// Non-secret structured properties associated with this event.
  final Map<String, Object?> data;

  /// Factory to construct a new event with an auto-generated ID and timestamp.
  factory EventRecord.create({
    required String type,
    EventLevel level = EventLevel.info,
    String? sessionId,
    required String message,
    Map<String, Object?> data = const {},
    DateTime? timestamp,
    String? id,
  }) {
    final now = (timestamp ?? DateTime.now()).toUtc();
    final eventId =
        id ??
        'evt_${now.microsecondsSinceEpoch}_${Random().nextInt(0xFFFFFF).toRadixString(16).padLeft(6, "0")}';
    assertNoSecretsInEvent(
      type: type,
      message: message,
      sessionId: sessionId,
      data: data,
    );
    return EventRecord(
      id: eventId,
      timestamp: now,
      type: type,
      level: level,
      sessionId: sessionId,
      message: message,
      data: data,
    );
  }

  /// Constructs an [EventRecord] from a connection ladder [ChannelEvent].
  factory EventRecord.fromChannelEvent(
    ChannelEvent event, {
    String? sessionId,
  }) {
    final sid = event is ChannelActive
        ? (event.sessionId ?? sessionId)
        : event is ChannelFailed
        ? (event.sessionId ?? sessionId)
        : event is ChannelTierSwitched
        ? (event.sessionId ?? sessionId)
        : sessionId;

    if (event is ChannelActive) {
      final shortFp = shortFingerprint(event.candidate.peerFingerprint);
      return EventRecord.create(
        type: 'channel_active',
        level: EventLevel.info,
        sessionId: sid,
        timestamp: event.timestamp,
        message:
            'Channel active: ${event.candidate.kind.wire} (${event.candidate.host}:${event.candidate.port}, RTT: ${event.rtt.inMilliseconds}ms)',
        data: {
          'candidateId': event.candidate.id,
          'kind': event.candidate.kind.wire,
          'host': event.candidate.host,
          'port': event.candidate.port,
          'rttMs': event.rtt.inMilliseconds,
          'costHint': event.candidate.costHint,
          'peerFingerprint': shortFp,
        },
      );
    } else if (event is ChannelFailed) {
      return EventRecord.create(
        type: 'channel_failed',
        level: EventLevel.warning,
        sessionId: sid,
        timestamp: event.timestamp,
        message:
            'Channel failed on ${event.candidate.kind.wire}: ${event.reason}',
        data: {
          'candidateId': event.candidate.id,
          'kind': event.candidate.kind.wire,
          'reason': event.reason,
          'consecutiveFailures': event.consecutiveFailures,
          if (event.error != null) 'error': event.error.toString(),
        },
      );
    } else if (event is ChannelTierSwitched) {
      return EventRecord.create(
        type: 'channel_tier_switched',
        level: EventLevel.info,
        sessionId: sid,
        timestamp: event.timestamp,
        message:
            'Switched channel tier from ${event.fromCandidate?.kind.wire ?? "none"} to ${event.toCandidate.kind.wire} (reason: ${event.reason})',
        data: {
          if (event.fromCandidate != null)
            'fromCandidateId': event.fromCandidate!.id,
          if (event.fromCandidate != null)
            'fromKind': event.fromCandidate!.kind.wire,
          'toCandidateId': event.toCandidate.id,
          'toKind': event.toCandidate.kind.wire,
          'reason': event.reason,
        },
      );
    } else if (event is ChannelCandidateTested) {
      return EventRecord.create(
        type: 'channel_candidate_tested',
        level: event.success ? EventLevel.debug : EventLevel.warning,
        sessionId: sid,
        timestamp: event.timestamp,
        message:
            'Tested candidate ${event.candidate.id} [${event.candidate.kind.wire}]: ${event.success ? "success" : "failed"}',
        data: {
          'candidateId': event.candidate.id,
          'kind': event.candidate.kind.wire,
          'success': event.success,
          if (event.rtt != null) 'rttMs': event.rtt!.inMilliseconds,
          if (event.error != null) 'error': event.error,
        },
      );
    }
    throw UnsupportedError('Unsupported ChannelEvent: ${event.runtimeType}');
  }

  /// Constructs an [EventRecord] from a transfer [SessionRecord].
  factory EventRecord.fromSession(
    SessionRecord session, {
    required String message,
    String? type,
    EventLevel? level,
    Map<String, Object?> data = const {},
  }) {
    final shortFp = shortFingerprint(session.peerFingerprint);
    final eventLevel =
        level ??
        (session.status == TransferStatus.failed
            ? EventLevel.error
            : EventLevel.info);

    final eventData = <String, Object?>{
      'role': session.role.wire,
      'peerDeviceId': session.peerDeviceId,
      'peerFingerprint': shortFp,
      'status': session.status.wire,
      if (session.failureReason != null)
        'failureReason': session.failureReason!.wire,
      'filesCount': session.files.length,
      'totalSize': session.totalSize,
      if (session.chosenCandidateId != null)
        'chosenCandidateId': session.chosenCandidateId,
      ...data,
    };

    return EventRecord.create(
      type: type ?? 'session_${session.status.wire.toLowerCase()}',
      level: eventLevel,
      sessionId: session.sessionId,
      timestamp: session.updatedAt,
      message: message,
      data: eventData,
    );
  }

  /// Constructs an error [EventRecord].
  factory EventRecord.error(
    String message, {
    String? type,
    String? sessionId,
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> data = const {},
  }) {
    final eventData = <String, Object?>{
      if (error != null) 'error': error.toString(),
      if (stackTrace != null)
        'stackTrace': stackTrace.toString().split('\n').take(8).join('\n'),
      ...data,
    };
    return EventRecord.create(
      type: type ?? 'error',
      level: EventLevel.error,
      sessionId: sessionId,
      message: message,
      data: eventData,
    );
  }

  /// Creates a copy of this event record with modified properties.
  EventRecord copyWith({
    String? id,
    DateTime? timestamp,
    String? type,
    EventLevel? level,
    String? sessionId,
    String? message,
    Map<String, Object?>? data,
  }) {
    return EventRecord(
      id: id ?? this.id,
      timestamp: timestamp ?? this.timestamp,
      type: type ?? this.type,
      level: level ?? this.level,
      sessionId: sessionId ?? this.sessionId,
      message: message ?? this.message,
      data: data ?? this.data,
    );
  }

  Map<String, Object?> toJson() {
    final json = <String, Object?>{
      'id': id,
      'timestamp': timestamp.toUtc().toIso8601String(),
      'type': type,
      'level': level.wire,
      if (sessionId != null) 'sessionId': sessionId,
      'message': message,
      if (data.isNotEmpty) 'data': data,
    };
    assertNoSecretsInEvent(
      type: type,
      message: message,
      sessionId: sessionId,
      data: data,
    );
    return json;
  }

  factory EventRecord.fromJson(Map<String, Object?> json) {
    final type = json['type']! as String;
    final message = json['message']! as String;
    final sessionId = json['sessionId'] as String?;
    final data = ((json['data'] as Map?) ?? const {}).cast<String, Object?>();

    assertNoSecretsInEvent(
      type: type,
      message: message,
      sessionId: sessionId,
      data: data,
    );

    return EventRecord(
      id: json['id']! as String,
      timestamp: DateTime.parse(json['timestamp']! as String).toUtc(),
      type: type,
      level: EventLevel.fromWire((json['level'] as String?) ?? 'info'),
      sessionId: sessionId,
      message: message,
      data: data,
    );
  }

  /// Serializes this event to a single compact JSON line.
  String toJsonLine() => jsonEncode(toJson());

  /// Deserializes an event from a single JSON line.
  factory EventRecord.fromJsonLine(String line) {
    final json = jsonDecode(line.trim()) as Map<String, Object?>;
    return EventRecord.fromJson(json);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EventRecord &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          timestamp == other.timestamp &&
          type == other.type &&
          level == other.level &&
          sessionId == other.sessionId &&
          message == other.message;

  @override
  int get hashCode => Object.hash(id, timestamp, type, level, sessionId);

  @override
  String toString() =>
      'EventRecord($id, [${level.wire}] $type, ${timestamp.toIso8601String()}'
      '${sessionId != null ? ", sid=$sessionId" : ""}: $message)';
}
