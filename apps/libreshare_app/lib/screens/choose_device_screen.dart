import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../l10n_strings.dart';
import '../providers/discovery_providers.dart';
import '../providers/send_flow_provider.dart';
import '../services/format.dart';
import '../widgets/device_card.dart';

/// Send, step 2 (spec section 9, screen 2): the picked files and the device
/// to send them to.
class ChooseDeviceScreen extends ConsumerWidget {
  const ChooseDeviceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final files = ref.watch(pickedFilesProvider);
    final devices = ref.watch(deviceListProvider);
    final theme = Theme.of(context);
    final total = files.fold<int>(0, (a, f) => a + f.size);

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('send.title')),
        leading: BackButton(
          onPressed: () {
            ref.read(pickedFilesProvider.notifier).clear();
            context.pop();
          },
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        trPlural('send.filesSelected', files.length, {
                          'size': formatBytes(total),
                        }),
                        key: const Key('send-summary'),
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    key: const Key('send-add-more'),
                    onPressed: () => unawaited(
                      ref.read(pickedFilesProvider.notifier).pick(),
                    ),
                    icon: const Icon(Icons.add),
                    label: Text(tr('send.addMore')),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              for (final f in files)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.insert_drive_file_outlined),
                    title: Text(
                      f.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(formatBytes(f.size)),
                    trailing: IconButton(
                      tooltip: tr('send.remove', {'name': f.name}),
                      icon: const Icon(Icons.close),
                      onPressed: () =>
                          ref.read(pickedFilesProvider.notifier).remove(f),
                    ),
                  ),
                ),
              const SizedBox(height: 24),
              Semantics(
                header: true,
                child: Text(
                  tr('send.chooseDevice'),
                  style: theme.textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: 8),
              if (files.isEmpty)
                Text(tr('send.noFiles'), key: const Key('send-no-files'))
              else if (devices.isEmpty)
                Column(
                  key: const Key('send-no-devices'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tr('send.noDevices')),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () => context.push('/add'),
                      icon: const Icon(Icons.add_link),
                      label: Text(tr('home.addDevice')),
                    ),
                  ],
                )
              else
                for (final d in devices) ...[
                  DeviceCard(
                    key: Key('choose-${d.id}'),
                    device: d,
                    onTap: () {
                      final key = ref.sendPickedFilesTo(d);
                      context.pushReplacement('/transfer/$key');
                    },
                  ),
                  const SizedBox(height: 8),
                ],
            ],
          ),
        ),
      ),
    );
  }
}
