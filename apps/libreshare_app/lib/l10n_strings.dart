/// Every user-visible English string of the app lives in this one table (the
/// i18n scaffold): widgets call [tr] / [trPlural] with a key, never a
/// literal. To translate, add another table and select it in [setLocaleStrings].
///
/// * `{name}` marks a placeholder filled from the `args` map.
/// * A plural family `key` is stored as `key.zero` (optional), `key.one` and
///   `key.other`; [trPlural] picks one by the count and also fills `{n}`.
library;

const Map<String, String> kStringsEn = {
  // App
  'app.title': 'LibreShare',
  'common.back': 'Back',
  'common.cancel': 'Cancel',
  'common.done': 'Done',
  'common.retry': 'Try again',
  'common.save': 'Save',
  'shell.starting': 'Starting LibreShare',
  'shell.failed': 'LibreShare could not start. Check that its data folder is writable and try again.',
  'shell.failedIdentity': "This device's security key is missing or damaged. To start fresh, clear the app's data; other devices will then warn that your key changed.",
  'failure.pinInvalid': 'That PIN was not accepted.',
  'failure.pinBlocked':
      'This device is not accepting PINs right now. Try again later.',
  'pin.enter6': 'Enter 6 digits',
  'pin.submit': 'Send',
  'pin.saveFailed': 'Could not save the PIN. Nothing was changed.',
  'pin.unreadable': 'Your saved PIN could not be read. A temporary PIN is shown on the Receive card until you set a new one.',
  'nav.nearby': 'Nearby',
  'nav.settings': 'Settings',

  // Home
  'home.title': 'Nearby',
  'home.scan': 'Scan network',
  'home.addDevice': 'Add device',
  'home.myQr': 'My QR code',
  'home.sendFiles': 'Send files',
  'home.nearby': 'Nearby devices',
  'home.transfers': 'Transfers',
  'empty.title': 'No devices found yet',
  'empty.iconLabel': 'Searching for devices',
  'empty.body': 'Make sure the other device has LibreShare open with Receive turned on, and that both devices are on the same network.',
  'empty.isolation': 'Some guest, hotel and campus Wi-Fi networks use AP / client isolation, which stops devices from seeing each other. If that is the case here, add the device by IP address or QR code, or use a phone hotspot.',
  'empty.addByIp': 'Add by IP or QR',

  // Device cards
  'device.semantics': '{alias}, {platform}, {address}, seen {seen}',
  'device.sendHint': 'Send files to this device',
  'source.multicast': 'Announced on the network',
  'source.mdns': 'Found with mDNS',
  'source.scan': 'Found by network scan',
  'source.manual': 'Added manually',
  'source.qr': 'Added from a link or QR code',
  'source.register': 'Introduced itself',
  'source.ble': 'Found nearby via Bluetooth',
  'platform.linux': 'Linux',
  'platform.windows': 'Windows',
  'platform.android': 'Android',
  'platform.macos': 'macOS',
  'platform.ios': 'iOS',
  'platform.unknown': 'Unknown system',

  // Receive
  'receive.title': 'Receive',
  'receive.for': 'Receive for',
  'receive.always': 'Always',
  'receive.minutes': '{n} min',
  'receive.hours': '{n} h',
  'receive.off': 'Off',
  'receive.everyone': 'Everyone',
  'receive.contactsOnly': 'Contacts only',
  'receive.whoEveryone': 'everyone',
  'receive.whoContacts': 'your contacts',
  'receive.onAlways': 'Visible to {who} until you turn it off',
  'receive.onUntil': 'Visible to {who} until {time} ({left} left)',
  'receive.offNever': 'Not receiving. Turn on Receive so other devices can find you and send you files.',
  'receive.offUser': 'Not receiving',
  'receive.offExpired': 'Receiving ended. Other devices can no longer see you.',
  'receive.starting': 'Starting…',
  'receive.draining': 'Finishing the current transfers, then stopping',
  'receive.pausedTimeout': 'Paused by the system. Tap Resume to receive again.',
  'receive.pausedStopped': 'Receiving was stopped by the system. Tap Resume.',
  'receive.pausedNetwork':
      'Waiting for Wi-Fi. Receiving resumes when you reconnect.',
  'receive.pausedPermission': 'Paused: a permission is needed.',
  'receive.pausedBattery': 'Paused: the battery is low.',
  'receive.failed': 'Could not start receiving. Another program may be using ports 53318 to 53327.',
  'receive.resume': 'Resume',
  'receive.tryAgain': 'Try again',
  'receive.capNote': 'Android limits how long LibreShare can keep receiving in the background.',
  'receive.whoCanSee': 'Who can see this device',
  'receive.contactsSoon':
      'Contacts only is coming in a later update (it needs device pairing).',

  // Tray tooltips
  'tray.receiving': 'LibreShare: receiving',
  'tray.receivingAlways': 'LibreShare: receiving until turned off',
  'tray.finishing': 'LibreShare: finishing transfers',
  'tray.paused': 'LibreShare: receiving paused',
  'tray.starting': 'LibreShare: starting',
  'tray.failed': 'LibreShare: could not start receiving',
  'tray.off': 'LibreShare: not receiving',

  // Send flow
  'send.title': 'Send files',
  'send.filesSelected.one': '{n} file selected ({size})',
  'send.filesSelected.other': '{n} files selected ({size})',
  'send.addMore': 'Add more',
  'send.remove': 'Remove {name}',
  'send.chooseDevice': 'Choose a device',
  'send.noFiles': 'Select at least one file to send.',
  'send.noDevices': 'No devices found yet. Make sure the other device has Receive turned on, or add it by IP address or QR code.',

  // Transfers
  'transfer.title': 'Transfer',
  'transfer.titleSend': 'Sending to {peer}',
  'transfer.titleReceive': 'Receiving from {peer}',
  'transfer.preparing': 'Preparing files…',
  'transfer.waitingFor': 'Waiting for {peer} to accept…',
  'transfer.awaitingYou': '{peer} wants to send you files. Accept or reject.',
  'transfer.sendingTo': 'Sending to {peer}, {pct}%',
  'transfer.receivingFrom': 'Receiving from {peer}, {pct}%',
  'transfer.sentCount.one': 'Sent {n} file to {peer}',
  'transfer.sentCount.other': 'Sent {n} files to {peer}',
  'transfer.receivedCount.one': 'Received {n} file from {peer}',
  'transfer.receivedCount.other': 'Received {n} files from {peer}',
  'transfer.cancelled': 'Transfer cancelled',
  'transfer.rejected': '{peer} declined the transfer',
  'transfer.rejectedByYou': 'You declined the files from {peer}',
  'transfer.failed': 'Transfer failed',
  'transfer.cancel': 'Cancel',
  'transfer.dismiss': 'Dismiss',
  'transfer.unknown': 'This transfer is no longer available.',
  'transfer.fileCount.one': '{n} file, {size}',
  'transfer.fileCount.other': '{n} files, {size}',
  'transfer.fileSemantics': '{name}, {pct} percent',
  'transfer.overallSemantics': 'Overall progress, {pct} percent',
  'transfer.open': 'Open',
  'transfer.showInFolder': 'Show in folder',
  'transfer.savedIn': 'Saved in {where}',
  'transfer.cantOpen': 'Could not open it here. The file is saved at {path}',
  'failure.rejected': '{peer} declined the files.',
  'failure.rejectedByYou': 'You declined the files from {peer}.',
  'failure.timeout': 'There was no answer in time. Try again.',
  'failure.cancelled': 'The transfer was cancelled.',
  'failure.verifyFailed':
      'A file arrived damaged and was discarded. Try sending it again.',
  'failure.noConnection': 'Could not reach {peer}. Check that you are on the same network and that Receive is on.',
  'failure.lost': 'The connection to {peer} was lost. Keep both apps open and on the same Wi-Fi, then try again.',
  'failure.diskFull': 'There is not enough free space on the receiving device.',
  'failure.storageUnusable': 'The download folder on the receiving device is not usable or unwritable.',
  'settings.folderUnwritable': 'The selected folder cannot be written to. Please choose another location.',
  'failure.protocol': 'Something went wrong during the transfer.',
  'failure.localFile':
      'A selected file could not be read. It may have been moved or deleted.',

  // Incoming prompt
  'incoming.title': 'Incoming transfer',
  'incoming.wantsToSend.one': 'wants to send you {n} file ({size})',
  'incoming.wantsToSend.other': 'wants to send you {n} files ({size})',
  'incoming.more': 'and {n} more',
  'incoming.accept': 'Accept',
  'incoming.reject': 'Reject',
  'incoming.countdown': 'Declines automatically in {time}',
  'incoming.countdownSemantics': 'Declines automatically in {time}',
  'sas.placeholder': 'Verification code: available after security setup (a later update). Only accept files from people you know.',

  // Add device
  'add.title': 'Add device',
  'add.byAddress': 'By IP address',
  'add.byAddressHelp': 'Enter the address shown on the other device, for example 192.168.1.20 or 192.168.1.20:53318.',
  'add.addressLabel': 'IP address (and port)',
  'add.addressHint': '192.168.1.20:53318',
  'add.lookup': 'Look up',
  'add.errorEmpty': 'Enter an IP address.',
  'add.errorIp': 'That does not look like a valid IP address.',
  'add.errorIpUnusable': 'That address cannot belong to a device. Use the IP address of the other device.',
  'add.errorPort': 'The port must be a number from 1 to 65535.',
  'add.unreachable': 'No LibreShare device answered at {address}. Check the address and that Receive is on.',
  'add.failed': 'Could not add the device. Try again.',
  'add.thisDevice': 'That is this device.',
  'add.byLink': 'By link or QR code',
  'add.byLinkHelp':
      'Paste the libreshare://peer link that the other device shows.',
  'add.byLinkHelpScan': 'Scan the QR code on the other device, or paste its libreshare://peer link.',
  'add.linkLabel': 'Device link',
  'add.linkHint': 'libreshare://peer?ip=…',
  'add.paste': 'Paste',
  'add.scan': 'Scan QR code',
  'add.addLink': 'Add from link',
  'add.badLink': 'That is not a valid LibreShare device link.',
  'add.fingerprintMismatch':
      'The device at that address does not match the link. Do not continue.',
  'add.idMismatch': 'A different device answered at that address.',
  'add.added': 'Added {alias}',
  'confirm.title': 'Add this device?',
  'confirm.fingerprint': 'Fingerprint',
  'confirm.fingerprintLater':
      'Available after security setup (a later update).',
  'confirm.onlyKnown': 'Only add devices you recognise.',
  'confirm.compare':
      'Check that this matches the fingerprint shown on the other device.',
  'confirm.add': 'Add',

  // My QR / scan
  'qr.title': 'My QR code',
  'qr.help':
      'Show this to the other device and scan it, or share the link below.',
  'qr.semantics': 'QR code to add {alias} at {address}',
  'qr.copy': 'Copy link',
  'qr.copied': 'Link copied',
  'qr.unavailable': 'No QR code yet',
  'qr.unavailableHelp': 'Your device can only be reached while Receive is on. Turn it on to get a code.',
  'qr.turnOnReceive': 'Turn on Receive',
  'scan.title': 'Scan QR code',
  'scan.hint': 'Point the camera at the QR code on the other device.',
  'scan.unsupported': 'Scanning needs a camera, which is not available here. Paste the link instead.',

  // Settings
  'settings.title': 'Settings',
  'settings.device': 'This device',
  'settings.deviceName': 'Device name',
  'settings.deviceNameLabel': 'Name other devices see',
  'settings.nameEmpty': 'Enter a name.',
  'settings.fingerprint': 'Your fingerprint',
  'settings.fingerprintLater':
      'Available after security setup (a later update)',
  'settings.receive': 'Receive',
  'settings.autostart': 'Start LibreShare when I sign in',
  'settings.autostartHelp': 'Runs in the background so you can receive files without opening the app.',
  'settings.autostartFailed': 'Could not change this setting.',
  'settings.autostartOsDisabled': 'Disabled in Windows Startup settings.',
  'settings.openWindowsSettings': 'Open Windows settings',
  'settings.startHidden': 'Start minimized',
  'settings.startHiddenHelp':
      'When started automatically, keep the window hidden.',
  'settings.storage': 'Storage',
  'storage.title': 'Where should received files go?',
  'storage.body': 'Received files are saved in {path}. On Android that folder is private to LibreShare, so other apps may not find the files. You can choose a folder such as Downloads instead.',
  'storage.choose': 'Choose a folder',
  'storage.keep': 'Keep default',
  'settings.downloadFolder': 'Download folder',
  'settings.folderReset': 'Use the default folder',
  'settings.network': 'Network',
  'settings.port': 'Port',
  'settings.portBound': 'Listening on port {port} (preferred: {preferred})',
  'settings.portIdle':
      'Not listening because Receive is off. Preferred port: {preferred}',
  'settings.portLabel': 'Preferred port',
  'settings.portInvalid': 'Enter a port from 1024 to 65535.',
  'settings.busy': 'Finish the current transfers first. This change restarts the connection.',
  'settings.speed': 'Transfer speed',
  'settings.speedEco': 'Eco',
  'settings.speedBalanced': 'Balanced',
  'settings.speedTurbo': 'Turbo',
  'settings.speedEcoHelp':
      'One chunk at a time. Gentlest on battery and old computers.',
  'settings.speedBalancedHelp': 'Three chunks at a time. The default.',
  'settings.speedTurboHelp':
      'Eight chunks at a time. Fastest on SSDs and fast links.',
  'settings.help': 'Help',
  'help.title': "Can't see devices?",
  'help.body': 'Both devices need to be on the same network, and the other one needs Receive turned on. Guest, hotel and campus Wi-Fi often isolates devices; in that case add the device by IP address or QR code, or use a phone hotspot. A firewall can also block LibreShare: on Linux, run one of the commands below once.',
  'help.firewall': 'Firewall commands (Linux)',
  'help.cmdUfw': 'sudo ufw allow 53318:53327/tcp && sudo ufw allow 53318/udp',
  'help.cmdFirewalld': 'sudo firewall-cmd --permanent --add-port=53318-53327/tcp --add-port=53318/udp && sudo firewall-cmd --reload',
  'help.runCheck': 'Scan the network now',
  'help.found.zero': 'No devices found. See the tips above.',
  'help.found.one': '{n} device found.',
  'help.found.other': '{n} devices found.',
  'help.copy': 'Copy command',
  'help.copied': 'Command copied',

  // Units and times
  'unit.b': 'B',
  'unit.kb': 'KB',
  'unit.mb': 'MB',
  'unit.gb': 'GB',
  'unit.tb': 'TB',
  'speed.perSecond': '{size}/s',
  'eta.seconds': '{n} s left',
  'eta.minutes': '{n} min left',
  'eta.hours': '{h} h {m} min left',
  'span.seconds': '{n} s',
  'span.minutes': '{n} min',
  'span.hours': '{h} h {m} min',
  'span.hoursOnly': '{h} h',
  'ago.now': 'just now',
  'ago.seconds': '{n} s ago',
  'ago.minutes': '{n} min ago',
  'ago.hours': '{n} h ago',
};

Map<String, String> _active = kStringsEn;

/// Switches the table [tr] reads (a translation, or [kStringsEn] again).
void setLocaleStrings(Map<String, String> strings) => _active = strings;

String _fill(String template, Map<String, Object?> args) {
  if (args.isEmpty || !template.contains('{')) return template;
  return template.replaceAllMapped(RegExp(r'\{(\w+)\}'), (m) {
    final v = args[m.group(1)];
    return v == null ? m.group(0)! : '$v';
  });
}

/// The text for [key] with `{placeholders}` filled from [args]. An unknown
/// key returns the key itself (and fails an assert in debug builds).
String tr(String key, [Map<String, Object?> args = const {}]) {
  final template = _active[key] ?? kStringsEn[key];
  assert(template != null, 'missing string: $key');
  return _fill(template ?? key, args);
}

/// Plural form of [key] for [count]; `{n}` is the count.
String trPlural(String key, int count, [Map<String, Object?> args = const {}]) {
  final form =
      count == 0 &&
          (_active.containsKey('$key.zero') ||
              kStringsEn.containsKey('$key.zero'))
      ? 'zero'
      : (count == 1 ? 'one' : 'other');
  return tr('$key.$form', {'n': count, ...args});
}
