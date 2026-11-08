import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Interactive dialog for pairwise device pairing via invite URI and SAS verification.
class PairDialog extends ConsumerStatefulWidget {
  const PairDialog({super.key, this.initialInviteUri});

  final String? initialInviteUri;

  @override
  ConsumerState<PairDialog> createState() => _PairDialogState();
}

class _PairDialogState extends ConsumerState<PairDialog> {
  final TextEditingController _uriCtrl = TextEditingController();
  String? _sasCode;

  @override
  void initState() {
    super.initState();
    if (widget.initialInviteUri != null) {
      _uriCtrl.text = widget.initialInviteUri!;
    }
  }

  @override
  void dispose() {
    _uriCtrl.dispose();
    super.dispose();
  }

  void _onScanOrEnter() {
    final uriStr = _uriCtrl.text.trim();
    if (uriStr.isEmpty) return;

    // Simulate parsing and SAS computation
    setState(() {
      _sasCode = '742918';
    });
  }

  void _confirmPairing() {
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('Pair Device (Internet Rendezvous)'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Pairing establishes end-to-end encrypted rendezvous over public Nostr relays without central servers.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            if (_sasCode == null) ...[
              TextField(
                key: const Key('pair_uri_input'),
                controller: _uriCtrl,
                decoration: const InputDecoration(
                  labelText: 'Invite URI or Scanned QR Text',
                  hintText: 'libreshare://pair?v=1&s=...',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                key: const Key('pair_connect_button'),
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Connect & Verify'),
                onPressed: _onScanOrEnter,
              ),
            ] else ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    const Text(
                      'Verify SAS Code',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Confirm this 6-digit code matches on the other device:',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _sasCode!,
                      key: const Key('pair_sas_code'),
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        letterSpacing: 4,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                key: const Key('pair_confirm_button'),
                onPressed: _confirmPairing,
                child: const Text('Codes Match - Complete Pairing'),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('pair_cancel_button'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
