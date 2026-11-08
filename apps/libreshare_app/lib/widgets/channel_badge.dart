import 'package:flutter/material.dart';
import 'package:libreshare_core/libreshare_core.dart';

/// Visual badge showing the active connection candidate channel tier (Increment 4).
class ChannelBadge extends StatelessWidget {
  const ChannelBadge({
    super.key,
    required this.kind,
    this.rtt,
    this.isFallingBack = false,
  });

  final CandidateKind kind;
  final Duration? rtt;
  final bool isFallingBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final (icon, label, color) = switch (kind) {
      CandidateKind.wifi => (Icons.wifi, 'Wi-Fi', colorScheme.primary),
      CandidateKind.lan => (Icons.lan, 'LAN', colorScheme.secondary),
      CandidateKind.loopback => (Icons.loop, 'Loopback', colorScheme.tertiary),
      CandidateKind.manual => (Icons.tune, 'Manual', colorScheme.outline),
      CandidateKind.tunnel => (Icons.cloud, 'Tunnel', colorScheme.error),
      CandidateKind.hotspot => (
        Icons.wifi_tethering,
        'Hotspot',
        colorScheme.secondary,
      ),
    };

    if (isFallingBack) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: colorScheme.onErrorContainer,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              'Switching tier...',
              style: theme.textTheme.labelSmall?.copyWith(
                color: colorScheme.onErrorContainer,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      );
    }

    return Tooltip(
      message: rtt != null ? '$label (${rtt!.inMilliseconds}ms)' : label,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
