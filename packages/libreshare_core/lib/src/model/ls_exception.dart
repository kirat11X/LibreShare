/// Typed protocol errors (spec §4.3 error envelope). `code` == wire code.
library;

enum LsErrorCode {
  /// Identity proof missing, stale, replayed, forged or naming another server. [I3]
  authInvalid('AUTH_INVALID', 401, false),

  /// Known deviceId presented a different key than the pinned one. [I3]
  keyChanged('KEY_CHANGED', 403, false),
  pinRequired('PIN_REQUIRED', 401, false),
  pinInvalid('PIN_INVALID', 401, false),
  tokenInvalid('TOKEN_INVALID', 401, false),
  blocked('BLOCKED', 403, false),
  notFound('NOT_FOUND', 404, false),
  busy('BUSY', 409, true),
  wrongState('WRONG_STATE', 409, false),
  missingChunks('MISSING_CHUNKS', 409, true),
  cancelled('CANCELLED', 410, false),
  tooLarge('TOO_LARGE', 413, false),
  outOfRange('OUT_OF_RANGE', 416, false),
  chunkHashMismatch('CHUNK_HASH_MISMATCH', 422, true),
  verifyFailed('VERIFY_FAILED', 422, false),
  rateLimited('RATE_LIMITED', 429, true),
  badRequest('BAD_REQUEST', 400, false),
  insufficientStorage('INSUFFICIENT_STORAGE', 507, false),
  upgradeRequired('UPGRADE_REQUIRED', 426, false),
  internal('INTERNAL', 500, true);

  const LsErrorCode(this.wire, this.httpStatus, this.retryable);
  final String wire;
  final int httpStatus;
  final bool retryable;

  static LsErrorCode fromWire(String? w) => LsErrorCode.values.firstWhere(
    (c) => c.wire == w,
    orElse: () => LsErrorCode.internal,
  );
}

class LsException implements Exception {
  LsException(this.code, [this.message = '', this.retryAfter]);
  final LsErrorCode code;
  final String message;

  /// When set, the server answers with a `Retry-After` header of this many whole seconds
  /// (LSP-1 4.3.1: PIN-failure BLOCKED). Never part of the JSON envelope.
  final Duration? retryAfter;

  bool get retryable => code.retryable;
  int get httpStatus => code.httpStatus;

  Map<String, Object?> toEnvelope() => {
    'error': {'code': code.wire, 'message': message, 'retryable': retryable},
  };

  static LsException fromEnvelope(Map<String, Object?> json, {int? status}) {
    final e = (json['error'] as Map?)?.cast<String, Object?>() ?? const {};
    return LsException(
      LsErrorCode.fromWire(e['code'] as String?),
      (e['message'] as String?) ?? 'HTTP ${status ?? '?'}',
    );
  }

  @override
  String toString() => 'LsException(${code.wire}: $message)';
}
