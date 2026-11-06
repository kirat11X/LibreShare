import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../l10n_strings.dart';
import '../providers/transfers_provider.dart';

/// Short status line for a transfer ("Sending to Pixel, 42%").
String transferStatusText(TransferView t) {
  final peer = t.peerAlias;
  switch (t.phase) {
    case TransferPhase.preparing:
      return tr('transfer.preparing');
    case TransferPhase.awaitingConsent:
      return tr('transfer.awaitingYou', {'peer': peer});
    case TransferPhase.waiting:
      return tr('transfer.waitingFor', {'peer': peer});
    case TransferPhase.transferring:
      final pct = (t.fraction * 100).floor();
      return t.isOutgoing
          ? tr('transfer.sendingTo', {'peer': peer, 'pct': pct})
          : tr('transfer.receivingFrom', {'peer': peer, 'pct': pct});
    case TransferPhase.completed:
      return t.isOutgoing
          ? trPlural('transfer.sentCount', t.files.length, {'peer': peer})
          : trPlural('transfer.receivedCount', t.files.length, {'peer': peer});
    case TransferPhase.cancelled:
      return tr('transfer.cancelled');
    case TransferPhase.rejected:
      return t.isOutgoing
          ? tr('transfer.rejected', {'peer': peer})
          : tr('transfer.rejectedByYou', {'peer': peer});
    case TransferPhase.failed:
      return tr('transfer.failed');
  }
}

/// A transfer on Home: peer, status, a progress bar while it runs; tap opens
/// the progress screen.
class TransferCard extends ConsumerWidget {
  const TransferCard({super.key, required this.transfer});

  final TransferView transfer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = transfer;
    final theme = Theme.of(context);
    final status = transferStatusText(t);
    final icon = t.isOutgoing ? Icons.upload : Icons.download;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push('/transfer/${t.key}'),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 72),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Row(
              children: [
                Icon(icon, color: theme.colorScheme.primary),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        status,
                        style: theme.textTheme.titleSmall,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (t.isActive) ...[
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                          value: t.phase == TransferPhase.transferring
                              ? t.fraction
                              : null,
                        ),
                      ],
                    ],
                  ),
                ),
                if (t.isFinished)
                  IconButton(
                    tooltip: tr('transfer.dismiss'),
                    icon: const Icon(Icons.close),
                    onPressed: () =>
                        ref.read(transfersProvider.notifier).dismiss(t.key),
                  )
                else
                  IconButton(
                    tooltip: tr('transfer.cancel'),
                    icon: const Icon(Icons.cancel_outlined),
                    onPressed: () =>
                        ref.read(transfersProvider.notifier).cancel(t.key),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
