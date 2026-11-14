import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

import '../providers/platform_providers.dart';
import '../providers/settings_provider.dart';
import '../providers/web_portal_provider.dart';
import '../services/format.dart';

class WebPortalScreen extends ConsumerStatefulWidget {
  const WebPortalScreen({super.key});

  @override
  ConsumerState<WebPortalScreen> createState() => _WebPortalScreenState();
}

class _WebPortalScreenState extends ConsumerState<WebPortalScreen> {
  final TextEditingController _pinController = TextEditingController();
  bool _requirePin = false;

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _pickAndAddFiles() async {
    final picker = ref.read(filePickerServiceProvider);
    final picked = await picker.pickFiles();
    if (picked.isEmpty) return;
    ref.read(webPortalProvider.notifier).addFiles(
          picked.map((p) => File(p.path)).toList(),
        );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(webPortalProvider);
    final notifier = ref.read(webPortalProvider.notifier);
    final downloadDir = ref.watch(downloadDirProvider);
    final launcher = ref.read(fileLauncherProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Web Portal (Browser Share)'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SwitchListTile(
                        key: const Key('web-portal-switch'),
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          'Web Share Portal',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Text(
                          state.isRunning
                              ? 'Active on local Wi-Fi'
                              : 'Disabled (zero-install browser sharing)',
                        ),
                        value: state.isRunning,
                        onChanged: (val) async {
                          if (val) {
                            await notifier.start(
                              pin: _requirePin && _pinController.text.isNotEmpty
                                  ? _pinController.text
                                  : null,
                            );
                          } else {
                            await notifier.stop();
                          }
                        },
                      ),
                      if (state.errorMessage != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          state.errorMessage!,
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (state.isRunning && state.portalUri != null) ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        Text(
                          'Scan with any phone or tablet',
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: SizedBox(
                            width: 200,
                            height: 200,
                            child: PrettyQrView.data(
                              data: state.portalUri.toString(),
                              decoration: const PrettyQrDecoration(
                                shape: PrettyQrSmoothSymbol(color: Colors.black),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        SelectableText(
                          state.portalUri.toString(),
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        FilledButton.tonalIcon(
                          icon: const Icon(Icons.copy, size: 18),
                          label: const Text('Copy URL'),
                          onPressed: () {
                            Clipboard.setData(
                              ClipboardData(text: state.portalUri.toString()),
                            );
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Web Portal URL copied to clipboard'),
                                duration: Duration(seconds: 2),
                              ),
                            );
                          },
                        ),
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.install_mobile, size: 28),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  'Web App (PWA) Ready: Browsers can tap "Install App" to use LibreShare as a full standalone app without app stores!',
                                  style: theme.textTheme.bodySmall,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ] else if (!state.isRunning) ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Security & Access',
                          style: theme.textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Require PIN for access'),
                          subtitle: const Text('Protects against unauthorized devices on the Wi-Fi'),
                          value: _requirePin,
                          onChanged: (val) {
                            setState(() {
                              _requirePin = val ?? false;
                            });
                          },
                        ),
                        if (_requirePin) ...[
                          const SizedBox(height: 8),
                          TextField(
                            controller: _pinController,
                            decoration: const InputDecoration(
                              labelText: '4-digit PIN',
                              hintText: 'e.g. 1234',
                              border: OutlineInputBorder(),
                            ),
                            keyboardType: TextInputType.number,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              'Files for Download (${state.sharedFiles.length})',
                              style: theme.textTheme.titleSmall,
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton.icon(
                            icon: const Icon(Icons.add, size: 18),
                            label: const Text('Add Files'),
                            onPressed: _pickAndAddFiles,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (state.sharedFiles.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: Text(
                            'No files shared yet. Add files so connected browsers can download them.',
                            style: TextStyle(fontStyle: FontStyle.italic),
                          ),
                        )
                      else
                        ListView.separated(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: state.sharedFiles.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final file = state.sharedFiles[index];
                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.insert_drive_file),
                              title: Text(file.name),
                              subtitle: Text(formatBytes(file.size)),
                              trailing: IconButton(
                                icon: const Icon(Icons.close, size: 20),
                                onPressed: () => notifier.removeFile(file.id),
                              ),
                            );
                          },
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Received Uploads (${state.receivedFiles.length})',
                            style: theme.textTheme.titleSmall,
                          ),
                          TextButton.icon(
                            icon: const Icon(Icons.folder_open, size: 18),
                            label: const Text('Open Folder'),
                            onPressed: () {
                              launcher.showInFolder(downloadDir.path);
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (state.receivedFiles.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: Text(
                            'No uploads received yet from browsers.',
                            style: TextStyle(fontStyle: FontStyle.italic),
                          ),
                        )
                      else
                        ListView.separated(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: state.receivedFiles.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final upload = state.receivedFiles[index];
                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.check_circle, color: Colors.green),
                              title: Text(upload.originalName),
                              subtitle: Text(formatBytes(upload.bytesWritten)),
                              trailing: IconButton(
                                icon: const Icon(Icons.open_in_new, size: 20),
                                onPressed: () {
                                  launcher.open(upload.savedPath);
                                },
                              ),
                            );
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
