import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../platform/sleep_inhibitor.dart';
import '../services/format.dart';

/// Modal bottom sheet for configuring and hosting a public link share (Increment 5).
class CreateLinkSheet extends StatefulWidget {
  final List<String> fileNames;
  final int totalBytes;
  final SleepInhibitor? sleepInhibitor;
  final Future<String> Function(String mode, String expiry, bool hideIp)?
  linkFactory;

  const CreateLinkSheet({
    super.key,
    required this.fileNames,
    required this.totalBytes,
    this.sleepInhibitor,
    this.linkFactory,
  });

  @override
  State<CreateLinkSheet> createState() => _CreateLinkSheetState();
}

class _CreateLinkSheetState extends State<CreateLinkSheet> {
  late final SleepInhibitor _inhibitor;
  bool _consentAgreed = false;
  String _selectedExpiry = '1h';
  String _selectedReceivers = '1';
  bool _hideIp = false;
  bool _isLoading = false;
  String? _linkUrl;
  String? _errorMessage;
  int _remainingSeconds = 3600;
  Timer? _countdownTimer;

  final List<String> _receivers = ['Waiting for receiver...'];

  @override
  void initState() {
    super.initState();
    _inhibitor = widget.sleepInhibitor ?? createSleepInhibitor();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _inhibitor.release();
    super.dispose();
  }

  void _agreeConsent() {
    setState(() {
      _consentAgreed = true;
    });
  }

  Future<void> _startSharing() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await _inhibitor.acquire(reason: 'Active link share');

      final url = widget.linkFactory != null
          ? await widget.linkFactory!(
              _selectedReceivers,
              _selectedExpiry,
              _hideIp,
            )
          : 'https://libreshare.github.io/r#v=1&h=active-link.example.com';

      if (!mounted) return;

      int durationSecs = 3600;
      if (_selectedExpiry == '15m') durationSecs = 900;
      if (_selectedExpiry == '24h') durationSecs = 86400;

      setState(() {
        _isLoading = false;
        _linkUrl = url;
        _remainingSeconds = durationSecs;
      });

      _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        setState(() {
          if (_remainingSeconds > 0) {
            _remainingSeconds--;
          } else {
            timer.cancel();
          }
        });
      });
    } catch (e) {
      if (!mounted) return;
      await _inhibitor.release();
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString();
      });
    }
  }

  Future<void> _stopSharing() async {
    _countdownTimer?.cancel();
    await _inhibitor.release();
    if (mounted) {
      Navigator.of(context).maybePop();
    }
  }

  String _formatCountdown(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) {
      return '${h}h ${m}m ${s}s remaining';
    }
    return '${m}m ${s}s remaining';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      key: const Key('create_link_sheet'),
      padding: const EdgeInsets.all(24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.link, size: 28),
                const SizedBox(width: 12),
                Text('Share via Link', style: theme.textTheme.headlineSmall),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${widget.fileNames.length} file(s) • ${formatBytes(widget.totalBytes)}',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            if (!_consentAgreed) ...[
              Card(
                key: const Key('consent_card'),
                color: theme.colorScheme.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.info_outline,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Provider & Privacy Notice',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Cloudflare Quick Tunnel: For testing and development. No uptime guarantee. '
                        'The provider sees connection IP addresses, transfer sizes and timing, '
                        'but never file contents (end-to-end encrypted with AES-256-GCM).',
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton(
                          key: const Key('consent_agree_button'),
                          onPressed: _agreeConsent,
                          child: const Text('I Understand & Agree'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ] else if (_linkUrl == null) ...[
              // Configuration View
              Text('Expires After', style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                key: const Key('expiry_selector'),
                segments: const [
                  ButtonSegment(value: '15m', label: Text('15 min')),
                  ButtonSegment(value: '1h', label: Text('1 hour')),
                  ButtonSegment(value: '24h', label: Text('24 hours')),
                ],
                selected: {_selectedExpiry},
                onSelectionChanged: (set) =>
                    setState(() => _selectedExpiry = set.first),
              ),
              const SizedBox(height: 16),
              Text('Allowed Receivers', style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                key: const Key('receivers_selector'),
                segments: const [
                  ButtonSegment(value: '1', label: Text('1 (One-Time)')),
                  ButtonSegment(value: '5', label: Text('Up to 5')),
                  ButtonSegment(value: 'anyone', label: Text('Anyone')),
                ],
                selected: {_selectedReceivers},
                onSelectionChanged: (set) =>
                    setState(() => _selectedReceivers = set.first),
              ),
              const SizedBox(height: 16),
              SwitchListTile(
                key: const Key('hide_ip_toggle'),
                title: const Text('Hide My IP Address'),
                subtitle: const Text(
                  'Direct connections show your IP address to whoever opens the link.',
                ),
                value: _hideIp,
                onChanged: (val) => setState(() => _hideIp = val),
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: 12),
                Text(
                  _errorMessage!,
                  key: const Key('error_text'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
              const SizedBox(height: 20),
              FilledButton(
                key: const Key('create_link_button'),
                onPressed: _isLoading ? null : _startSharing,
                child: _isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Create Link'),
              ),
            ] else ...[
              // Active Share View
              Card(
                color: theme.colorScheme.primaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      SelectableText(
                        _linkUrl!,
                        key: const Key('link_display_text'),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      ElevatedButton.icon(
                        key: const Key('copy_link_button'),
                        icon: const Icon(Icons.copy),
                        label: const Text('Copy Link'),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: _linkUrl!));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Link copied to clipboard'),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.timer_outlined, size: 18),
                  const SizedBox(width: 6),
                  Text(
                    _formatCountdown(_remainingSeconds),
                    key: const Key('expiry_countdown_text'),
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Keep LibreShare open and this device awake until downloads finish.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
              const Divider(height: 32),
              Text('Receivers', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              for (var i = 0; i < _receivers.length; i++)
                ListTile(
                  key: Key('receiver_row_$i'),
                  leading: const Icon(Icons.person_outline),
                  title: Text(_receivers[i]),
                ),
              const SizedBox(height: 20),
              OutlinedButton.icon(
                key: const Key('stop_sharing_button'),
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('Stop Sharing'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                ),
                onPressed: _stopSharing,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
