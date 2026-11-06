import 'package:flutter/material.dart';

import '../l10n_strings.dart';

/// Icon for a peer's `platform` / `deviceType` as reported on the wire.
IconData platformIcon(String platform, [String deviceType = 'desktop']) {
  switch (platform.toLowerCase()) {
    case 'android':
    case 'ios':
      return deviceType == 'tablet' ? Icons.tablet_android : Icons.smartphone;
    case 'linux':
    case 'windows':
    case 'macos':
      return Icons.laptop;
    default:
      return deviceType == 'mobile' ? Icons.smartphone : Icons.devices_other;
  }
}

/// "Linux", "Windows", ... for display.
String platformLabel(String platform) => switch (platform.toLowerCase()) {
  'linux' => tr('platform.linux'),
  'windows' => tr('platform.windows'),
  'android' => tr('platform.android'),
  'macos' => tr('platform.macos'),
  'ios' => tr('platform.ios'),
  _ => tr('platform.unknown'),
};
