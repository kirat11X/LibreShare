import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:libreshare_core/libreshare_core.dart';

import '../l10n_strings.dart';
import '../providers/platform_providers.dart';
import '../services/format.dart';
import 'platform_icon.dart';

/// Where a device was found, in words.
String sourceLabel(DiscoverySource source) => switch (source) {
  DiscoverySource.multicast => tr('source.multicast'),
  DiscoverySource.mdns => tr('source.mdns'),
  DiscoverySource.subnetScan => tr('source.scan'),
  DiscoverySource.manual => tr('source.manual'),
  DiscoverySource.qr => tr('source.qr'),
  DiscoverySource.register => tr('source.register'),
};

/// `ip:port`, with brackets around IPv6 literals.
String hostPort(String address, int port) =>
    address.contains(':') ? '[$address]:$port' : '$address:$port';

/// One device of the Nearby list: alias, platform icon, IP, last seen and how
/// it was found. The whole card is the "send files to this device" target.
class DeviceCard extends ConsumerWidget {
  const DeviceCard({super.key, required this.device, required this.onTap});

  final DiscoveredDevice device;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now =
        ref.watch(nowTickProvider).value ?? ref.watch(clockProvider).now();
    final info = device.info;
    final scheme = Theme.of(context).colorScheme;
    final seen = formatAgo(device.lastSeen, now);
    final where = hostPort(device.address, info.port);
    final platform = platformLabel(info.platform);
    return Semantics(
      container: true,
      label: tr('device.semantics', {
        'alias': info.alias,
        'platform': platform,
        'address': where,
        'seen': seen,
      }),
      hint: tr('device.sendHint'),
      excludeSemantics: true,
      button: true,
      onTap: onTap,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 72),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  CircleAvatar(
                    backgroundColor: scheme.primaryContainer,
                    foregroundColor: scheme.onPrimaryContainer,
                    child: Icon(platformIcon(info.platform, info.deviceType)),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          info.alias,
                          style: Theme.of(context).textTheme.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '$platform  ·  $where',
                          style: Theme.of(context).textTheme.bodyMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '$seen  ·  ${sourceLabel(device.source)}',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.send, color: scheme.primary),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
