import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const List<String> kDefaultNostrRelays = [
  'wss://relay.damus.io',
  'wss://nos.lol',
  'wss://relay.primal.net',
];

/// Card for managing public Nostr relay endpoints and disclosing metadata implications.
class RelaySettingsCard extends ConsumerStatefulWidget {
  const RelaySettingsCard({super.key});

  @override
  ConsumerState<RelaySettingsCard> createState() => _RelaySettingsCardState();
}

class _RelaySettingsCardState extends ConsumerState<RelaySettingsCard> {
  final TextEditingController _customCtrl = TextEditingController();
  List<String> _relays = List.from(kDefaultNostrRelays);

  @override
  void dispose() {
    _customCtrl.dispose();
    super.dispose();
  }

  void _addRelay() {
    final url = _customCtrl.text.trim();
    if (url.startsWith('wss://') || url.startsWith('ws://')) {
      setState(() {
        if (!_relays.contains(url)) {
          _relays.add(url);
          _customCtrl.clear();
        }
      });
    }
  }

  void _removeRelay(String url) {
    setState(() {
      _relays.remove(url);
    });
  }

  void _resetRelays() {
    setState(() {
      _relays = List.from(kDefaultNostrRelays);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      key: const Key('settings-relay-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.hub_outlined),
                const SizedBox(width: 8),
                Text(
                  'Nostr Relays',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                TextButton(
                  key: const Key('reset_relays_button'),
                  onPressed: _resetRelays,
                  child: const Text('Reset Defaults'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'DISCLOSURE: Public relays see network timing and IP addresses. Envelope contents and presence data are authenticated and end-to-end encrypted (AES-256-GCM).',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _relays.length,
              itemBuilder: (context, index) {
                final r = _relays[index];
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.cloud_queue, size: 18),
                  title: Text(r, style: const TextStyle(fontSize: 13)),
                  trailing: IconButton(
                    key: Key('remove_relay_$index'),
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => _removeRelay(r),
                  ),
                );
              },
            ),
            const Divider(),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('custom_relay_input'),
                    controller: _customCtrl,
                    decoration: const InputDecoration(
                      hintText: 'wss://my-relay.example.com',
                      labelText: 'Add Custom Relay',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  key: const Key('add_relay_button'),
                  onPressed: _addRelay,
                  child: const Text('Add'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
