import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:libreshare_core/libreshare_core.dart';

import 'channel_badge.dart';
import 'pair_dialog.dart';

/// Representation of a paired peer device with presence status and candidates.
class PairedPeerViewModel {
  const PairedPeerViewModel({
    required this.deviceId,
    required this.alias,
    required this.fingerprint,
    required this.isOnline,
    this.lastSeenMinutes = 0,
    this.candidateKind = CandidateKind.tunnel,
  });

  final String deviceId;
  final String alias;
  final String fingerprint;
  final bool isOnline;
  final int lastSeenMinutes;
  final CandidateKind candidateKind;
}

/// Card presenting paired peer devices, online/last-seen presence status, and unpairing actions.
class PairedPeersCard extends ConsumerStatefulWidget {
  const PairedPeersCard({super.key, this.initialPeers});

  final List<PairedPeerViewModel>? initialPeers;

  @override
  ConsumerState<PairedPeersCard> createState() => _PairedPeersCardState();
}

class _PairedPeersCardState extends ConsumerState<PairedPeersCard> {
  late List<PairedPeerViewModel> _peers;

  @override
  void initState() {
    super.initState();
    _peers = widget.initialPeers != null
        ? List.from(widget.initialPeers!)
        : const [
            PairedPeerViewModel(
              deviceId: 'peer-bob-uuid',
              alias: 'Bob Laptop',
              fingerprint: 'B1B2B3B4B5B6B7B8C1C2C3C4C5C6C7C8D1D2D3D4D5D6D7D8E1E2E3E4E5E6E7E8',
              isOnline: true,
              candidateKind: CandidateKind.tunnel,
            ),
          ];
  }

  void _unpair(String deviceId) {
    setState(() {
      _peers.removeWhere((p) => p.deviceId == deviceId);
    });
  }

  void _openPairDialog() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => const PairDialog(),
    );
    if (result == true) {
      setState(() {
        _peers.add(
          const PairedPeerViewModel(
            deviceId: 'peer-carol-uuid',
            alias: 'Carol Phone',
            fingerprint: 'A1A2A3A4A5A6A7A8B1B2B3B4B5B6B7B8C1C2C3C4C5C6C7C8D1D2D3D4D5D6D7D8',
            isOnline: true,
            candidateKind: CandidateKind.tunnel,
          ),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      key: const Key('settings-paired-peers-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.devices_other),
                const SizedBox(width: 8),
                Text(
                  'Paired Devices (Internet)',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                ElevatedButton.icon(
                  key: const Key('pair_new_device_button'),
                  icon: const Icon(Icons.add_link, size: 16),
                  label: const Text('Pair Device'),
                  onPressed: _openPairDialog,
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_peers.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    'No paired devices. Pair a device by QR to connect over the internet.',
                  ),
                ),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _peers.length,
                separatorBuilder: (_, _) => const Divider(),
                itemBuilder: (context, index) {
                  final p = _peers[index];
                  final shortFp = p.fingerprint.substring(
                    0,
                    min(16, p.fingerprint.length),
                  );

                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const CircleAvatar(
                      child: Icon(Icons.person_outline),
                    ),
                    title: Row(
                      children: [
                        Text(
                          p.alias,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(width: 8),
                        if (p.isOnline)
                          Chip(
                            key: Key('peer_online_chip_${p.deviceId}'),
                            label: const Text(
                              'Online',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.green,
                              ),
                            ),
                            backgroundColor: Colors.green.shade50,
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                          )
                        else
                          Chip(
                            key: Key('peer_last_seen_chip_${p.deviceId}'),
                            label: Text(
                              'Last seen ${p.lastSeenMinutes}m ago',
                              style: const TextStyle(fontSize: 10),
                            ),
                            backgroundColor: Colors.grey.shade200,
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'FP: $shortFp...',
                          style: const TextStyle(fontSize: 11),
                        ),
                        const SizedBox(height: 4),
                        ChannelBadge(
                          key: Key('peer_channel_badge_${p.deviceId}'),
                          kind: p.candidateKind,
                        ),
                      ],
                    ),
                    trailing: IconButton(
                      key: Key('peer_unpair_button_${p.deviceId}'),
                      icon: const Icon(Icons.link_off, color: Colors.red),
                      tooltip: 'Unpair',
                      onPressed: () => _unpair(p.deviceId),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
