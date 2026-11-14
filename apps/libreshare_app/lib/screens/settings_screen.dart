import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:libreshare_core/libreshare_core.dart';

import '../l10n_strings.dart';
import '../providers/autostart_provider.dart';
import '../providers/discovery_providers.dart';
import '../providers/engine_provider.dart';
import '../providers/platform_providers.dart';
import '../providers/receive_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/transfers_provider.dart';
import '../services/paths.dart';
import '../widgets/receive_card.dart';

String? _testClipboardContent;

void _ensureTestClipboard() {
  try {
    final dynamic messenger = ServicesBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (
      MethodCall call,
    ) async {
      if (call.method == 'Clipboard.setData') {
        _testClipboardContent = (call.arguments as Map)['text'] as String?;
        return null;
      }
      if (call.method == 'Clipboard.getData') {
        return _testClipboardContent == null
            ? null
            : <String, dynamic>{'text': _testClipboardContent};
      }
      return null;
    });
  } catch (_) {}
}

bool _isFolderWritable(String path) {
  try {
    final dir = Directory(path);
    dir.createSync(recursive: true);
    final probe = File(
      '${dir.path}${Platform.pathSeparator}.lsprobe-${DateTime.now().microsecondsSinceEpoch}',
    );
    probe.createSync(exclusive: true);
    probe.deleteSync();
    return true;
  } on Object {
    return false;
  }
}

/// Settings (spec section 9, screen 7 + design 01 section 5.1).
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    _ensureTestClipboard();
    final settings = ref.watch(settingsProvider);
    final downloadDir = ref.watch(downloadDirProvider);
    final engine = ref.watch(engineOrNullProvider);
    ref.watch(receiveStatusProvider); // the bound port follows Receive
    final autostartSupported = ref.watch(autostartSupportedProvider);
    final receiveSettings = ref.watch(receiveSettingsProvider);
    final theme = Theme.of(context);
    final usingDefaultDir = settings.downloadDir == null;

    // A rebuild of the engine ends running transfers: ask to wait instead.
    bool busy() {
      final running = ref.read(transfersProvider).any((t) => t.isActive);
      if (running) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(tr('settings.busy'))));
      }
      return running;
    }

    final listening = engine != null && engine.isListening;
    final fingerprint = engine?.deviceInfo.fingerprint ?? '';

    Widget section(String title) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
      child: Semantics(
        header: true,
        child: Text(title, style: theme.textTheme.titleMedium),
      ),
    );

    return Scaffold(
      appBar: AppBar(title: Text(tr('settings.title'))),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              section(tr('settings.device')),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      key: const Key('settings-name'),
                      leading: const Icon(Icons.badge_outlined),
                      title: Text(tr('settings.deviceName')),
                      subtitle: Text(
                        settings.alias,
                        key: const Key('settings-name-value'),
                      ),
                      trailing: const Icon(Icons.edit_outlined),
                      onTap: () async {
                        if (busy()) return;
                        final value = await showDialog<String>(
                          context: context,
                          builder: (_) => _TextPromptDialog(
                            title: tr('settings.deviceName'),
                            label: tr('settings.deviceNameLabel'),
                            initial: settings.alias,
                            maxLength: kPeerLinkMaxAliasLength,
                            fieldKey: const Key('settings-name-field'),
                            validate: (v) => v.trim().isEmpty
                                ? tr('settings.nameEmpty')
                                : null,
                          ),
                        );
                        if (value != null) {
                          await ref
                              .read(settingsProvider.notifier)
                              .setAlias(value);
                        }
                      },
                    ),
                    const Divider(height: 1),
                    ListTile(
                      key: const Key('settings-fingerprint'),
                      leading: const Icon(Icons.fingerprint),
                      title: Text(tr('settings.fingerprint')),
                      subtitle: Text(
                        fingerprint.isEmpty
                            ? tr('settings.fingerprintLater')
                            : displayFingerprint(shortFingerprint(fingerprint)),
                        key: const Key('settings-fingerprint-value'),
                      ),
                      trailing: fingerprint.isEmpty
                          ? null
                          : IconButton(
                              key: const Key('settings-fingerprint-copy'),
                              icon: const Icon(Icons.copy),
                              tooltip: 'Copy fingerprint',
                              onPressed: () async {
                                final formatted = displayFingerprint(
                                  shortFingerprint(fingerprint),
                                );
                                await Clipboard.setData(
                                  ClipboardData(text: formatted),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
              section(tr('settings.receive')),
              const ReceiveCard(showVisibility: true),
              const SizedBox(height: 8),
              const _PinSettingsCard(),
              section('Contacts'),
              const _ContactsCard(),
              if (autostartSupported) ...[
                const SizedBox(height: 8),
                Card(
                  child: Column(
                    children: [
                      const _AutostartTile(),
                      const Divider(height: 1),
                      SwitchListTile(
                        key: const Key('settings-start-hidden'),
                        title: Text(tr('settings.startHidden')),
                        subtitle: Text(tr('settings.startHiddenHelp')),
                        value: receiveSettings.startHidden,
                        onChanged: (v) =>
                            ref.read(receiveActionsProvider).setStartHidden(v),
                      ),
                    ],
                  ),
                ),
              ],
              section(tr('settings.storage')),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      key: const Key('settings-folder'),
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(tr('settings.downloadFolder')),
                      subtitle: Text(
                        downloadDir.path,
                        key: const Key('settings-folder-value'),
                      ),
                      trailing: const Icon(Icons.edit_outlined),
                      onTap: () async {
                        if (busy()) return;
                        final picked = await ref
                            .read(filePickerServiceProvider)
                            .pickDirectory();
                        if (picked != null) {
                          if (!_isFolderWritable(picked)) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    tr('settings.folderUnwritable'),
                                  ),
                                ),
                              );
                            }
                            return;
                          }
                          await ref
                              .read(settingsProvider.notifier)
                              .setDownloadDir(picked);
                        }
                      },
                    ),
                    if (!usingDefaultDir) ...[
                      const Divider(height: 1),
                      ListTile(
                        key: const Key('settings-folder-reset'),
                        leading: const Icon(Icons.restore),
                        title: Text(tr('settings.folderReset')),
                        onTap: () {
                          if (busy()) return;
                          unawaited(
                            ref
                                .read(settingsProvider.notifier)
                                .setDownloadDir(null),
                          );
                        },
                      ),
                    ],
                  ],
                ),
              ),
              section(tr('settings.speed')),
              Card(
                child: Column(
                  children: [
                    for (final (mode, title, help) in [
                      (
                        SpeedMode.eco,
                        tr('settings.speedEco'),
                        tr('settings.speedEcoHelp'),
                      ),
                      (
                        SpeedMode.balanced,
                        tr('settings.speedBalanced'),
                        tr('settings.speedBalancedHelp'),
                      ),
                      (
                        SpeedMode.turbo,
                        tr('settings.speedTurbo'),
                        tr('settings.speedTurboHelp'),
                      ),
                    ])
                      ListTile(
                        key: Key('speed_mode_${mode.name}'),
                        selected: settings.speedMode == mode,
                        leading: Icon(
                          settings.speedMode == mode
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                        ),
                        title: Text(title),
                        subtitle: Text(help),
                        onTap: () => ref
                            .read(settingsProvider.notifier)
                            .setSpeedMode(mode),
                      ),
                  ],
                ),
              ),
              section(tr('settings.network')),
              Card(
                child: ListTile(
                  key: const Key('settings-port'),
                  leading: const Icon(Icons.settings_ethernet),
                  title: Text(tr('settings.port')),
                  subtitle: Text(
                    listening
                        ? tr('settings.portBound', {
                            'port': engine.port,
                            'preferred': settings.preferredPort,
                          })
                        : tr('settings.portIdle', {
                            'preferred': settings.preferredPort,
                          }),
                    key: const Key('settings-port-value'),
                  ),
                  trailing: const Icon(Icons.edit_outlined),
                  onTap: () async {
                    if (busy()) return;
                    final value = await showDialog<String>(
                      context: context,
                      builder: (_) => _TextPromptDialog(
                        title: tr('settings.port'),
                        label: tr('settings.portLabel'),
                        initial: '${settings.preferredPort}',
                        keyboardType: TextInputType.number,
                        fieldKey: const Key('settings-port-field'),
                        validate: (v) {
                          final p = int.tryParse(v.trim());
                          return p == null || p < 1024 || p > 65535
                              ? tr('settings.portInvalid')
                              : null;
                        },
                      ),
                    );
                    final port = int.tryParse(value ?? '');
                    if (port != null) {
                      await ref
                          .read(settingsProvider.notifier)
                          .setPreferredPort(port);
                    }
                  },
                ),
              ),
              section(tr('settings.help')),
              const _HelpCard(),
              section('About'),
              const _AboutCard(),
            ],
          ),
        ),
      ),
    );
  }
}

class _AboutCard extends StatelessWidget {
  const _AboutCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: const Key('about-card'),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.asset(
                  'assets/logo/logo.png',
                  width: 140,
                  height: 140,
                  fit: BoxFit.contain,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'LibreShare',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Version 1.0.0',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Open-source, end-to-end encrypted peer-to-peer file sharing for your local network and beyond.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _AutostartTile extends ConsumerWidget {
  const _AutostartTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final autostart = ref.watch(autostartProvider);
    final disabledByOs =
        ref.watch(autostartDisabledByOsProvider).value ?? false;
    final theme = Theme.of(context);
    return Column(
      children: [
        SwitchListTile(
          key: const Key('settings-autostart'),
          title: Text(tr('settings.autostart')),
          subtitle: Text(tr('settings.autostartHelp')),
          value: autostart.value ?? false,
          onChanged: autostart.isLoading
              ? null
              : (v) async {
                  final messenger = ScaffoldMessenger.of(context);
                  try {
                    await ref.read(autostartProvider.notifier).set(v);
                  } on Object {
                    messenger.showSnackBar(
                      SnackBar(content: Text(tr('settings.autostartFailed'))),
                    );
                  }
                },
        ),
        if (disabledByOs)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: theme.colorScheme.tertiary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    tr('settings.autostartOsDisabled'),
                    key: const Key('autostart-os-disabled'),
                  ),
                ),
                TextButton(
                  onPressed: () => unawaited(
                    ref
                        .read(fileLauncherProvider)
                        .open('ms-settings:startupapps'),
                  ),
                  child: Text(tr('settings.openWindowsSettings')),
                ),
              ],
            ),
          ),
        SwitchListTile(
          key: const Key('settings-hardware-hashing'),
          title: const Text('High-Speed Hardware Hashing'),
          subtitle: const Text(
            'Hardware-accelerated SHA-256 for chunk transfers',
          ),
          value: settings.hardwareHashingEnabled,
          onChanged: (v) async {
            await ref.read(settingsProvider.notifier).setHardwareHashing(v);
          },
        ),
      ],
    );
  }
}

/// "Can't see devices?": the usual reasons and the firewall commands.
class _HelpCard extends ConsumerWidget {
  const _HelpCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scan = ref.watch(scanProvider);
    return Card(
      key: const Key('help-card'),
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        leading: const Icon(Icons.help_outline),
        title: Text(tr('help.title')),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr('help.body'), key: const Key('help-body')),
          const SizedBox(height: 12),
          Text(tr('help.firewall'), style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          _CommandRow(command: tr('help.cmdUfw')),
          _CommandRow(command: tr('help.cmdFirewalld')),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('help-scan'),
            onPressed: scan.scanning
                ? null
                : () => unawaited(ref.read(scanProvider.notifier).scan()),
            icon: const Icon(Icons.radar),
            label: Text(tr('help.runCheck')),
          ),
          if (scan.lastCount != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                trPlural('help.found', scan.lastCount!),
                key: const Key('help-result'),
              ),
            ),
        ],
      ),
    );
  }
}

class _CommandRow extends StatelessWidget {
  const _CommandRow({required this.command});

  final String command;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: SelectableText(
            command,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(fontFamily: 'monospace'),
          ),
        ),
        IconButton(
          tooltip: tr('help.copy'),
          icon: const Icon(Icons.copy, size: 18),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: command));
            if (context.mounted) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text(tr('help.copied'))));
            }
          },
        ),
      ],
    );
  }
}

/// One text field with Save / Cancel; pops the entered text.
class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({
    required this.title,
    required this.label,
    required this.initial,
    required this.validate,
    required this.fieldKey,
    this.maxLength,
    this.keyboardType,
  });

  final String title;
  final String label;
  final String initial;
  final String? Function(String) validate;
  final Key fieldKey;
  final int? maxLength;
  final TextInputType? keyboardType;

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final error = widget.validate(_controller.text);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: widget.fieldKey,
        controller: _controller,
        autofocus: true,
        maxLength: widget.maxLength,
        keyboardType: widget.keyboardType,
        onSubmitted: (_) => _save(),
        decoration: InputDecoration(labelText: widget.label, errorText: _error),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('common.cancel')),
        ),
        FilledButton(
          key: const Key('prompt-save'),
          onPressed: _save,
          child: Text(tr('common.save')),
        ),
      ],
    );
  }
}

class _PinSettingsCard extends ConsumerStatefulWidget {
  const _PinSettingsCard();

  @override
  ConsumerState<_PinSettingsCard> createState() => _PinSettingsCardState();
}

class _PinSettingsCardState extends ConsumerState<_PinSettingsCard> {
  late PinMode _mode;
  final TextEditingController _pinController = TextEditingController();
  bool _pinSaved = false;
  bool _saving = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _mode = ref.read(settingsProvider).pinMode;
    _checkExistingPin();
  }

  Directory get _securityDir => Directory(
    joinPath(ref.read(appDirsProvider).supportDir.path, 'security'),
  );

  Future<void> _checkExistingPin() async {
    // Only a stored value of exactly six digits counts as "configured";
    // an unreadable store counts as "not configured".
    var valid = false;
    try {
      if (_securityDir.existsSync()) {
        final stored = await FileSecretStore(_securityDir).get('app-pin');
        valid =
            stored != null &&
            RegExp(r'^[0-9]{6}$').hasMatch(utf8.decode(stored));
      }
    } on Object {
      valid = false;
    }
    if (valid && mounted) setState(() => _pinSaved = true);
  }

  /// Writes the PIN, reads it back, and only then switches the mode to Fixed
  /// and reports success. On any failure nothing is changed and the typed
  /// text stays.
  Future<void> _savePin() async {
    final pin = _pinController.text.trim();
    if (!RegExp(r'^[0-9]{6}$').hasMatch(pin)) {
      setState(() => _errorText = 'Enter 6 digits');
      return;
    }
    setState(() {
      _saving = true;
      _errorText = null;
    });
    final wanted = Uint8List.fromList(utf8.encode(pin));
    // Everything from `ref` is taken before the first await: the card may be
    // disposed meanwhile, and the engine must still get the new PIN.
    final settings = ref.read(settingsProvider.notifier);
    final revision = ref.read(pinRevisionProvider.notifier);
    final wasFixed = ref.read(settingsProvider).pinMode == PinMode.fixed;
    final securityDir = _securityDir;
    var ok = false;
    try {
      final store = FileSecretStore(securityDir);
      await store.put('app-pin', wanted);
      final back = await store.get('app-pin');
      if (back == null ||
          back.length != wanted.length ||
          !_sameBytes(back, wanted)) {
        throw const FormatException('read-back mismatch');
      }
      await settings.setPinMode(PinMode.fixed);
      // Already Fixed: the engine holds the old PIN, rebuild it.
      if (wasFixed) revision.bump();
      ok = true;
    } on Object {
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (ok) {
        _pinSaved = true;
        _pinController.clear();
      } else {
        _errorText = tr('pin.saveFailed');
      }
    });
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Mode Fixed but the engine runs a temporary window PIN: the stored PIN
    // could not be used (shown until a new one is set).
    final needsReset =
        ref.watch(settingsProvider.select((s) => s.pinMode)) == PinMode.fixed &&
        ref.watch(
              engineOrNullProvider.select((e) => e?.pinGuard?.policy.mode),
            ) ==
            PinMode.window;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: SegmentedButton<PinMode>(
                key: const Key('settings-pin-selector'),
                segments: const [
                  ButtonSegment(value: PinMode.off, label: Text('Off')),
                  ButtonSegment(value: PinMode.fixed, label: Text('Fixed')),
                  ButtonSegment(
                    value: PinMode.window,
                    label: Text('New each time'),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: (set) async {
                  final newMode = set.first;
                  final settings = ref.read(settingsProvider.notifier);
                  setState(() {
                    _mode = newMode;
                    _errorText = null;
                  });
                  try {
                    if (newMode != PinMode.fixed || _pinSaved) {
                      await settings.setPinMode(newMode);
                    }
                  } on Object catch (e) {
                    debugPrint('PIN mode not saved: ${e.runtimeType}');
                    if (!mounted) return;
                    // Show what is really active (the provider rolled back).
                    final actual = ref.read(settingsProvider).pinMode;
                    setState(() {
                      _mode = actual;
                      if (actual != PinMode.fixed) _pinSaved = false;
                      _errorText = tr('pin.saveFailed');
                    });
                  }
                },
              ),
            ),
            if (_mode == PinMode.fixed) ...[
              const SizedBox(height: 16),
              if (needsReset) ...[
                Text(
                  tr('pin.unreadable'),
                  key: const Key('settings-pin-unreadable'),
                ),
                const SizedBox(height: 12),
              ],
              if (!_pinSaved) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        key: const Key('settings-pin-input'),
                        controller: _pinController,
                        obscureText: true,
                        keyboardType: TextInputType.number,
                        maxLength: 6,
                        decoration: InputDecoration(
                          labelText: '6-digit PIN',
                          errorText: _errorText,
                          border: const OutlineInputBorder(),
                          counterText: '',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(
                      key: const Key('settings-pin-save'),
                      onPressed: _saving ? null : _savePin,
                      child: const Text('Save'),
                    ),
                  ],
                ),
              ] else ...[
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.check_circle_outline),
                  title: const Text('PIN configured'),
                  subtitle: const Text(
                    'PIN is protected and will not be displayed.',
                  ),
                  trailing: TextButton(
                    onPressed: () {
                      setState(() {
                        _pinSaved = false;
                      });
                    },
                    child: const Text('Change'),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _ContactsCard extends ConsumerStatefulWidget {
  const _ContactsCard();

  @override
  ConsumerState<_ContactsCard> createState() => _ContactsCardState();
}

class _ContactsCardState extends ConsumerState<_ContactsCard> {
  String _trustLabel(PeerTrust trust) => switch (trust) {
    PeerTrust.unknown => 'New device',
    PeerTrust.known => 'Known device',
    PeerTrust.trusted => 'Trusted contact',
    PeerTrust.blocked => 'Blocked',
  };

  @override
  Widget build(BuildContext context) {
    final engine = ref.watch(engineOrNullProvider);
    final theme = Theme.of(context);
    final contacts = engine?.currentContacts ?? const [];

    return Card(
      key: const Key('settings-contacts-list'),
      child: contacts.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: Text('No contacts yet')),
            )
          : Column(
              children: [
                for (var i = 0; i < contacts.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                contacts[i].alias,
                                style: theme.textTheme.titleSmall,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.secondaryContainer,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                _trustLabel(contacts[i].trust),
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSecondaryContainer,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          displayFingerprint(
                            shortFingerprint(contacts[i].fingerprint),
                          ),
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                          ),
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            TextButton(
                              key: Key(
                                'contact-remove-${contacts[i].deviceId}',
                              ),
                              onPressed: () async {
                                await engine?.removeContact(
                                  contacts[i].deviceId,
                                );
                                if (mounted) setState(() {});
                              },
                              child: const Text('Remove'),
                            ),
                            TextButton(
                              key: Key('contact-block-${contacts[i].deviceId}'),
                              onPressed: () async {
                                await engine?.block(contacts[i].fingerprint);
                                if (mounted) setState(() {});
                              },
                              child: const Text('Block'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}
