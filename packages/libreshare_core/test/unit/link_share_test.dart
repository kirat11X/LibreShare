import 'dart:typed_data';

import 'package:libreshare_core/src/model/share_models.dart';
import 'package:libreshare_core/src/share/link_share.dart';
import 'package:test/test.dart';

void main() {
  group('LinkShare State Machine & Lifecycle Tests', () {
    late Uint8List testRootKey;

    setUp(() {
      testRootKey = Uint8List.fromList(List.filled(32, 5));
    });

    test('Mode 1: first claimant binds, second claimant receives conflict', () {
      final share = LinkShare(
        shareId: 'share_123',
        token: 'token_abc',
        rootKey: testRootKey,
        mode: ShareMode.oneTime,
        maxReceivers: 1,
        totalBytes: 5000,
        createdAt: DateTime.now(),
        fileNames: ['file.txt'],
      );

      expect(share.state, equals(LinkShareState.ready));

      // First claimant binds
      expect(share.tryBindClaim('claim_AAA'), isTrue);
      expect(share.state, equals(LinkShareState.active));
      expect(share.boundClaims, contains('claim_AAA'));

      // Repeating same claimant is permitted
      expect(share.tryBindClaim('claim_AAA'), isTrue);

      // Second claimant is rejected in Mode 1
      expect(share.tryBindClaim('claim_BBB'), isFalse);
    });

    test('Mode N: allows up to N claimants, rejects N+1', () {
      final share = LinkShare(
        shareId: 'share_multi',
        token: 'token_multi',
        rootKey: testRootKey,
        mode: ShareMode.multiReceiver,
        maxReceivers: 2,
        totalBytes: 5000,
        createdAt: DateTime.now(),
        fileNames: ['file.txt'],
      );

      expect(share.tryBindClaim('claim_1'), isTrue);
      expect(share.tryBindClaim('claim_2'), isTrue);
      expect(share.tryBindClaim('claim_3'), isFalse);
      expect(share.boundClaims.length, equals(2));
    });

    test('Mode 0 (Anyone): permits unlimited claimants', () {
      final share = LinkShare(
        shareId: 'share_anyone',
        token: 'token_anyone',
        rootKey: testRootKey,
        mode: ShareMode.anyone,
        maxReceivers: 0,
        totalBytes: 5000,
        createdAt: DateTime.now(),
        fileNames: ['file.txt'],
      );

      for (var i = 1; i <= 10; i++) {
        expect(share.tryBindClaim('claim_$i'), isTrue);
      }
      expect(share.boundClaims.length, equals(10));
    });

    test(
      'one-time completion: verified final ack transitions state to completed',
      () {
        final share = LinkShare(
          shareId: 'share_complete',
          token: 'token_complete',
          rootKey: testRootKey,
          mode: ShareMode.oneTime,
          maxReceivers: 1,
          totalBytes: 5000,
          createdAt: DateTime.now(),
          fileNames: ['file.txt'],
        );

        share.tryBindClaim('claim_target');
        expect(share.state, equals(LinkShareState.active));

        share.recordFinalAck('claim_target');
        expect(share.state, equals(LinkShareState.completed));
        expect(share.isCompleted, isTrue);

        // Subsequent claim after completion is rejected
        expect(share.tryBindClaim('claim_new'), isFalse);
      },
    );

    test('byte budget enforcement revokes share when exceeded', () {
      final share = LinkShare(
        shareId: 'share_budget',
        token: 'token_budget',
        rootKey: testRootKey,
        mode: ShareMode.oneTime,
        maxReceivers: 1,
        totalBytes: 1000, // Budget is 2 * 1000 * 1 = 2000 bytes
        createdAt: DateTime.now(),
        fileNames: ['file.txt'],
      );

      share.tryBindClaim('claim_client');
      share.recordBytesServed('claim_client', 1500);
      expect(share.state, equals(LinkShareState.active));

      // Exceed remaining 500 bytes
      share.recordBytesServed('claim_client', 600);
      expect(share.state, equals(LinkShareState.revoked));
      expect(share.isRevoked, isTrue);
    });

    test('expiry check with injected timestamp', () {
      final now = DateTime.now();
      final share = LinkShare(
        shareId: 'share_exp',
        token: 'token_exp',
        rootKey: testRootKey,
        mode: ShareMode.oneTime,
        maxReceivers: 1,
        totalBytes: 1000,
        createdAt: now,
        expiresAt: now.add(const Duration(minutes: 15)),
        fileNames: ['file.txt'],
      );

      expect(share.isExpired(now.add(const Duration(minutes: 10))), isFalse);
      expect(share.isExpired(now.add(const Duration(minutes: 20))), isTrue);
    });

    test('explicit revocation marks share revoked', () {
      final share = LinkShare(
        shareId: 'share_rev',
        token: 'token_rev',
        rootKey: testRootKey,
        mode: ShareMode.oneTime,
        maxReceivers: 1,
        totalBytes: 1000,
        createdAt: DateTime.now(),
        fileNames: ['file.txt'],
      );

      expect(share.isRevoked, isFalse);
      share.revoke(reason: 'user requested stop');
      expect(share.state, equals(LinkShareState.revoked));
      expect(share.isRevoked, isTrue);
    });

    test('toString scrubs rootKey and tokens (secret hygiene)', () {
      final share = LinkShare(
        shareId: 'share_secret_check',
        token: 'secret_token_12345',
        rootKey: testRootKey,
        mode: ShareMode.oneTime,
        maxReceivers: 1,
        totalBytes: 1000,
        createdAt: DateTime.now(),
        fileNames: ['file.txt'],
      );

      final str = share.toString();
      expect(str, contains('[redacted]'));
      expect(str.contains('secret_token_12345'), isFalse);
      expect(str.contains(testRootKey.toString()), isFalse);
    });
  });
}
