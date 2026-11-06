import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:libreshare_core/libreshare_core.dart';

import '../l10n_strings.dart';
import '../providers/engine_provider.dart';
import '../providers/platform_providers.dart';
import '../widgets/device_card.dart';
import '../widgets/platform_icon.dart';

/// A validated `ip[:port]` entry.
class AddressInput {
  const AddressInput(this.ip, this.port);

  final String ip;
  final int port;

  @override
  String toString() => hostPort(ip, port);
}

/// Parses "192.168.1.5", "192.168.1.5:53320", "[fe80::1]:53318" or a bare IPv6
/// literal. Returns the string-table key of the problem in the second slot.
(AddressInput?, String?) parseAddress(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return (null, 'add.errorEmpty');
  String ip = text;
  String? portText;
  if (text.startsWith('[')) {
    final close = text.indexOf(']');
    if (close < 0) return (null, 'add.errorIp');
    ip = text.substring(1, close);
    final rest = text.substring(close + 1);
    if (rest.isNotEmpty) {
      if (!rest.startsWith(':')) return (null, 'add.errorIp');
      portText = rest.substring(1);
    }
  } else if (':'.allMatches(text).length == 1) {
    final i = text.indexOf(':');
    ip = text.substring(0, i);
    portText = text.substring(i + 1);
  }
  var port = kDefaultPort;
  if (portText != null) {
    final p = int.tryParse(portText);
    if (p == null || p < 1 || p > 65535) return (null, 'add.errorPort');
    port = p;
  }
  if (InternetAddress.tryParse(ip) == null) return (null, 'add.errorIp');
  try {
    PeerLink(ip: ip, port: port);
  } on FormatException {
    return (null, 'add.errorIpUnusable');
  }
  return (AddressInput(ip, port), null);
}

/// Add device (spec section 9, screen 8): by IP[:port] with a confirmation
/// dialog, or from a pasted / scanned `libreshare://peer` link.
class AddDeviceScreen extends ConsumerStatefulWidget {
  const AddDeviceScreen({super.key});

  @override
  ConsumerState<AddDeviceScreen> createState() => _AddDeviceScreenState();
}

class _AddDeviceScreenState extends ConsumerState<AddDeviceScreen> {
  final _address = TextEditingController();
  final _link = TextEditingController();
  String? _addressError;
  String? _linkError;
  bool _busy = false;

  @override
  void dispose() {
    _address.dispose();
    _link.dispose();
    super.dispose();
  }

  LibreShareEngine? get _engine => ref.read(engineOrNullProvider);

  Future<void> _lookup() async {
    final (input, error) = parseAddress(_address.text);
    if (input == null) {
      setState(() => _addressError = tr(error!));
      return;
    }
    final engine = _engine;
    if (engine == null) return;
    setState(() {
      _addressError = null;
      _busy = true;
    });
    ResolvedPeer? peer;
    try {
      peer = await engine.resolvePeer(input.ip, input.port);
    } on PeerUnreachable {
      _addressError = tr('add.unreachable', {'address': input.toString()});
    } on FormatException {
      _addressError = tr('add.errorIp');
    } on Object {
      _addressError = tr('add.failed');
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (peer == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => ConfirmPeerDialog(peer: peer!),
    );
    if (confirmed != true || !mounted) return;
    try {
      final device = engine.addResolvedPeer(peer);
      _done(device.info.alias);
    } on ArgumentError {
      setState(() => _addressError = tr('add.thisDevice'));
    } on Object {
      setState(() => _addressError = tr('add.failed'));
    }
  }

  Future<void> _addLink(String raw) async {
    final link = PeerLink.tryParse(raw);
    if (link == null) {
      setState(() => _linkError = tr('add.badLink'));
      return;
    }
    final engine = _engine;
    if (engine == null) return;
    setState(() {
      _linkError = null;
      _busy = true;
    });
    DiscoveredDevice? device;
    String? error;
    try {
      device = await engine.addPeerLink(link);
    } on PeerUnreachable {
      error = tr('add.unreachable', {'address': hostPort(link.ip, link.port)});
    } on FingerprintMismatch {
      error = tr('add.fingerprintMismatch');
    } on DeviceIdMismatch {
      error = tr('add.idMismatch');
    } on ArgumentError {
      error = tr('add.thisDevice');
    } on Object {
      error = tr('add.failed');
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _linkError = error;
    });
    if (device != null) _done(device.info.alias);
  }

  void _done(String alias) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(tr('add.added', {'alias': alias}))));
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/');
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || !mounted) return;
    setState(() {
      _link.text = text.trim();
      _linkError = null;
    });
  }

  Future<void> _scan() async {
    final raw = await context.push<String>('/scan');
    if (raw == null || !mounted) return;
    _link.text = raw;
    await _addLink(raw);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canScan = ref.watch(qrScanSupportedProvider);
    return Scaffold(
      appBar: AppBar(title: Text(tr('add.title'))),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (_busy) const LinearProgressIndicator(key: Key('add-busy')),
              Semantics(
                header: true,
                child: Text(
                  tr('add.byAddress'),
                  style: theme.textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: 4),
              Text(tr('add.byAddressHelp'), style: theme.textTheme.bodyMedium),
              const SizedBox(height: 12),
              TextField(
                key: const Key('add-address'),
                controller: _address,
                enabled: !_busy,
                keyboardType: TextInputType.url,
                autocorrect: false,
                textInputAction: TextInputAction.go,
                onSubmitted: (_) => _lookup(),
                decoration: InputDecoration(
                  labelText: tr('add.addressLabel'),
                  hintText: tr('add.addressHint'),
                  errorText: _addressError,
                  errorMaxLines: 3,
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  key: const Key('add-lookup'),
                  onPressed: _busy ? null : _lookup,
                  icon: const Icon(Icons.search),
                  label: Text(tr('add.lookup')),
                ),
              ),
              const SizedBox(height: 32),
              Semantics(
                header: true,
                child: Text(
                  tr('add.byLink'),
                  style: theme.textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                canScan ? tr('add.byLinkHelpScan') : tr('add.byLinkHelp'),
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('add-link'),
                controller: _link,
                enabled: !_busy,
                minLines: 1,
                maxLines: 3,
                autocorrect: false,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: tr('add.linkLabel'),
                  hintText: tr('add.linkHint'),
                  errorText: _linkError,
                  errorMaxLines: 3,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    key: const Key('add-paste'),
                    onPressed: _busy ? null : _paste,
                    icon: const Icon(Icons.content_paste),
                    label: Text(tr('add.paste')),
                  ),
                  if (canScan)
                    OutlinedButton.icon(
                      key: const Key('add-scan'),
                      onPressed: _busy ? null : _scan,
                      icon: const Icon(Icons.qr_code_scanner),
                      label: Text(tr('add.scan')),
                    ),
                  FilledButton.icon(
                    key: const Key('add-link-submit'),
                    onPressed: _busy ? null : () => _addLink(_link.text),
                    icon: const Icon(Icons.add_link),
                    label: Text(tr('add.addLink')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Is this the device you meant?": name, platform, address and, once there is
/// TLS (Increment 3), the fingerprint to compare out of band.
class ConfirmPeerDialog extends StatelessWidget {
  const ConfirmPeerDialog({super.key, required this.peer});

  final ResolvedPeer peer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final info = peer.info;
    final fingerprint = peer.fingerprintToConfirm;
    return AlertDialog(
      key: const Key('confirm-peer-dialog'),
      scrollable: true,
      title: Text(tr('confirm.title')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(platformIcon(info.platform, info.deviceType)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  info.alias,
                  key: const Key('confirm-alias'),
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${platformLabel(info.platform)}  ·  ${hostPort(peer.address, peer.port)}',
            key: const Key('confirm-address'),
          ),
          const SizedBox(height: 16),
          Text(tr('confirm.fingerprint'), style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          if (fingerprint != null) ...[
            SelectableText(
              displayFingerprint(fingerprint),
              key: const Key('confirm-fingerprint'),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 8),
            Text(tr('confirm.compare'), style: theme.textTheme.bodySmall),
          ] else ...[
            Text(
              tr('confirm.fingerprintLater'),
              key: const Key('confirm-fingerprint-later'),
            ),
            const SizedBox(height: 8),
            Text(tr('confirm.onlyKnown'), style: theme.textTheme.bodySmall),
          ],
        ],
      ),
      actions: [
        TextButton(
          key: const Key('confirm-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(tr('common.cancel')),
        ),
        FilledButton(
          key: const Key('confirm-add'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(tr('confirm.add')),
        ),
      ],
    );
  }
}
