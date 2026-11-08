import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:libreshare_core/libreshare_core.dart';

import '../l10n_strings.dart';
import '../providers/platform_providers.dart';
import '../providers/transfers_provider.dart';
import '../services/format.dart';
import '../services/paths.dart';
import '../widgets/channel_badge.dart';

String _formatSas(String code) {
  if (code.length == 6) {
    return '${code.substring(0, 3)} ${code.substring(3)}';
  }
  return code;
}

String failureText(TransferView t) {
  if (t.keyChanged) {
    return 'The security key of ${t.peerAlias} changed. Nothing was sent.';
  }
  if (t.insecurePeer) {
    return '${t.peerAlias} uses an older version without encryption. Nothing was sent.';
  }
  if (t.refusal == LsErrorCode.pinInvalid) {
    return tr('failure.pinInvalid');
  }
  if (t.refusal == LsErrorCode.blocked) return tr('failure.pinBlocked');
  if (t.localFileError) return tr('failure.localFile');
  return switch (t.failure) {
    FailureReason.rejected =>
      t.isOutgoing
          ? tr('failure.rejected', {'peer': t.peerAlias})
          : tr('failure.rejectedByYou', {'peer': t.peerAlias}),
    FailureReason.timeout => tr('failure.timeout'),
    FailureReason.cancelled => tr('failure.cancelled'),
    FailureReason.verifyFailed => tr('failure.verifyFailed'),
    FailureReason.noConnection => tr(
      t.wasTransferring ? 'failure.lost' : 'failure.noConnection',
      {'peer': t.peerAlias},
    ),
    FailureReason.diskFull => tr('failure.diskFull'),
    FailureReason.storageUnusable => tr('failure.storageUnusable'),
    FailureReason.protocolError || null => tr('failure.protocol'),
  };
}

/// Waiting + progress + completion for one transfer (spec section 9, screens
/// 2, 4 and 5). The route key is [TransferView.key].
class TransferScreen extends ConsumerWidget {
  const TransferScreen({super.key, required this.transferKey});

  final String transferKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(transferProvider(transferKey));
    void leave() {
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/');
      }
    }

    if (t == null) {
      return Scaffold(
        appBar: AppBar(title: Text(tr('transfer.title'))),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tr('transfer.unknown'),
                  key: const Key('transfer-unknown'),
                ),
                const SizedBox(height: 16),
                FilledButton(onPressed: leave, child: Text(tr('common.back'))),
              ],
            ),
          ),
        ),
      );
    }

    final title = t.isOutgoing
        ? tr('transfer.titleSend', {'peer': t.peerAlias})
        : tr('transfer.titleReceive', {'peer': t.peerAlias});
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 16),
            child: Center(child: ChannelBadge(kind: CandidateKind.wifi)),
          ),
        ],
      ),
      body: Stack(
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  switch (t.phase) {
                    TransferPhase.preparing => _Waiting(
                      key: const Key('transfer-preparing'),
                      headline: tr('transfer.preparing'),
                      showSas: false,
                      transfer: t,
                    ),
                    TransferPhase.waiting => _Waiting(
                      key: const Key('transfer-waiting'),
                      headline: tr('transfer.waitingFor', {
                        'peer': t.peerAlias,
                      }),
                      showSas: true,
                      transfer: t,
                    ),
                    TransferPhase.awaitingConsent => _AwaitingYou(transfer: t),
                    TransferPhase.transferring => _Progress(transfer: t),
                    TransferPhase.completed => _Done(
                      transfer: t,
                      onDone: leave,
                    ),
                    _ => _Failed(transfer: t, onBack: leave),
                  },
                ],
              ),
            ),
          ),
          if (t.pinRequired)
            Positioned.fill(
              child: Container(
                color: Colors.black54,
                alignment: Alignment.center,
                padding: const EdgeInsets.all(16),
                child: _PinDialog(transfer: t),
              ),
            ),
        ],
      ),
    );
  }
}

class _PinDialog extends ConsumerStatefulWidget {
  const _PinDialog({required this.transfer});

  final TransferView transfer;

  @override
  ConsumerState<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends ConsumerState<_PinDialog> {
  // The PIN lives only here and in the retryWithPin call.
  final TextEditingController _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final pin = _controller.text.trim();
    if (!RegExp(r'^[0-9]{6}$').hasMatch(pin)) {
      setState(() => _error = tr('pin.enter6'));
      return;
    }
    _controller.clear();
    ref.read(transfersProvider.notifier).retryWithPin(widget.transfer.key, pin);
  }

  @override
  Widget build(BuildContext context) {
    final peer = widget.transfer.peerAlias;
    return Card(
      key: const Key('pin-dialog'),
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Enter PIN', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                'Ask $peer for the 6-digit PIN on their screen.',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('pin-field'),
                controller: _controller,
                keyboardType: TextInputType.number,
                maxLength: 6,
                textAlign: TextAlign.center,
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: '6-digit PIN',
                  hintText: '000000',
                  errorText: _error,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              FilledButton(
                key: const Key('pin-submit'),
                onPressed: _submit,
                child: Text(tr('pin.submit')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CancelButton extends ConsumerWidget {
  const _CancelButton({required this.transfer});

  final TransferView transfer;

  @override
  Widget build(BuildContext context, WidgetRef ref) => OutlinedButton.icon(
    key: const Key('transfer-cancel'),
    onPressed: () =>
        unawaited(ref.read(transfersProvider.notifier).cancel(transfer.key)),
    icon: const Icon(Icons.close),
    label: Text(tr('transfer.cancel')),
  );
}

class _Waiting extends StatelessWidget {
  const _Waiting({
    super.key,
    required this.headline,
    required this.showSas,
    required this.transfer,
  });

  final String headline;
  final bool showSas;
  final TransferView transfer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        const SizedBox(height: 24),
        const SizedBox(
          width: 64,
          height: 64,
          child: CircularProgressIndicator(),
        ),
        const SizedBox(height: 24),
        Semantics(
          liveRegion: true,
          child: Text(
            headline,
            style: theme.textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          trPlural('transfer.fileCount', transfer.files.length, {
            'size': formatBytes(transfer.bytesTotal),
          }),
          style: theme.textTheme.bodyMedium,
        ),
        if (transfer.sasCode != null) ...[
          const SizedBox(height: 24),
          Container(
            key: const Key('sender-sas-code-block'),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.shield_outlined),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    'Verification code ${_formatSas(transfer.sasCode!)}. Tell ${transfer.peerAlias} to compare it, then wait for them to accept.',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
        ] else if (showSas) ...[
          const SizedBox(height: 24),
          Container(
            key: const Key('sas-placeholder'),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.shield_outlined),
                const SizedBox(width: 12),
                Flexible(child: Text(tr('sas.placeholder'))),
              ],
            ),
          ),
        ],
        const SizedBox(height: 24),
        _CancelButton(transfer: transfer),
      ],
    );
  }
}

class _AwaitingYou extends ConsumerWidget {
  const _AwaitingYou({required this.transfer});

  final TransferView transfer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(transfersProvider.notifier);
    return Column(
      key: const Key('transfer-awaiting-you'),
      children: [
        const SizedBox(height: 24),
        Text(
          tr('transfer.awaitingYou', {'peer': transfer.peerAlias}),
          style: Theme.of(context).textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        Wrap(
          spacing: 12,
          children: [
            TextButton(
              onPressed: () => notifier.rejectIncoming(transfer.key),
              child: Text(tr('incoming.reject')),
            ),
            FilledButton(
              onPressed: () => notifier.acceptIncoming(transfer.key),
              child: Text(tr('incoming.accept')),
            ),
          ],
        ),
      ],
    );
  }
}

class _FileRows extends StatelessWidget {
  const _FileRows({required this.files, this.showBars = true});

  final List<TransferFile> files;
  final bool showBars;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        for (final f in files)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Semantics(
              container: true,
              label: tr('transfer.fileSemantics', {
                'name': f.name,
                'pct': (f.fraction * 100).floor(),
              }),
              excludeSemantics: true,
              child: Column(
                key: Key('file-${f.id}'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        f.isDone
                            ? Icons.check_circle
                            : Icons.insert_drive_file_outlined,
                        size: 18,
                        color: f.isDone ? theme.colorScheme.primary : null,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          f.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${formatBytes(f.done > f.size ? f.size : f.done)} / ${formatBytes(f.size)}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                  if (showBars) ...[
                    const SizedBox(height: 4),
                    LinearProgressIndicator(
                      key: Key('file-bar-${f.id}'),
                      value: f.fraction,
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.transfer});

  final TransferView transfer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = transfer;
    final pct = (t.fraction * 100).floor();
    final eta = t.eta;
    return Column(
      key: const Key('transfer-progress'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          container: true,
          label: tr('transfer.overallSemantics', {'pct': pct}),
          excludeSemantics: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$pct%',
                key: const Key('overall-percent'),
                style: theme.textTheme.displaySmall,
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                key: const Key('overall-bar'),
                value: t.fraction,
                minHeight: 8,
              ),
              const SizedBox(height: 8),
              Text(
                '${formatBytes(t.bytesDone)} / ${formatBytes(t.bytesTotal)}',
                key: const Key('overall-bytes'),
              ),
              Text(
                [
                  if (t.speed >= 1) formatSpeed(t.speed),
                  if (eta != null) formatEta(eta),
                ].join('  ·  '),
                key: const Key('overall-speed'),
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        _FileRows(files: t.files),
        const SizedBox(height: 24),
        Center(child: _CancelButton(transfer: t)),
      ],
    );
  }
}

class _Done extends ConsumerWidget {
  const _Done({required this.transfer, required this.onDone});

  final TransferView transfer;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = transfer;
    final launcher = ref.read(fileLauncherProvider);
    final paths = t.savedPaths;

    Future<void> run(Future<bool> Function() action, String where) async {
      var ok = false;
      try {
        ok = await action();
      } on Object {
        ok = false;
      }
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('transfer.cantOpen', {'path': where}))),
        );
      }
    }

    return Column(
      key: const Key('transfer-done'),
      children: [
        const SizedBox(height: 16),
        Icon(Icons.check_circle, size: 72, color: theme.colorScheme.primary),
        const SizedBox(height: 16),
        Semantics(
          liveRegion: true,
          child: Text(
            transferDoneText(t),
            style: theme.textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 4),
        Text(formatBytes(t.bytesTotal)),
        if (!t.isOutgoing && t.savedFolder != null) ...[
          const SizedBox(height: 4),
          Text(
            tr('transfer.savedIn', {
              'where': describeSavedLocation(t.savedFolder!),
            }),
            key: const Key('transfer-saved-location'),
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 16),
        _FileRows(files: t.files, showBars: false),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            if (!t.isOutgoing && paths.length == 1)
              FilledButton.icon(
                key: const Key('transfer-open'),
                onPressed: () =>
                    run(() => launcher.open(paths.first), paths.first),
                icon: const Icon(Icons.open_in_new),
                label: Text(tr('transfer.open')),
              ),
            if (!t.isOutgoing && paths.isNotEmpty)
              OutlinedButton.icon(
                key: const Key('transfer-show-folder'),
                onPressed: () => run(
                  () => launcher.showInFolder(paths.first),
                  t.savedFolder ?? paths.first,
                ),
                icon: const Icon(Icons.folder_open),
                label: Text(tr('transfer.showInFolder')),
              ),
            TextButton(
              key: const Key('transfer-done-button'),
              onPressed: onDone,
              child: Text(tr('common.done')),
            ),
          ],
        ),
      ],
    );
  }
}

String transferDoneText(TransferView t) => t.isOutgoing
    ? trPlural('transfer.sentCount', t.files.length, {'peer': t.peerAlias})
    : trPlural('transfer.receivedCount', t.files.length, {'peer': t.peerAlias});

class _Failed extends StatelessWidget {
  const _Failed({required this.transfer, required this.onBack});

  final TransferView transfer;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cancelled = transfer.phase == TransferPhase.cancelled;
    return Column(
      key: const Key('transfer-failed'),
      children: [
        const SizedBox(height: 16),
        Icon(
          cancelled ? Icons.cancel : Icons.error,
          size: 72,
          color: theme.colorScheme.error,
        ),
        const SizedBox(height: 16),
        Semantics(
          liveRegion: true,
          child: Text(
            failureText(transfer),
            key: const Key('failure-text'),
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 24),
        FilledButton(
          key: const Key('transfer-back'),
          onPressed: onBack,
          child: Text(tr('common.back')),
        ),
      ],
    );
  }
}
