// docs/plans/inc3.md section 4.1 row "security/mitm_test"
//
// In-process TLS-terminating proxy with its own certificate:
// - pinned_sender_refuses_proxy
// - first_contact_relay_fails_at_reveal
// - proxy_cannot_replay_captured_proof_to_real_receiver
// - proxy_with_own_identity_never_gets_files_without_user_accept
import 'dart:convert';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/p4_support.dart';
import '../helpers/p5_raw_peer.dart';
import '../helpers/p5_support.dart';

void main() {
  group('security/mitm_test (inc3.md section 4.1)', () {
    // -------------------------------------------------------------------------
    // 1. pinned_sender_refuses_proxy
    // -------------------------------------------------------------------------
    group('pinned_sender_refuses_proxy', () {
      late KeyIdentity clientIdentity;
      late KeyIdentity legitReceiver;
      late KeyIdentity proxyIdentity;
      final openPeers = <RawPeer>[];
      final openClients = <ApiClient>[];

      setUp(() {
        clientIdentity = newIdentity('mitm-client');
        legitReceiver = newIdentity('mitm-legit-rx');
        proxyIdentity = newIdentity('mitm-proxy');
      });

      tearDown(() async {
        for (final c in openClients) {
          c.close();
        }
        openClients.clear();
        for (final p in openPeers) {
          await p.close();
        }
        openPeers.clear();
      });

      test('pinned_sender_refuses_proxy: sender aborts handshake on proxy cert before any HTTP byte', () async {
        // In-process proxy TLS server with its own certificate (proxyIdentity)
        final proxyServer = await RawTlsPeer.start(proxyIdentity, port: 0);
        openPeers.add(proxyServer);

        // Sender is pinned to legitReceiver's certificate fingerprint
        final sec = secureConfig(clientIdentity);
        final client = secureClient(
          proxyServer.port,
          sec,
          pin: legitReceiver.identity.fingerprint,
        );
        openClients.add(client);

        Object? caught;
        try {
          await client.info();
        } on Object catch (e) {
          caught = e;
        }

        expect(caught, isA<PeerFingerprintMismatchException>());
        final mismatch = caught! as PeerFingerprintMismatchException;
        expect(
          mismatch.expectedShort,
          shortFp(legitReceiver.identity.fingerprint),
        );
        expect(
          mismatch.presentedShort,
          shortFp(proxyIdentity.identity.fingerprint),
        );

        await settle();
        expect(
          proxyServer.bytesReceived,
          0,
          reason: 'pinned client must not send any HTTP byte to proxy',
        );
        expect(proxyServer.requests, isEmpty);
      });
    });

    // -------------------------------------------------------------------------
    // 2. first_contact_relay_fails_at_reveal
    // -------------------------------------------------------------------------
    group('first_contact_relay_fails_at_reveal', () {
      test('first_contact_relay_fails_at_reveal: commitment bound to proxy fingerprint fails on real receiver', () async {
        final rig = P4Rig();
        final sender = p4Identity('mitm-fc-sender');
        final proxy = p4Identity('mitm-fc-proxy');

        // Honest sender talks to proxy; sender sees proxy's fingerprint in TLS handshake
        final sas = SasSender(sender, fpOf(proxy));

        // Proxy relays session request to real receiver
        final st = await rig.open(sender, commit: sas.commit);
        expect(st.status, TransferStatus.pending);
        expect(st.sas, isNotNull);

        // Sender sends SAS reveal with Ns. Real receiver validates commit against its OWN fingerprint.
        // Since commit was computed over proxy's fingerprint, it fails.
        try {
          await rig.receiver.revealSas(
            st.sessionId,
            nonce: sas.nonceB64,
            peer: peerOf(sender),
          );
          fail('expected LsException authInvalid on commit mismatch');
        } on LsException catch (e) {
          expect(e.code, LsErrorCode.authInvalid);
        }

        // Real receiver marks session failed with protocolError
        final polled = await rig.receiver.getSession(st.sessionId);
        expect(polled.status, TransferStatus.failed);
        expect(polled.failureReason, FailureReason.protocolError);
        expect(rig.trust.contacts, isEmpty);
        rig.dispose();
      });
    });

    // -------------------------------------------------------------------------
    // 3. proxy_cannot_replay_captured_proof_to_real_receiver
    // -------------------------------------------------------------------------
    group('proxy_cannot_replay_captured_proof_to_real_receiver', () {
      test('proxy_cannot_replay_captured_proof_to_real_receiver: channel-bound proof fails on other server', () async {
        final client = newIdentity('mitm-proof-client');
        final serverA = newIdentity('mitm-server-a');
        final serverB = newIdentity('mitm-server-b');

        // Client generates valid proof bound to serverA's fingerprint
        final method = 'POST';
        final path = '/api/v1/sessions';
        final body = utf8.encode('{"files":[]}');
        final now = DateTime.now();

        final capturedHeader = buildAuthHeader(
          identity: client,
          method: method,
          pathAndQuery: path,
          body: body,
          serverFingerprint: serverA.identity.fingerprint,
          now: now,
        );

        // Proxy attempts to replay this captured header to serverB
        final cacheB = NonceCache();
        final result = verifyAuthHeader(
          header: capturedHeader,
          method: method,
          pathAndQuery: path,
          body: body,
          ownFingerprint: serverB.identity.fingerprint,
          nonces: cacheB,
          now: now,
        );

        expect(result, isA<AuthFailed>());
        final failed = result as AuthFailed;
        expect(failed.reason, AuthFailure.badSignature);
      });
    });

    // -------------------------------------------------------------------------
    // 4. proxy_with_own_identity_never_gets_files_without_user_accept
    // -------------------------------------------------------------------------
    group('proxy_with_own_identity_never_gets_files_without_user_accept', () {
      test('proxy_with_own_identity_never_gets_files_without_user_accept: unaccepted session grants zero access', () async {
        final rig = P4Rig();
        final proxy = p4Identity('mitm-active-proxy');

        // Proxy connects with its own identity and commitment
        final sas = SasSender(proxy, rig.rxFp);
        final st = await rig.open(proxy, commit: sas.commit);

        // Session remains PENDING awaiting user Accept
        expect(st.status, TransferStatus.pending);

        // Attempting to query file state or write chunks without user accept fails
        try {
          await rig.receiver.fileState(
            st.sessionId,
            'f0',
            token: 'invalid-or-unauthorized',
          );
          fail('expected unauthorized before user accept');
        } on LsException catch (e) {
          expect(
            e.code,
            anyOf(
              LsErrorCode.tokenInvalid,
              LsErrorCode.authInvalid,
              LsErrorCode.notFound,
            ),
          );
        }

        // Proxy is not in trusted contacts
        expect(rig.trust.contacts, isEmpty);
        rig.dispose();
      });
    });
  });
}
