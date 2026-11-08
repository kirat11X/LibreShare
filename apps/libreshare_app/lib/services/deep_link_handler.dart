import 'package:libreshare_core/libreshare_core.dart';

/// Handles parsing and dispatching of incoming deep links (Increment 5).
///
/// Supports both canonical HTTPS landing links (`https://libreshare.github.io/r#...`)
/// and application URL scheme deep links (`libreshare://r?...`).
class DeepLinkHandler {
  /// Parses [uri] into a validated [ShareLink], or null if invalid or unrecognized scheme.
  static ShareLink? parse(Uri uri, {bool allowDeveloperHosts = false}) {
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'libreshare' && scheme != 'https') {
      return null;
    }

    try {
      return ShareLink.parse(
        uri.toString(),
        allowDeveloperHosts: allowDeveloperHosts,
      );
    } catch (_) {
      return null;
    }
  }
}
