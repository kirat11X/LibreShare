/// Helpers of the P3 verifying review (test/security/p3_review_*.dart).
library;

import 'dart:convert';

import 'package:libreshare_core/libreshare_core.dart';

import 'p3_secure_handler.dart';
import 'p3_secure_rig.dart';

/// A [P3SecureHandler] whose `createAuthenticatedSession` asks a real [PinGuard] about the PIN
/// carried in the request, exactly as the receiver does at step 10 of LSP-1 4.3.4. A wrong,
/// missing or blocked PIN is therefore answered by the HTTP layer from the `LsException` that the
/// guard throws.
class P3vPinHandler extends P3SecureHandler {
  P3vPinHandler(this.guard) {
    onCreateAuthenticated = (request, remoteAddress, peer) async {
      guard.check(
        remoteAddress: remoteAddress,
        pin: request.pin,
        exempt: false,
      );
      return const SessionStatus(
        sessionId: 'sess-pin',
        status: TransferStatus.pending,
      );
    };
  }

  final PinGuard guard;
}

/// A `POST /sessions` body of [who] that carries [pin].
List<int> p3vSessionBodyWithPin(P3Peer who, String? pin) => utf8.encode(
  jsonEncode(
    SessionRequest(
      sender: who.info(),
      files: const [
        FileItem(fileId: 'f0', fileName: 'a.bin', size: 1, chunkCount: 1),
      ],
      totalSize: 1,
      pin: pin,
    ).toJson(),
  ),
);

/// A PIN that is not [pin].
String p3vWrongPin(String pin) => pin == '000000' ? '111111' : '000000';

/// Parses a `Retry-After` header value that must be whole seconds; null when it is not.
int? p3vRetryAfterSeconds(P3Res r) {
  final raw = r.header('retry-after');
  if (raw == null || !RegExp(r'^[0-9]+$').hasMatch(raw.trim())) return null;
  return int.parse(raw.trim());
}
