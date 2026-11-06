import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/navigation_provider.dart';
import '../providers/platform_providers.dart';
import '../providers/router_provider.dart';
import '../providers/transfers_provider.dart';
import 'incoming_transfer_dialog.dart';

/// Shows the consent dialog for every incoming request, one at a time, over
/// whatever screen is open, and carries out the decision. Wraps the whole app.
class IncomingHost extends ConsumerStatefulWidget {
  const IncomingHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<IncomingHost> createState() => _IncomingHostState();
}

class _IncomingHostState extends ConsumerState<IncomingHost> {
  final Set<String> _handled = {};
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _maybeShow(ref.read(incomingRequestsProvider)),
    );
  }

  void _maybeShow(List<TransferView> pending) {
    if (!mounted || _showing) return;
    final next = pending.where((t) => !_handled.contains(t.key)).firstOrNull;
    if (next == null) return;
    _handled.add(next.key);
    _showing = true;
    unawaited(_present(next.key));
  }

  Future<void> _present(String key) async {
    // A hidden window (tray) must come forward for a request.
    unawaited(ref.read(platformServicesProvider).window.show());
    final navigator = ref.read(rootNavigatorKeyProvider).currentContext;
    IncomingDecision? decision;
    if (navigator != null && navigator.mounted) {
      decision = await showDialog<IncomingDecision>(
        context: navigator,
        barrierDismissible: false,
        useRootNavigator: true,
        builder: (_) => IncomingTransferDialog(transferKey: key),
      );
    }
    if (!mounted) return;
    final transfers = ref.read(transfersProvider.notifier);
    switch (decision) {
      case IncomingDecision.accept:
        await transfers.acceptIncoming(key);
        if (mounted && ref.read(transferProvider(key)) != null) {
          ref.read(routerProvider).push('/transfer/$key');
        }
      case IncomingDecision.reject || IncomingDecision.expired:
        await transfers.rejectIncoming(key);
      case IncomingDecision.gone || null:
        break;
    }
    _showing = false;
    if (mounted) _maybeShow(ref.read(incomingRequestsProvider));
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<List<TransferView>>(
      incomingRequestsProvider,
      (_, next) => _maybeShow(next),
    );
    return widget.child;
  }
}
