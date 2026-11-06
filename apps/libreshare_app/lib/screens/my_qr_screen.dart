import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

import '../l10n_strings.dart';
import '../providers/engine_provider.dart';
import '../providers/receive_provider.dart';
import '../widgets/device_card.dart';

/// My QR (spec section 9, screen 8): the `libreshare://peer` link of this
/// device as a QR code, plus the same text to copy for devices without a
/// camera. There is nothing to show while Receive is off (no open listener).
class MyQrScreen extends ConsumerWidget {
  const MyQrScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = ref.watch(engineOrNullProvider);
    // Rebuild when Receive turns on or off: the link exists only while the
    // listener is open.
    ref.watch(receiveStatusProvider);
    final link = engine?.myPeerLink;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(tr('qr.title'))),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              if (link == null) ...[
                const SizedBox(height: 24),
                Icon(Icons.qr_code_2, size: 72, color: theme.disabledColor),
                const SizedBox(height: 16),
                Text(
                  tr('qr.unavailable'),
                  key: const Key('qr-unavailable'),
                  style: theme.textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(tr('qr.unavailableHelp'), textAlign: TextAlign.center),
                const SizedBox(height: 24),
                Center(
                  child: FilledButton.icon(
                    key: const Key('qr-turn-on'),
                    onPressed: () =>
                        ref.read(receiveActionsProvider).setEnabled(true),
                    icon: const Icon(Icons.wifi_tethering),
                    label: Text(tr('qr.turnOnReceive')),
                  ),
                ),
              ] else ...[
                Text(
                  tr('qr.help'),
                  style: theme.textTheme.bodyLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Semantics(
                  container: true,
                  image: true,
                  label: tr('qr.semantics', {
                    'alias': engine!.deviceInfo.alias,
                    'address': hostPort(link.ip, link.port),
                  }),
                  child: Container(
                    key: const Key('qr-code'),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: PrettyQrView.data(
                        data: link.toUri(),
                        decoration: const PrettyQrDecoration(
                          shape: PrettyQrSmoothSymbol(color: Colors.black),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Center(
                  child: Text(
                    engine.deviceInfo.alias,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                Center(child: Text(hostPort(link.ip, link.port))),
                const SizedBox(height: 16),
                SelectableText(
                  link.toUri(),
                  key: const Key('qr-link-text'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(height: 16),
                Center(
                  child: FilledButton.icon(
                    key: const Key('qr-copy'),
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: link.toUri()),
                      );
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(tr('qr.copied'))),
                        );
                      }
                    },
                    icon: const Icon(Icons.copy),
                    label: Text(tr('qr.copy')),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Center(
                child: TextButton(
                  onPressed: () =>
                      context.canPop() ? context.pop() : context.go('/'),
                  child: Text(tr('common.done')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
