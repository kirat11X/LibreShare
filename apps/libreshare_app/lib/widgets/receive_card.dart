import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:libreshare_core/libreshare_core.dart';

import '../l10n_strings.dart';
import '../providers/engine_provider.dart';
import '../providers/platform_providers.dart';
import '../providers/receive_provider.dart';
import '../services/format.dart';
import 'storage_prompt.dart';

/// Label of a duration choice: "15 min", "1 h", "6 h", "Always".
String receiveChoiceLabel(ReceiveMode mode) => switch (mode) {
  ReceiveAlways() => tr('receive.always'),
  ReceiveOff() => tr('receive.off'),
  ReceiveFor(:final duration) =>
    duration.inMinutes < 60
        ? tr('receive.minutes', {'n': duration.inMinutes})
        : tr('receive.hours', {'n': duration.inHours}),
};

/// The Receive card of design 01 section 5.1: status line built from the
/// [ReceiveState], the on/off switch, the quick durations and (in Settings)
/// who can see this device.
class ReceiveCard extends ConsumerWidget {
  const ReceiveCard({super.key, this.showVisibility = false});

  /// Settings shows the "Who can see this device" control; Home does not.
  final bool showVisibility;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(receiveStatusProvider);
    final choices = ref.watch(receiveChoicesProvider);
    final selected = ref.watch(selectedReceiveChoiceProvider);
    final actions = ref.read(receiveActionsProvider);
    final now =
        ref.watch(nowTickProvider).value ?? ref.watch(clockProvider).now();
    final capped =
        ref.watch(platformServicesProvider).caps.maxContinuous != null;
    final engine = ref.watch(engineOrNullProvider);
    final theme = Theme.of(context);
    final receiving = state is On || state is Draining;
    // Only a window PIN is shown; a fixed PIN is never displayed.
    final guard = receiving ? engine?.pinGuard : null;
    final activePin = guard?.policy.mode == PinMode.window
        ? guard?.currentPin
        : null;
    final canResume =
        state is Paused ||
        state is Failed ||
        (state is Off && state.reason == OffReason.expired);

    return Card(
      key: const Key('receive-card'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              key: const Key('receive-switch'),
              title: Text(
                tr('receive.title'),
                style: theme.textTheme.titleMedium,
              ),
              subtitle: Text(
                receiveStatusText(context, state, now),
                key: const Key('receive-status'),
              ),
              value: receiving || state is Starting,
              onChanged: state is Starting
                  ? null
                  : (v) async {
                      if (v && !await askStorageIfNeeded(context)) return;
                      await actions.setEnabled(v);
                    },
            ),
            if (activePin != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Row(
                  children: [
                    const Icon(Icons.pin, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      'PIN: $activePin',
                      key: const Key('receive-pin'),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        letterSpacing: 2,
                      ),
                    ),
                  ],
                ),
              ),
            if (canResume)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonalIcon(
                    key: const Key('receive-resume'),
                    onPressed: actions.resume,
                    icon: const Icon(Icons.play_arrow),
                    label: Text(
                      state is Failed
                          ? tr('receive.tryAgain')
                          : tr('receive.resume'),
                    ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(tr('receive.for'), style: theme.textTheme.labelLarge),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final mode in choices)
                    ChoiceChip(
                      key: Key('receive-choice-${_choiceKey(mode)}'),
                      label: Text(receiveChoiceLabel(mode)),
                      selected: mode == selected,
                      onSelected: (_) => actions.choose(mode),
                    ),
                ],
              ),
            ),
            if (capped)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  tr('receive.capNote'),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            if (showVisibility) ...[
              const Divider(),
              const _VisibilitySection(),
            ],
          ],
        ),
      ),
    );
  }

  static String _choiceKey(ReceiveMode m) => switch (m) {
    ReceiveAlways() => 'always',
    ReceiveOff() => 'off',
    ReceiveFor(:final duration) => '${duration.inMinutes}m',
  };
}

/// One line describing [state], e.g. "Visible to everyone until 18:20
/// (5 h 12 min left)".
String receiveStatusText(
  BuildContext context,
  ReceiveState state,
  DateTime now,
) {
  switch (state) {
    case On(:final until, :final visibility):
      final who = visibility == ReceiveVisibility.everyone
          ? tr('receive.whoEveryone')
          : tr('receive.whoContacts');
      if (until == null) return tr('receive.onAlways', {'who': who});
      final left = until.difference(now);
      final time = MaterialLocalizations.of(context)
          .formatTimeOfDay(TimeOfDay.fromDateTime(until));
      return tr('receive.onUntil', {
        'who': who,
        'time': time,
        'left': formatSpan(left.isNegative ? Duration.zero : left),
      });
    case Off(:final reason):
      return switch (reason) {
        OffReason.neverEnabled => tr('receive.offNever'),
        OffReason.user => tr('receive.offUser'),
        OffReason.expired => tr('receive.offExpired'),
      };
    case Starting():
      return tr('receive.starting');
    case Draining():
      return tr('receive.draining');
    case Paused(:final reason):
      return switch (reason) {
        PauseReason.platformTimeout => tr('receive.pausedTimeout'),
        PauseReason.osStopped => tr('receive.pausedStopped'),
        PauseReason.noNetwork => tr('receive.pausedNetwork'),
        PauseReason.permissionMissing => tr('receive.pausedPermission'),
        PauseReason.batteryLow => tr('receive.pausedBattery'),
      };
    case Failed():
      return tr('receive.failed');
  }
}

enum _Who { everyone, contacts, off }

class _VisibilitySection extends ConsumerWidget {
  const _VisibilitySection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(receiveStatusProvider);
    final settings = ref.watch(receiveSettingsProvider);
    final actions = ref.read(receiveActionsProvider);
    final receiving = state is On || state is Draining;
    final current = !receiving
        ? _Who.off
        : settings.visibility == ReceiveVisibility.contacts
        ? _Who.contacts
        : _Who.everyone;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr('receive.whoCanSee'), style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          SegmentedButton<_Who>(
            key: const Key('visibility-control'),
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: _Who.everyone,
                label: Text(tr('receive.everyone')),
              ),
              ButtonSegment(
                value: _Who.contacts,
                label: Text(tr('receive.contactsOnly')),
                enabled: false,
              ),
              ButtonSegment(value: _Who.off, label: Text(tr('receive.off'))),
            ],
            selected: {current},
            onSelectionChanged: (s) async {
              final pick = s.first;
              if (pick == _Who.off) {
                await actions.setEnabled(false);
              } else if (pick == _Who.everyone) {
                await actions.setVisibility(ReceiveVisibility.everyone);
                if (!receiving) await actions.setEnabled(true);
              }
            },
          ),
          const SizedBox(height: 4),
          Text(
            tr('receive.contactsSoon'),
            key: const Key('contacts-soon'),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
