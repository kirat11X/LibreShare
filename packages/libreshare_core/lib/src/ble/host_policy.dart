import 'beacon_types.dart';

/// The winning party selected to host the ad-hoc Wi-Fi hotspot.
enum HostWinner { sideA, sideB, neither }

/// Deterministically elects the hotspot host between two peers (design 03 section 4.2).
///
/// Rules:
/// 1. Only one side `canHost` -> it hosts. If neither canHost -> `neither`.
/// 2. Prefer a side with `hostKeepsUplink` (Ethernet, STA+AP concurrency, cellular).
/// 3. Prefer Android LOHS (rank 3) > Linux NM (rank 2) > Windows legacy AP (rank 1) > other (rank 0).
/// 4. Tiebreaker: the receiver hosts (LSP server and hotspot on one machine, eliminating an IP handoff hop).
HostWinner chooseHost({
  required BeaconCap capA,
  required BeaconCap capB,
  required bool isReceiverA,
}) {
  // 1. Only one side canHost -> it hosts.
  if (capA.canHost && !capB.canHost) return HostWinner.sideA;
  if (!capA.canHost && capB.canHost) return HostWinner.sideB;
  if (!capA.canHost && !capB.canHost) return HostWinner.neither;

  // 2. Both canHost: prefer a side with hostKeepsUplink
  if (capA.hostKeepsUplink && !capB.hostKeepsUplink) return HostWinner.sideA;
  if (!capA.hostKeepsUplink && capB.hostKeepsUplink) return HostWinner.sideB;

  // 3. Platform preference order
  int platformRank(BlePlatform p) {
    switch (p) {
      case BlePlatform.android:
        return 3;
      case BlePlatform.linux:
        return 2;
      case BlePlatform.windows:
        return 1;
      case BlePlatform.macos:
      case BlePlatform.ios:
      case BlePlatform.other:
        return 0;
    }
  }

  final rankA = platformRank(capA.platform);
  final rankB = platformRank(capB.platform);
  if (rankA > rankB) return HostWinner.sideA;
  if (rankB > rankA) return HostWinner.sideB;

  // 4. Tiebreaker -> receiver hosts
  return isReceiverA ? HostWinner.sideA : HostWinner.sideB;
}
