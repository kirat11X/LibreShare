import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../l10n_strings.dart';
import '../providers/platform_providers.dart';

/// Camera view that returns the first scanned code as the route result.
/// Reached only where the camera plugin exists (Android, iOS).
class ScanQrScreen extends ConsumerStatefulWidget {
  const ScanQrScreen({super.key});

  @override
  ConsumerState<ScanQrScreen> createState() => _ScanQrScreenState();
}

class _ScanQrScreenState extends ConsumerState<ScanQrScreen> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    final supported = ref.watch(qrScanSupportedProvider);
    return Scaffold(
      appBar: AppBar(title: Text(tr('scan.title'))),
      body: !supported
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  tr('scan.unsupported'),
                  key: const Key('scan-unsupported'),
                ),
              ),
            )
          : Stack(
              children: [
                Positioned.fill(
                  child: ref.read(qrScannerBuilderProvider)(context, (raw) {
                    if (_done) return;
                    _done = true;
                    context.pop(raw);
                  }),
                ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    margin: const EdgeInsets.all(16),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(tr('scan.hint')),
                  ),
                ),
              ],
            ),
    );
  }
}
