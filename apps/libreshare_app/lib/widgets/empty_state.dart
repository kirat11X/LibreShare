import 'package:flutter/material.dart';

import '../l10n_strings.dart';

/// Shown on Home when nobody is around: why that can happen (AP / client
/// isolation, Receive off on the other side) and what to do (scan, add by IP
/// or QR).
class NoDevicesView extends StatelessWidget {
  const NoDevicesView({
    super.key,
    required this.onScan,
    required this.onAdd,
    required this.onShowQr,
  });

  final VoidCallback onScan;
  final VoidCallback onAdd;
  final VoidCallback onShowQr;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: tr('empty.title'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 24),
        child: Column(
          key: const Key('no-devices'),
          children: [
            Icon(
              Icons.wifi_find,
              size: 64,
              color: theme.colorScheme.primary,
              semanticLabel: tr('empty.iconLabel'),
            ),
            const SizedBox(height: 16),
            Text(
              tr('empty.title'),
              style: theme.textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              tr('empty.body'),
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              tr('empty.isolation'),
              key: const Key('isolation-hint'),
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  key: const Key('empty-scan'),
                  onPressed: onScan,
                  icon: const Icon(Icons.radar),
                  label: Text(tr('home.scan')),
                ),
                OutlinedButton.icon(
                  key: const Key('empty-add'),
                  onPressed: onAdd,
                  icon: const Icon(Icons.add_link),
                  label: Text(tr('empty.addByIp')),
                ),
                OutlinedButton.icon(
                  key: const Key('empty-qr'),
                  onPressed: onShowQr,
                  icon: const Icon(Icons.qr_code),
                  label: Text(tr('home.myQr')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
