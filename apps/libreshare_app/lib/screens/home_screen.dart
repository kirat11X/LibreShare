import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:libreshare_core/libreshare_core.dart';

import '../l10n_strings.dart';
import '../providers/discovery_providers.dart';
import '../providers/send_flow_provider.dart';
import '../providers/transfers_provider.dart';
import '../widgets/device_card.dart';
import '../widgets/empty_state.dart';
import '../widgets/receive_card.dart';
import '../widgets/transfer_card.dart';

/// Home / Nearby (spec section 9, screen 1).
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(deviceListProvider);
    final scan = ref.watch(scanProvider);
    final transfers = ref.watch(transfersProvider);
    final theme = Theme.of(context);

    Future<void> doScan() => ref.read(scanProvider.notifier).scan();

    Future<void> sendFiles() async {
      final picked = await ref.read(pickedFilesProvider.notifier).pick();
      if (picked && context.mounted) unawaited(context.push('/send'));
    }

    Future<void> sendTo(DiscoveredDevice device) async {
      final notifier = ref.read(pickedFilesProvider.notifier);
      if (ref.read(pickedFilesProvider).isEmpty) {
        if (!await notifier.pick()) return;
      }
      final key = ref.sendPickedFilesTo(device);
      if (context.mounted) unawaited(context.push('/transfer/$key'));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('home.title')),
        actions: [
          IconButton(
            key: const Key('action-scan'),
            tooltip: tr('home.scan'),
            icon: const Icon(Icons.radar),
            onPressed: scan.scanning ? null : doScan,
          ),
          IconButton(
            key: const Key('action-add'),
            tooltip: tr('home.addDevice'),
            icon: const Icon(Icons.add_link),
            onPressed: () => context.push('/add'),
          ),
          IconButton(
            key: const Key('action-qr'),
            tooltip: tr('home.myQr'),
            icon: const Icon(Icons.qr_code),
            onPressed: () => context.push('/my-qr'),
          ),
          IconButton(
            key: const Key('action-history'),
            tooltip: 'Transfer History',
            icon: const Icon(Icons.history),
            onPressed: () => context.push('/history'),
          ),
        ],
        bottom: scan.scanning
            ? const PreferredSize(
                preferredSize: Size.fromHeight(4),
                child: LinearProgressIndicator(key: Key('scan-progress')),
              )
            : null,
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('send-fab'),
        onPressed: sendFiles,
        icon: const Icon(Icons.upload_file),
        label: Text(tr('home.sendFiles')),
      ),
      // Empty state: the list ends above the floating button, so no button of
      // it is ever hidden under it. With devices the list scrolls under it.
      body: Padding(
        padding: EdgeInsets.only(bottom: devices.isEmpty ? 88 : 0),
        child: RefreshIndicator(
          onRefresh: doScan,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(
                  16,
                  16,
                  16,
                  devices.isEmpty ? 16 : 96,
                ),
                children: [
                  const ReceiveCard(),
                  if (transfers.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Semantics(
                      header: true,
                      child: Text(
                        tr('home.transfers'),
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (final t in transfers) ...[
                      TransferCard(key: Key('transfer-${t.key}'), transfer: t),
                      const SizedBox(height: 8),
                    ],
                  ],
                  const SizedBox(height: 24),
                  Semantics(
                    header: true,
                    child: Text(
                      tr('home.nearby'),
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (devices.isEmpty)
                    NoDevicesView(
                      onScan: doScan,
                      onAdd: () => context.push('/add'),
                      onShowQr: () => context.push('/my-qr'),
                    )
                  else
                    for (final d in devices) ...[
                      DeviceCard(
                        key: Key('device-${d.id}'),
                        device: d,
                        onTap: () => sendTo(d),
                      ),
                      const SizedBox(height: 8),
                    ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
