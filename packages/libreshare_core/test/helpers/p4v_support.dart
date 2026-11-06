// Helpers of the P4 verifying review (test/security/p4_review_test.dart).
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';

import 'manual_clock.dart';
import 'p4_support.dart';

/// A trust store whose `setPairKey` fails like a full disk would (after `pin` succeeded).
class FailingSetPairKeyTrust extends InMemoryTrustStore {
  FailingSetPairKeyTrust({super.clock});

  @override
  Future<void> setPairKey(String deviceId, bool present) async {
    throw const FileSystemException('simulated write failure');
  }
}

/// A secure receiver wired like [P4Rig] but with a caller supplied event listener.
FileReceiver p4vReceiver({
  required Directory downloadDir,
  required InMemoryTrustStore trust,
  required ManualClock clock,
  required void Function(LsEvent) onEvent,
}) {
  final id = p4Identity(kRxId);
  return FileReceiver(
    self: DeviceInfo(
      deviceId: kRxId,
      alias: 'Receiver',
      platform: 'linux',
      fingerprint: id.identity.fingerprint,
      version: kProtocolVersionSecure,
    ),
    downloadDir: downloadDir,
    autoAccept: false,
    clock: clock,
    onEvent: onEvent,
    freeSpaceProbe: (_) async => null,
    security: SecurityConfig.tls(
      identity: id,
      trust: trust,
      pin: const PinPolicy.off(),
      consent: const ConsentPolicy(),
    ),
  );
}
