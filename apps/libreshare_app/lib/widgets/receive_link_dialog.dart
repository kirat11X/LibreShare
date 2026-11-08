import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libreshare_core/libreshare_core.dart';

import '../services/deep_link_handler.dart';

/// Dialog allowing a user to paste and download files from a share link (Increment 5).
class ReceiveLinkDialog extends StatefulWidget {
  final String? initialLink;
  final Future<void> Function(ShareLink link)? onDownload;

  const ReceiveLinkDialog({super.key, this.initialLink, this.onDownload});

  @override
  State<ReceiveLinkDialog> createState() => _ReceiveLinkDialogState();
}

class _ReceiveLinkDialogState extends State<ReceiveLinkDialog> {
  late final TextEditingController _controller;
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialLink ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && mounted) {
      setState(() {
        _controller.text = data!.text!.trim();
        _errorMessage = null;
      });
    }
  }

  Future<void> _startDownload() async {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      setState(() {
        _errorMessage = 'Please enter or paste a share link';
      });
      return;
    }

    final uri = Uri.tryParse(text);
    if (uri == null) {
      setState(() {
        _errorMessage = 'Invalid link URL format';
      });
      return;
    }

    final link = DeepLinkHandler.parse(uri, allowDeveloperHosts: true);
    if (link == null) {
      setState(() {
        _errorMessage = 'Invalid or unsupported LibreShare link';
      });
      return;
    }

    if (link.isExpired(DateTime.now())) {
      setState(() {
        _errorMessage = 'This share link has expired';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      if (widget.onDownload != null) {
        await widget.onDownload!(link);
      }
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        Navigator.of(context).maybePop(true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      key: const Key('receive_link_dialog'),
      title: const Row(
        children: [
          Icon(Icons.download_for_offline_outlined),
          SizedBox(width: 8),
          Text('Receive from Link'),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Enter or paste a LibreShare download link to retrieve files over the internet.',
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('link_input_field'),
              controller: _controller,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: 'Share Link URL',
                hintText: 'https://.../r#v=1&h=...',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  key: const Key('paste_link_button'),
                  tooltip: 'Paste from clipboard',
                  icon: const Icon(Icons.paste),
                  onPressed: _pasteFromClipboard,
                ),
              ),
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                key: const Key('receive_error_text'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
            if (_isLoading) ...[
              const SizedBox(height: 16),
              const Center(
                child: CircularProgressIndicator(
                  key: Key('receive_progress_indicator'),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading
              ? null
              : () => Navigator.of(context).maybePop(false),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          key: const Key('download_link_button'),
          onPressed: _isLoading ? null : _startDownload,
          icon: const Icon(Icons.download),
          label: const Text('Download'),
        ),
      ],
    );
  }
}
