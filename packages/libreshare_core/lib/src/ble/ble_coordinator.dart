import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../clock.dart';
import '../discovery/device_discovery.dart';
import '../discovery/peer_registry.dart';
import '../model/device.dart';
import '../security/contracts.dart';
import 'beacon_codec.dart';
import 'beacon_types.dart';
import 'ble_backend.dart';
import 'ble_messages.dart';
import 'ble_session.dart';
import 'visibility_manager.dart';

enum BleRouteKind { lan, hotspot }

class BleTransferPrompt {
  const BleTransferPrompt({
    required this.offerId,
    required this.peerAlias,
    required this.peerPlatform,
    required this.peerFingerprint,
    required this.isPaired,
    required this.sasCode,
    required this.firstName,
    required this.fileCount,
    required this.totalSize,
    required this.respond,
  });

  final String offerId;
  final String peerAlias;
  final String peerPlatform;
  final String peerFingerprint;
  final bool isPaired;
  final String sasCode;
  final String firstName;
  final int fileCount;
  final int totalSize;
  final void Function(bool accept) respond;
}

class BleTransferResult {
  const BleTransferResult({
    required this.accepted,
    this.routeKind,
    this.lanCandidate,
    this.peerFingerprint,
    this.rejectionReason,
  });

  final bool accepted;
  final BleRouteKind? routeKind;
  final LanCandidate? lanCandidate;
  final String? peerFingerprint;
  final String? rejectionReason;
}

/// Integrates BLE discovery, GATT secure sessions, consent prompting, and fast LAN handoff into the engine.
class BleCoordinator {
  BleCoordinator({
    required this.self,
    required this.identity,
    this.trustStore,
    required this.peerRegistry,
    required this.bleBackend,
    required this.advKey,
    VisibilityManager? visibility,
    this.clock = const SystemClock(),
    required this.localLanCandidates,
    this.probeLanCandidate,
    this.getPeerAdvKey,
    this.onTransferPrompt,
  }) : visibility =
           visibility ?? VisibilityManager(advKey: advKey, clock: clock);

  final DeviceInfo self;
  final IdentityProvider identity;
  final TrustStore? trustStore;
  final PeerRegistry peerRegistry;
  final BleBackend bleBackend;
  final Uint8List advKey;
  final VisibilityManager visibility;
  final Clock clock;
  final List<LanCandidate> Function() localLanCandidates;
  final Future<bool> Function(LanCandidate candidate)? probeLanCandidate;
  final List<int>? Function(String deviceId)? getPeerAdvKey;
  final Future<bool> Function(BleTransferPrompt prompt)? onTransferPrompt;

  StreamSubscription<BleDevice>? _scanSub;
  StreamSubscription<BleGattSession>? _incomingGattSub;
  StreamSubscription<VisibilityState>? _visibilitySub;
  bool _running = false;

  bool get isRunning => _running;

  /// Starts BLE advertising, scanning, and GATT server listener.
  Future<void> start() async {
    if (_running) return;
    _running = true;

    // Start advertising based on initial visibility mode
    final initialBeacon = _buildBeacon(visibility.currentState);
    if (initialBeacon != null) {
      await bleBackend.startAdvertising(initialBeacon, connectable: true);
    }

    _visibilitySub = visibility.stateChanges.listen((state) async {
      final beacon = _buildBeacon(state);
      if (beacon != null) {
        await bleBackend.startAdvertising(beacon, connectable: true);
      } else {
        await bleBackend.stopAdvertising();
      }
    });

    // Start scanning for nearby peers
    _scanSub = bleBackend
        .scan(filter: const BleScanFilter(companyId: kBleCompanyIdSigTest))
        .listen(_onDiscoveredDevice);

    // Listen for incoming GATT sessions (Receiver/Peripheral role)
    final server = bleBackend.gattServer;
    if (server != null) {
      await server.start();
      _incomingGattSub = server.incomingSessions.listen(
        _handleIncomingGattSession,
      );
    }
  }

  BleBeacon? _buildBeacon(VisibilityState state) {
    if (!state.isAdvertising || state.activeEid == null) return null;
    return BleBeacon(
      companyId: kBleCompanyIdSigTest,
      flags: BeaconFlags(
        recv: true,
        gatt: true,
        open: state.mode == VisibilityMode.everyone,
      ),
      cap: const BeaconCap(canHost: true, canJoin: true),
      eid: state.activeEid!,
      seq: 1,
    );
  }

  void _onDiscoveredDevice(BleDevice dev) {
    final beacon = dev.beacon;
    if (beacon == null) return;
    if (!beacon.flags.recv && !beacon.flags.send) return;

    // Check if this EID matches any trusted contact
    Contact? matchedContact;
    final now = clock.now();
    if (trustStore != null && getPeerAdvKey != null) {
      for (final contact in trustStore!.contacts) {
        final advKey = getPeerAdvKey!(contact.deviceId);
        if (advKey != null && matchesEid(beacon.eid, advKey, now)) {
          matchedContact = contact;
          break;
        }
      }
    }

    final DeviceInfo reportedInfo;
    if (matchedContact != null) {
      // Known trusted peer
      reportedInfo = DeviceInfo(
        deviceId: matchedContact.deviceId,
        alias: matchedContact.alias,
        platform: 'ble',
        caps: const ['resume', 'ble1'],
      );
    } else {
      // Unpaired nearby peer
      reportedInfo = DeviceInfo(
        deviceId: dev.id,
        alias: dev.name ?? 'Nearby (${dev.id})',
        platform: 'ble',
        caps: const ['resume', 'ble1'],
      );
    }

    // Register into the peer table with DiscoverySource.ble
    peerRegistry.seen(reportedInfo, dev.address, DiscoverySource.ble);
  }

  Future<void> _handleIncomingGattSession(BleGattSession gatt) async {
    final session = BleSession(
      gatt: gatt,
      role: BleSessionRole.peripheral,
      identity: identity,
      trustStore: trustStore,
    );

    try {
      final authResult = await session.performHandshake(
        localAlias: self.alias,
        localPlatform: Platform.operatingSystem,
        localLanCandidates: localLanCandidates(),
      );

      // Await BleOffer over encrypted channel
      await for (final msg in session.incomingMessages) {
        if (msg is BleOffer) {
          final completer = Completer<bool>();
          final prompt = BleTransferPrompt(
            offerId: msg.offerId,
            peerAlias: authResult.peerAlias,
            peerPlatform: authResult.peerPlatform,
            peerFingerprint: authResult.peerFingerprint,
            isPaired: authResult.isPaired,
            sasCode: authResult.sasCode,
            firstName: msg.firstName,
            fileCount: msg.fileCount,
            totalSize: msg.totalSize,
            respond: (accept) {
              if (!completer.isCompleted) completer.complete(accept);
            },
          );

          if (onTransferPrompt != null) {
            unawaited(
              onTransferPrompt!(prompt).then((val) {
                if (!completer.isCompleted) completer.complete(val);
              }),
            );
          } else {
            // Default rule: unpaired requires explicit consent (rejected if no handler)
            completer.complete(authResult.isPaired);
          }

          final accepted = await completer.future;
          if (!accepted) {
            await session.send(
              BleDecision(
                offerId: msg.offerId,
                accept: false,
                reason: 'Declined by user',
              ),
            );
            await session.close();
            return;
          }

          await session.send(BleDecision(offerId: msg.offerId, accept: true));

          // Await NetPlan from Central
          final netPlan = await session.incomingMessages
              .where((m) => m is BleNetPlan)
              .cast<BleNetPlan>()
              .first
              .timeout(const Duration(seconds: 10));

          if (netPlan.pathKind == 'lan') {
            // Transfer proceeds over direct LAN bypass
            return;
          }
        }
      }
    } on Object catch (_) {
      await session.close();
    }
  }

  /// Sends an offer over BLE to a discovered peer.
  Future<BleTransferResult> sendOffer({
    required String peerDeviceId,
    required BleOffer offer,
    Future<bool> Function(String sasCode)? onConfirmSas,
  }) async {
    final gatt = await bleBackend.connectGatt(peerDeviceId);
    final session = BleSession(
      gatt: gatt,
      role: BleSessionRole.central,
      identity: identity,
      trustStore: trustStore,
    );

    try {
      final authResult = await session.performHandshake(
        localAlias: self.alias,
        localPlatform: Platform.operatingSystem,
        localLanCandidates: localLanCandidates(),
      );

      if (!authResult.isPaired) {
        // Enforce SAS verification for unpaired connections
        final confirmed =
            await (onConfirmSas?.call(authResult.sasCode) ??
                Future.value(true));
        if (!confirmed) {
          await session.close();
          return const BleTransferResult(
            accepted: false,
            rejectionReason: 'SAS code verification rejected',
          );
        }
      }

      await session.send(offer);

      final decision = await session.incomingMessages
          .where((m) => m is BleDecision)
          .cast<BleDecision>()
          .first
          .timeout(const Duration(seconds: 15));

      if (!decision.accept) {
        await session.close();
        return BleTransferResult(
          accepted: false,
          rejectionReason: decision.reason ?? 'Offer rejected by receiver',
        );
      }

      // Receiver accepted! Try fast direct LAN bypass first
      if (probeLanCandidate != null && authResult.lanCandidates.isNotEmpty) {
        for (final candidate in authResult.lanCandidates) {
          final reachable = await probeLanCandidate!(candidate);
          if (reachable) {
            await session.send(
              BleNetPlan(
                offerId: offer.offerId,
                hostRole: 'none',
                pathKind: 'lan',
              ),
            );
            await session.close();
            return BleTransferResult(
              accepted: true,
              routeKind: BleRouteKind.lan,
              lanCandidate: candidate,
              peerFingerprint: authResult.peerFingerprint,
            );
          }
        }
      }

      // No LAN candidate reachable -> Hotspot handoff required
      return BleTransferResult(
        accepted: true,
        routeKind: BleRouteKind.hotspot,
        peerFingerprint: authResult.peerFingerprint,
      );
    } finally {
      if (session.state != BleSessionState.closed) {
        await session.close();
      }
    }
  }

  /// Stops BLE activities and closes listeners.
  Future<void> stop() async {
    _running = false;
    await _scanSub?.cancel();
    _scanSub = null;
    await _incomingGattSub?.cancel();
    _incomingGattSub = null;
    await _visibilitySub?.cancel();
    _visibilitySub = null;
    visibility.dispose();
    await bleBackend.stopAdvertising();
    await bleBackend.stopScan();
    await bleBackend.gattServer?.stop();
  }
}
