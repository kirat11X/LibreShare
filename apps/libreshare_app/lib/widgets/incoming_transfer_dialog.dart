import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:libreshare_core/libreshare_core.dart';

import '../l10n_strings.dart';
import '../providers/engine_provider.dart';
import '../providers/platform_providers.dart';
import '../providers/transfers_provider.dart';
import '../services/format.dart';
import 'platform_icon.dart';

enum IncomingDecision {
  accept,
  reject,

  /// The 120 s countdown ran out.
  expired,

  /// The request was settled elsewhere (sender cancelled, engine timeout).
  gone,
}

/// The consent prompt (spec section 9, screen 3): who wants to send what, with
/// Accept / Reject and a countdown that rejects on its own. The verification
/// code (SAS) arrives with Increment 3: its place is marked.
class IncomingTransferDialog extends ConsumerStatefulWidget {
  const IncomingTransferDialog({super.key, required this.transferKey});

  final String transferKey;

  /// The countdown the prompt shows (spec: 120 s).
  static const Duration timeout = Duration(seconds: 120);

  @override
  ConsumerState<IncomingTransferDialog> createState() =>
      _IncomingTransferDialogState();
}

String _formatSas(String code) {
  if (code.length == 6) {
    return '${code.substring(0, 3)} ${code.substring(3)}';
  }
  return code;
}

String _trustLabel(PeerTrust trust) => switch (trust) {
  PeerTrust.unknown => 'New device',
  PeerTrust.known => 'Known device',
  PeerTrust.trusted => 'Trusted contact',
  PeerTrust.blocked => 'Blocked',
};

class _IncomingTransferDialogState
    extends ConsumerState<IncomingTransferDialog> {
  Timer? _timer;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Duration _remaining(TransferView t) {
    final deadline =
        t.consentDeadline ?? t.createdAt.add(IncomingTransferDialog.timeout);
    return deadline.difference(ref.read(clockProvider).now());
  }

  void _tick() {
    if (!mounted || _closing) return;
    final t = ref.read(transferProvider(widget.transferKey));
    if (t == null || t.phase != TransferPhase.awaitingConsent) return;
    if (_remaining(t) <= Duration.zero) {
      _close(IncomingDecision.expired);
    } else {
      setState(() {});
    }
  }

  void _close(IncomingDecision decision) {
    if (_closing) return;
    _closing = true;
    Navigator.of(context).pop(decision);
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(transferProvider(widget.transferKey));
    if (t == null || t.phase != TransferPhase.awaitingConsent) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _close(IncomingDecision.gone);
      });
    }
    if (t == null) return const SizedBox.shrink();

    final engine = ref.watch(engineOrNullProvider);
    final info = t.sessionId != null
        ? engine?.incomingInfo(t.sessionId!)
        : engine?.incomingInfo(widget.transferKey);

    final theme = Theme.of(context);
    final remaining = _remaining(t);
    final total =
        (t.consentDeadline ?? t.createdAt.add(IncomingTransferDialog.timeout))
            .difference(t.createdAt)
            .inMilliseconds;
    final fraction = total <= 0
        ? 0.0
        : (remaining.inMilliseconds / total).clamp(0.0, 1.0);
    const maxListed = 5;
    final listed = t.files.take(maxListed).toList();
    final more = t.files.length - listed.length;
    final trustLabel = info != null ? _trustLabel(info.trust) : null;

    return AlertDialog(
      key: const Key('incoming-dialog'),
      scrollable: true,
      title: Text(tr('incoming.title')),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (info?.keyChanged == true)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          color: theme.colorScheme.error,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            "This device's security key changed. It may be a new phone, or someone pretending to be it.",
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onErrorContainer,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () {
                        final router = GoRouter.of(context);
                        _close(IncomingDecision.reject);
                        router.go('/settings');
                      },
                      child: const Text('Open Contacts'),
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: theme.colorScheme.primaryContainer,
                  foregroundColor: theme.colorScheme.onPrimaryContainer,
                  child: Icon(platformIcon(t.peerPlatform)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.peerAlias,
                        key: const Key('incoming-sender'),
                        style: theme.textTheme.titleMedium,
                      ),
                      Text(
                        t.peerAddress.isEmpty
                            ? platformLabel(t.peerPlatform)
                            : '${platformLabel(t.peerPlatform)}  ·  ${t.peerAddress}',
                        key: const Key('incoming-sender-detail'),
                        style: theme.textTheme.bodyMedium,
                      ),
                      if (trustLabel != null) ...[
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.secondaryContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            trustLabel,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSecondaryContainer,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              trPlural('incoming.wantsToSend', t.files.length, {
                'size': formatBytes(t.bytesTotal),
              }),
              key: const Key('incoming-summary'),
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 8),
            for (final f in listed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    const Icon(Icons.insert_drive_file_outlined, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        f.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(formatBytes(f.size), style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            if (more > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(tr('incoming.more', {'n': more})),
              ),
            if (info != null && info.sasRequired) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Verification code',
                      style: theme.textTheme.titleMedium,
                    ),
                    if (info.sasCode != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _formatSas(info.sasCode!),
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          fontSize: 24.0,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Ask ${t.peerAlias} to read the code on their screen. Accept only if it is the same.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ],
                ),
              ),
            ] else ...[
              const SizedBox(height: 16),
              Container(
                key: const Key('sas-placeholder'),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.shield_outlined),
                    const SizedBox(width: 12),
                    Expanded(child: Text(tr('sas.placeholder'))),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            Semantics(
              container: true,
              label: tr('incoming.countdownSemantics', {
                'time': formatCountdown(remaining),
              }),
              excludeSemantics: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(value: fraction),
                  const SizedBox(height: 4),
                  Text(
                    tr('incoming.countdown', {
                      'time': formatCountdown(remaining),
                    }),
                    key: const Key('incoming-countdown'),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('incoming-reject'),
          onPressed: () => _close(IncomingDecision.reject),
          child: Text(tr('incoming.reject')),
        ),
        if (info?.keyChanged != true)
          FilledButton(
            key: const Key('incoming-accept'),
            onPressed: (info?.sasRequired == true && info?.sasCode == null)
                ? null
                : () => _close(IncomingDecision.accept),
            child: Text(tr('incoming.accept')),
          ),
      ],
    );
  }
}
