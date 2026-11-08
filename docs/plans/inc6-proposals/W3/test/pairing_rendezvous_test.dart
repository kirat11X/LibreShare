// Wave 3 unit tests: PairingService, SAS agreement, racing scanners, replay/expiry rules.
library;

import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../../helpers/manual_clock.dart';
import '../../helpers/p4_support.dart';

void main() {
  group('Wave 3: PairingService & SAS Agreement', () {
    late ManualClock clock;
    late InMemoryTrustStore trustA;
    late InMemoryTrustStore trustB;
    late InMemorySecretStore secretsA;
    late InMemorySecretStore secretsB;
    late KeyIdentity identityA;
    late KeyIdentity identityB;
    late PairingService serviceA;
    late PairingService serviceB;

    setUp(() async {
      clock = ManualClock();
      trustA = InMemoryTrustStore(clock: clock);
      trustB = InMemoryTrustStore(clock: clock);
      secretsA = InMemorySecretStore();
      secretsB = InMemorySecretStore();

      identityA = p4Identity('device-a-uuid');
      identityB = p4Identity('device-b-uuid');

      serviceA = PairingService(
        identity: identityA,
        trust: trustA,
        secrets: secretsA,
        clock: clock,
        self: () => DeviceInfo(
          deviceId: identityA.identity.deviceId,
          alias: 'Alice',
          platform: 'linux',
          fingerprint: identityA.identity.fingerprint,
          version: kProtocolVersionSecure,
        ),
      );

      serviceB = PairingService(
        identity: identityB,
        trust: trustB,
        secrets: secretsB,
        clock: clock,
        self: () => DeviceInfo(
          deviceId: identityB.identity.deviceId,
          alias: 'Bob',
          platform: 'linux',
          fingerprint: identityB.identity.fingerprint,
          version: kProtocolVersionSecure,
        ),
      );
    });

    test(
      'inviter and scanner complete handshake with identical SAS and K_pair',
      () async {
        // 1. Alice creates invite
        final invite = serviceA.createInvite();

        // 2. Bob scans invite
        final inviterCard = DeviceInfo(
          deviceId: identityA.identity.deviceId,
          alias: 'Alice',
          platform: 'linux',
          fingerprint: identityA.identity.fingerprint,
          version: kProtocolVersionSecure,
        );

        final scan = serviceB.startScan(
          inviteSecretB64: invite.secretB64,
          inviter: inviterCard,
        );

        // 3. Bob sends PairRequest to Alice
        final handleFuture = serviceA.handlePair(
          scan.request,
          peer: peerOf(identityB),
        );

        // Alice confirms prompt
        expect(serviceA.pendingPrompt, isNotNull);
        expect(
          serviceA.pendingPrompt!.fingerprint,
          equals(identityB.identity.fingerprint),
        );
        serviceA.decide(accept: true);

        final pairResponse = await handleFuture;
        expect(pairResponse.accepted, isTrue);

        // 4. Bob completes scan with Alice's response
        final completed = await scan.complete(pairResponse);
        expect(completed, isTrue);

        // Invariant: Both sides stored K_pair under kpair/<peerDeviceId>
        final kPairA = await secretsA.get(
          'kpair/${identityB.identity.deviceId}',
        );
        final kPairB = await secretsB.get(
          'kpair/${identityA.identity.deviceId}',
        );

        expect(kPairA, isNotNull);
        expect(kPairB, isNotNull);
        expect(kPairA, equals(kPairB));

        // Invariant: Both sides have peer in trust store as contact with hasPairKey = true
        final contactA = trustA.contacts.firstWhere(
          (c) => c.deviceId == identityB.identity.deviceId,
        );
        final contactB = trustB.contacts.firstWhere(
          (c) => c.deviceId == identityA.identity.deviceId,
        );
        expect(contactA.hasPairKey, isTrue);
        expect(contactB.hasPairKey, isTrue);
      },
    );

    test('reused invite secret S is rejected after being spent', () async {
      final invite = serviceA.createInvite();
      final inviterCard = DeviceInfo(
        deviceId: identityA.identity.deviceId,
        alias: 'Alice',
        platform: 'linux',
        fingerprint: identityA.identity.fingerprint,
        version: kProtocolVersionSecure,
      );

      final scan1 = serviceB.startScan(
        inviteSecretB64: invite.secretB64,
        inviter: inviterCard,
      );
      final handleFuture1 = serviceA.handlePair(
        scan1.request,
        peer: peerOf(identityB),
      );
      serviceA.decide(accept: true);
      final resp1 = await handleFuture1;
      expect(resp1.accepted, isTrue);
      await scan1.complete(resp1);

      // Second scanner attempts to use the same invite
      final identityC = p4Identity('device-c-uuid');
      final serviceC = PairingService(
        identity: identityC,
        trust: InMemoryTrustStore(clock: clock),
        secrets: InMemorySecretStore(),
        clock: clock,
        self: () => DeviceInfo(
          deviceId: identityC.identity.deviceId,
          alias: 'Carol',
          platform: 'linux',
          fingerprint: identityC.identity.fingerprint,
          version: kProtocolVersionSecure,
        ),
      );

      final scan2 = serviceC.startScan(
        inviteSecretB64: invite.secretB64,
        inviter: inviterCard,
      );

      // Inviter throws LsException(notFound) because invite is already spent
      expect(
        () => serviceA.handlePair(scan2.request, peer: peerOf(identityC)),
        throwsA(isA<LsException>()),
      );
    });

    test(
      'tampered request MAC is actively rejected without spending invite',
      () async {
        final invite = serviceA.createInvite();
        final inviterCard = DeviceInfo(
          deviceId: identityA.identity.deviceId,
          alias: 'Alice',
          platform: 'linux',
          fingerprint: identityA.identity.fingerprint,
          version: kProtocolVersionSecure,
        );

        final scan = serviceB.startScan(
          inviteSecretB64: invite.secretB64,
          inviter: inviterCard,
        );

        // Tamper MAC
        final originalMacBytes = b64urlDecode(scan.request.mac);
        final tamperedMacBytes = Uint8List.fromList(originalMacBytes);
        tamperedMacBytes[0] ^= 0xFF;

        final tamperedRequest = PairRequest(
          sender: scan.request.sender,
          nonce: scan.request.nonce,
          mac: b64urlEncode(tamperedMacBytes),
        );

        expect(
          () => serviceA.handlePair(tamperedRequest, peer: peerOf(identityB)),
          throwsA(isA<LsException>()),
        );

        // The invite was not consumed by the tampered request; valid request now succeeds
        final handleFuture = serviceA.handlePair(
          scan.request,
          peer: peerOf(identityB),
        );
        serviceA.decide(accept: true);
        final resp = await handleFuture;
        expect(resp.accepted, isTrue);
      },
    );

    test('expired invite is rejected', () {
      final invite = serviceA.createInvite();
      final inviterCard = DeviceInfo(
        deviceId: identityA.identity.deviceId,
        alias: 'Alice',
        platform: 'linux',
        fingerprint: identityA.identity.fingerprint,
        version: kProtocolVersionSecure,
      );

      // Advance clock past 10 min TTL
      clock.advance(const Duration(minutes: 11));

      final scan = serviceB.startScan(
        inviteSecretB64: invite.secretB64,
        inviter: inviterCard,
      );

      expect(
        () => serviceA.handlePair(scan.request, peer: peerOf(identityB)),
        throwsA(isA<LsException>()),
      );
    });

    test(
      'two scanners race: first accept wins, second scanner is rejected',
      () async {
        final invite = serviceA.createInvite();
        final inviterCard = DeviceInfo(
          deviceId: identityA.identity.deviceId,
          alias: 'Alice',
          platform: 'linux',
          fingerprint: identityA.identity.fingerprint,
          version: kProtocolVersionSecure,
        );

        final scanB = serviceB.startScan(
          inviteSecretB64: invite.secretB64,
          inviter: inviterCard,
        );

        final identityC = p4Identity('device-c-racing');
        final serviceC = PairingService(
          identity: identityC,
          trust: InMemoryTrustStore(clock: clock),
          secrets: InMemorySecretStore(),
          clock: clock,
          self: () => DeviceInfo(
            deviceId: identityC.identity.deviceId,
            alias: 'Carol',
            platform: 'linux',
            fingerprint: identityC.identity.fingerprint,
            version: kProtocolVersionSecure,
          ),
        );
        final scanC = serviceC.startScan(
          inviteSecretB64: invite.secretB64,
          inviter: inviterCard,
        );

        // Bob's request arrives and is held
        final handleB = serviceA.handlePair(
          scanB.request,
          peer: peerOf(identityB),
        );
        expect(serviceA.pendingPrompt, isNotNull);

        // Carol's request arrives while Bob is held -> throws 409 conflict
        expect(
          () => serviceA.handlePair(scanC.request, peer: peerOf(identityC)),
          throwsA(isA<LsException>()),
        );

        // Accept Bob
        serviceA.decide(accept: true);
        final respB = await handleB;
        expect(respB.accepted, isTrue);
        await scanB.complete(respB);
      },
    );
  });
}
