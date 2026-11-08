// RendezvousServiceImpl: coordinates presence announcements, cache, offers, and receive gate hook.
library;

import 'dart:async';
import 'dart:convert' show ascii;

import '../clock.dart';
import '../model/ls_exception.dart';
import '../receive/receive_state.dart';
import '../security/contracts.dart';
import '../security/crypto_primitives.dart' show hexOf, hmacSha256, sha256Bytes;
import 'channel_deriver.dart';
import 'envelope_codec.dart';
import 'presence_cache.dart';
import 'records.dart';
import 'rendezvous_backend.dart';
import 'rendezvous_service.dart';
import 'replay_guard.dart';

/// Implementation of [RendezvousService] using encrypted rendezvous channels.
class RendezvousServiceImpl implements RendezvousService {
  RendezvousServiceImpl({
    required this.identity,
    required this.trust,
    required this.secrets,
    required this.backend,
    this.channelDeriver = const ChannelDeriverImpl(),
    this.envelopeCodec = const EnvelopeCodecImpl(),
    ReplayGuard? replayGuard,
    PresenceCache? presenceCache,
    this.clock = const SystemClock(),
    this.announcePolicy = AnnouncePolicy.none,
    List<Map<String, dynamic>>? localCandidates,
    this.relayUrls,
  }) : replayGuard = replayGuard ?? ReplayGuard(),
       presenceCache = presenceCache ?? PresenceCache(clock: clock),
       localCandidates = localCandidates ?? [];

  final IdentityProvider identity;
  final TrustStore trust;
  final SecretStore secrets;
  final RendezvousBackend backend;
  final ChannelDeriver channelDeriver;
  final EnvelopeCodec envelopeCodec;
  final ReplayGuard replayGuard;
  final PresenceCache presenceCache;
  final Clock clock;
  final List<Uri>? relayUrls;

  AnnouncePolicy announcePolicy;
  List<Map<String, dynamic>> localCandidates;

  int _seq = 0;
  StreamSubscription<RelayEvent>? _backendSub;
  Timer? _periodicTimer;
  OfferCallback? _onOffer;

  final StreamController<MapEntry<String, PresenceRecord>> _presenceCtrl =
      StreamController<MapEntry<String, PresenceRecord>>.broadcast();

  final Map<String, Completer<ReplyRecord>> _pendingOffers = {};

  @override
  Stream<MapEntry<String, PresenceRecord>> get presenceEvents =>
      _presenceCtrl.stream;

  /// Hook for ReceiveGate: updates announce policy and broadcasts presence if enabled.
  void setAnnounce(AnnouncePolicy policy) {
    announcePolicy = policy;
    if (announcePolicy != AnnouncePolicy.none) {
      unawaited(broadcastPresence());
    }
  }

  @override
  Future<void> start({OfferCallback? onOffer}) async {
    _onOffer = onOffer;
    if (relayUrls != null && relayUrls!.isNotEmpty) {
      await backend.connect(relayUrls!);
    }

    final epoch = channelDeriver.currentEpoch(now: clock.now());

    // Subscribe to inbound channels for all paired contacts (where this device is target)
    for (final contact in trust.contacts) {
      if (!contact.hasPairKey) continue;
      final kPair = await secrets.get('kpair/${contact.deviceId}');
      if (kPair == null) continue;

      final inboundChannel = channelDeriver.deriveChannelId(
        pairKey: kPair,
        peerDeviceId: identity.identity.deviceId,
        epoch: epoch,
      );
      await backend.subscribe(inboundChannel);
    }

    _backendSub = backend.events.listen(_handleEvent);

    if (announcePolicy != AnnouncePolicy.none) {
      await broadcastPresence();
    }
  }

  void _handleEvent(RelayEvent event) {
    unawaited(_processIncoming(event));
  }

  Future<void> _processIncoming(RelayEvent event) async {
    final epoch = channelDeriver.currentEpoch(now: clock.now());

    for (final contact in trust.contacts) {
      if (!contact.hasPairKey) continue;
      final kPair = await secrets.get('kpair/${contact.deviceId}');
      if (kPair == null) continue;

      final inboundChannel = channelDeriver.deriveChannelId(
        pairKey: kPair,
        peerDeviceId: identity.identity.deviceId,
        epoch: epoch,
      );
      if (inboundChannel != event.channelIdHex) continue;

      final envelopeKey = channelDeriver.deriveEnvelopeKey(
        pairKey: kPair,
        epoch: epoch,
      );

      final RendezvousRecord record;
      try {
        record = envelopeCodec.unseal(
          payload: event.payload,
          envelopeKey: envelopeKey,
          channelIdHex: event.channelIdHex,
        );
      } catch (_) {
        // Not decryptable with this key or authentication failed
        continue;
      }

      try {
        replayGuard.validate(
          record,
          channelIdHex: event.channelIdHex,
          now: clock.now(),
        );
      } catch (_) {
        // Replay or clock skew violation
        continue;
      }

      if (record is PresenceRecord) {
        presenceCache.recordPresence(
          contact.deviceId,
          record,
          peerFingerprint: contact.fingerprint,
        );
        _presenceCtrl.add(MapEntry(contact.deviceId, record));
      } else if (record is OfferRecord) {
        final handler = _onOffer;
        if (handler != null) {
          final accepted = await handler(contact.deviceId, record);
          final decisionStr = accepted ? 'accept' : 'decline';
          final ackHmac = hexOf(
            hmacSha256(
              kPair,
              ascii.encode('LSP-R1-DECISION:${record.offerId}:$decisionStr'),
            ),
          );
          final reply = ReplyRecord(
            seq: ++_seq,
            issuedAt: clock.now().millisecondsSinceEpoch,
            offerId: record.offerId,
            decision: decisionStr,
            sealedAck: ackHmac,
          );
          final outboundChannel = channelDeriver.deriveChannelId(
            pairKey: kPair,
            peerDeviceId: contact.deviceId,
            epoch: epoch,
          );
          final payload = envelopeCodec.seal(
            record: reply,
            envelopeKey: envelopeKey,
            channelIdHex: outboundChannel,
          );
          await backend.publish(
            RelayEvent(
              id: hexOf(sha256Bytes(payload)),
              channelIdHex: outboundChannel,
              payload: payload,
              createdAt: clock.now().millisecondsSinceEpoch ~/ 1000,
            ),
          );
        }
      } else if (record is ReplyRecord) {
        final completer = _pendingOffers.remove(record.offerId);
        completer?.complete(record);
      } else if (record is RevokeRecord) {
        presenceCache.evict(contact.deviceId);
      }
    }
  }

  @override
  Future<void> broadcastPresence() async {
    // When Receive mode is Off (AnnouncePolicy.none), zero presence events are published!
    if (announcePolicy == AnnouncePolicy.none) {
      return;
    }

    final now = clock.now();
    final epoch = channelDeriver.currentEpoch(now: now);

    for (final contact in trust.contacts) {
      if (!contact.hasPairKey) continue;
      final kPair = await secrets.get('kpair/${contact.deviceId}');
      if (kPair == null) continue;

      // Outbound to contact's channel (where contact is target)
      final outboundChannel = channelDeriver.deriveChannelId(
        pairKey: kPair,
        peerDeviceId: contact.deviceId,
        epoch: epoch,
      );
      final envelopeKey = channelDeriver.deriveEnvelopeKey(
        pairKey: kPair,
        epoch: epoch,
      );

      final record = PresenceRecord(
        seq: ++_seq,
        issuedAt: now.millisecondsSinceEpoch,
        candidates: localCandidates,
      );

      final payload = envelopeCodec.seal(
        record: record,
        envelopeKey: envelopeKey,
        channelIdHex: outboundChannel,
      );

      await backend.publish(
        RelayEvent(
          id: hexOf(sha256Bytes(payload)),
          channelIdHex: outboundChannel,
          payload: payload,
          createdAt: now.millisecondsSinceEpoch ~/ 1000,
        ),
      );
    }
  }

  @override
  Future<ReplyRecord> sendOffer(
    String peerDeviceId,
    OfferRecord offer, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final kPair = await secrets.get('kpair/$peerDeviceId');
    if (kPair == null) {
      throw LsException(LsErrorCode.notFound, 'peer not paired');
    }

    final now = clock.now();
    final epoch = channelDeriver.currentEpoch(now: now);
    final outboundChannel = channelDeriver.deriveChannelId(
      pairKey: kPair,
      peerDeviceId: peerDeviceId,
      epoch: epoch,
    );
    final envelopeKey = channelDeriver.deriveEnvelopeKey(
      pairKey: kPair,
      epoch: epoch,
    );

    final payload = envelopeCodec.seal(
      record: offer,
      envelopeKey: envelopeKey,
      channelIdHex: outboundChannel,
    );

    final completer = Completer<ReplyRecord>();
    _pendingOffers[offer.offerId] = completer;

    await backend.publish(
      RelayEvent(
        id: hexOf(sha256Bytes(payload)),
        channelIdHex: outboundChannel,
        payload: payload,
        createdAt: now.millisecondsSinceEpoch ~/ 1000,
      ),
    );

    final reply = await completer.future.timeout(
      timeout,
      onTimeout: () {
        _pendingOffers.remove(offer.offerId);
        throw TimeoutException('offer timeout');
      },
    );

    // Verify cryptographic sealedAck
    final expectedHmac = hexOf(
      hmacSha256(
        kPair,
        ascii.encode('LSP-R1-DECISION:${offer.offerId}:${reply.decision}'),
      ),
    );
    if (reply.sealedAck != expectedHmac) {
      throw LsException(LsErrorCode.authInvalid, 'invalid sealed decision ack');
    }

    return reply;
  }

  @override
  Future<void> revokePairing(String peerDeviceId) async {
    final kPair = await secrets.get('kpair/$peerDeviceId');
    if (kPair != null) {
      final now = clock.now();
      final epoch = channelDeriver.currentEpoch(now: now);
      final outboundChannel = channelDeriver.deriveChannelId(
        pairKey: kPair,
        peerDeviceId: peerDeviceId,
        epoch: epoch,
      );
      final envelopeKey = channelDeriver.deriveEnvelopeKey(
        pairKey: kPair,
        epoch: epoch,
      );

      final record = RevokeRecord(
        seq: ++_seq,
        issuedAt: now.millisecondsSinceEpoch,
        revokedAt: now.millisecondsSinceEpoch,
      );

      final payload = envelopeCodec.seal(
        record: record,
        envelopeKey: envelopeKey,
        channelIdHex: outboundChannel,
      );

      await backend.publish(
        RelayEvent(
          id: hexOf(sha256Bytes(payload)),
          channelIdHex: outboundChannel,
          payload: payload,
          createdAt: now.millisecondsSinceEpoch ~/ 1000,
        ),
      );
    }

    presenceCache.evict(peerDeviceId);
    await secrets.delete('kpair/$peerDeviceId');
    await trust.setPairKey(peerDeviceId, false);
  }

  @override
  Future<void> stop() async {
    _periodicTimer?.cancel();
    _periodicTimer = null;
    await _backendSub?.cancel();
    _backendSub = null;
    await backend.disconnect();
    await _presenceCtrl.close();
  }
}
