/// Headless LibreShare CLI: info | devices | receive | send | peer-link |
/// identity | contacts | pair.
///
/// The CLI defaults to the secure profile (TLS 1.3, persistent identity in
/// `--identity-dir`); `--insecure-plaintext` selects the Increment 1/2 wire.
///
/// Exit codes: 0 ok, 1 failed, 64 usage, 66 no input, 80 key changed,
/// 81 insecure peer, 82 PIN/auth/blocked/bad pairing secret, 83 SAS aborted,
/// 84 identity lost.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:logging/logging.dart';
import 'package:libreshare_core/libreshare_core.dart';
import 'package:uuid/uuid.dart';

const int exitKeyChanged = 80;
const int exitInsecurePeer = 81;
const int exitAuthRefused = 82;
const int exitSasAborted = 83;
const int exitIdentityLost = 84;

const _usage = '''
LibreShare CLI

Usage: ls <command> [options]

Commands:
  info       Show a peer's DeviceInfo (or this device's)  ls info [--to host:port]
  devices    List devices around, via multicast/mDNS       ls devices [--timeout 5] [--json] [--scan] [--listen]
  receive    Listen for incoming transfers                 ls receive --dir DIR [--port N] [--auto-accept] [--once]
                                                           [--for 30m | --always] [--visibility everyone|contacts]
                                                           [--pin PIN|auto] [--insecure-tofu] [--no-discovery]
  send       Send files to a peer                          ls send (--to host:port | --device NAME|ID|LINK) FILE...
                                                           [--pin PIN] [--insecure-tofu] [--allow-insecure]
  peer-link  Print this device's libreshare://peer link,   ls peer-link [LINK] [--port N] [--ip ADDR]
             or resolve and check one you were given
  identity   Show or rotate this device's identity         ls identity show|rotate
  contacts   Pinned devices                                ls contacts list|add|remove|block|unblock
                                                           add --id UUID --fp 64HEX [--alias A] [--trust known|trusted]
  pair       Pair two devices by invite (QR text)          ls pair --show | --scan URI

Options of every command that talks to a peer:
  --secure (default) | --insecure-plaintext   TLS with a pinned identity, or the plain Increment 1/2 wire
  --identity-dir DIR      identity, contacts and keys (default: \$LS_HOME or the user config directory)
  --advertise-ip ADDR     the address other devices are told (behind NAT / in a container)
''';

/// What `runCli` needs from its surroundings. Everything is optional; the
/// defaults are the real terminal, the real network and real signals. Tests
/// pass their own to run several commands in one process.
class CliHooks {
  const CliHooks({
    this.out,
    this.err,
    this.discovery,
    this.bindAddress,
    this.stop,
    this.handleSignals = true,
  });

  /// One line of normal output (default: stdout).
  final void Function(String line)? out;

  /// One line of diagnostics (default: stderr).
  final void Function(String line)? err;

  /// Replaces the discovery setup of the commands that use discovery
  /// (`devices`, `receive`, `send --device`). `receive --no-discovery` wins.
  final DiscoveryConfig? discovery;

  /// Pins the listener (and the address this device reports) to one address.
  final InternetAddress? bindAddress;

  /// Completing it ends a long-running command (`receive`, `devices --listen`)
  /// the way Ctrl-C does.
  final Future<void>? stop;

  /// Watch SIGINT/SIGTERM (default). Off for in-process use.
  final bool handleSignals;
}

class _Io {
  _Io(CliHooks h) {
    out = h.out ?? _stdoutLine;
    err = h.err ?? _stderrLine;
    if (h.out == null) {
      // A closed pipe (`ls info | true`) is not an error of ours.
      stdout.done.then<void>((_) {}, onError: (Object _) => _broken = true);
    }
  }

  late final void Function(String) out;
  late final void Function(String) err;
  bool _broken = false;

  void _stdoutLine(String s) {
    if (_broken) return;
    try {
      stdout.writeln(s);
    } on Object {
      _broken = true;
    }
  }

  void _stderrLine(String s) {
    try {
      stderr.writeln(s);
    } on Object {
      // nobody is reading
    }
  }
}

/// Lines typed on the terminal, read asynchronously (a blocking read would
/// stop the engine from serving). One reader per command; EOF answers null.
class _Lines {
  StreamSubscription<String>? _sub;
  final Queue<String> _queue = Queue<String>();
  final Queue<Completer<String?>> _waiters = Queue<Completer<String?>>();
  bool _eof = false;

  Future<String?> next() {
    if (_queue.isNotEmpty) return Future.value(_queue.removeFirst());
    if (_eof) return Future.value(null);
    _sub ??= stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (l) {
            if (_waiters.isNotEmpty) {
              _waiters.removeFirst().complete(l);
            } else {
              _queue.add(l);
            }
          },
          onDone: () {
            _eof = true;
            while (_waiters.isNotEmpty) {
              _waiters.removeFirst().complete(null);
            }
          },
          onError: (Object _) {
            _eof = true;
            while (_waiters.isNotEmpty) {
              _waiters.removeFirst().complete(null);
            }
          },
        );
    final c = Completer<String?>();
    _waiters.add(c);
    return c.future;
  }

  /// y / yes; anything else, and EOF, is no.
  Future<bool> confirm(String question) async {
    stdout.write(question);
    final a = (await next())?.trim().toLowerCase();
    // A terminal echoes the user's Enter; a pipe does not, and the next line
    // of output must start on a line of its own.
    if (!stdin.hasTerminal) stdout.writeln();
    return a == 'y' || a == 'yes';
  }

  Future<void> close() async {
    await _sub?.cancel();
    _sub = null;
  }
}

/// Text from the network made safe for one terminal line.
String _clean(String s) {
  final b = StringBuffer();
  for (final c in s.runes) {
    b.writeCharCode(c < 0x20 || c == 0x7f ? 0x3f : c);
  }
  final t = b.toString();
  return t.length > 64 ? t.substring(0, 64) : t;
}

String _sasText(String code) =>
    code.length == 6 ? '${code.substring(0, 3)} ${code.substring(3)}' : code;

/// Where identity, contacts and keys live when `--identity-dir` is not given.
Directory _defaultIdentityDir() {
  final env = Platform.environment;
  final home = env['LS_HOME'];
  if (home != null && home.isNotEmpty) return Directory(home);
  final sep = Platform.pathSeparator;
  if (Platform.isWindows) {
    final app = env['APPDATA'] ?? env['USERPROFILE'] ?? '.';
    return Directory('$app${sep}LibreShare');
  }
  final xdg = env['XDG_CONFIG_HOME'];
  if (xdg != null && xdg.isNotEmpty) return Directory('$xdg${sep}libreshare');
  final h = env['HOME'] ?? '.';
  return Directory('$h$sep.config${sep}libreshare');
}

/// What the profile options of a command resolved to.
class _Setup {
  _Setup(this.wiring, this.advertiseIp);
  final SecurityWiring? wiring;
  final String? advertiseIp;

  bool get secure => wiring != null;

  Future<void> close() async => wiring?.close();
}

void _addProfileOptions(ArgParser p) {
  p
    ..addFlag(
      'secure',
      negatable: false,
      help: 'TLS 1.3 with a pinned identity (the default)',
    )
    ..addFlag(
      'insecure-plaintext',
      negatable: false,
      help: 'plain HTTP, no identity: the Increment 1/2 wire (loopback, tests)',
    )
    ..addOption('identity-dir', help: 'identity, contacts and keys')
    ..addOption('advertise-ip', help: 'the address other devices are told');
}

/// Resolves `--secure|--insecure-plaintext`, `--advertise-ip` and the identity
/// directory. A usage error or a lost identity is printed and returned as the
/// exit code.
Future<({_Setup? setup, int code})> _setup(
  ArgResults r,
  _Io io, {
  PinPolicy pinPolicy = const PinPolicy.off(),
  String? pin,
  bool allowInsecure = false,
  bool autoAcceptTrusted = false,
}) async {
  if (r['secure'] == true && r['insecure-plaintext'] == true) {
    io.err('--secure and --insecure-plaintext exclude each other');
    return (setup: null, code: 64);
  }
  final adv = r['advertise-ip'] as String?;
  if (adv != null && InternetAddress.tryParse(adv) == null) {
    io.err('invalid --advertise-ip');
    return (setup: null, code: 64);
  }
  if (r['insecure-plaintext'] == true) {
    return (setup: _Setup(null, adv), code: 0);
  }
  final dirArg = r['identity-dir'] as String?;
  try {
    final wiring = await SecurityWiring.open(
      directory: dirArg == null ? _defaultIdentityDir() : Directory(dirArg),
      pinPolicy: pinPolicy,
      pin: pin,
      allowInsecurePeers: allowInsecure,
      consent: ConsentPolicy(autoAcceptTrusted: autoAcceptTrusted),
    );
    return (setup: _Setup(wiring, adv), code: 0);
  } on IdentityLostException catch (e) {
    io.err(
      'identity lost (${e.reason.name}): the key or its metadata is missing '
      'or damaged; it is never regenerated automatically',
    );
    return (setup: null, code: exitIdentityLost);
  } on FileSystemException catch (e) {
    io.err('cannot use the identity directory: ${e.message}');
    return (setup: null, code: 1);
  }
}

int _exitForRefusal(LsErrorCode? c) => switch (c) {
  LsErrorCode.keyChanged => exitKeyChanged,
  LsErrorCode.pinRequired ||
  LsErrorCode.pinInvalid ||
  LsErrorCode.blocked ||
  LsErrorCode.authInvalid => exitAuthRefused,
  _ => 1,
};

/// The exit code a thrown security exception stands for, or null.
int? _exitForException(Object e) {
  if (e is PeerFingerprintMismatchException) return exitKeyChanged;
  if (e is InsecurePeerException) return exitInsecurePeer;
  if (e is SasAbortedException) return exitSasAborted;
  if (e is IdentityLostException) return exitIdentityLost;
  if (e is LsException) {
    final c = _exitForRefusal(e.code);
    return c == 1 ? null : c;
  }
  return null;
}

/// Ctrl-C / SIGTERM / `CliHooks.stop`, as one future.
class _Interrupt {
  _Interrupt(CliHooks h) {
    if (h.handleSignals) {
      _subs.add(ProcessSignal.sigint.watch().listen((_) => trigger()));
      if (!Platform.isWindows) {
        _subs.add(ProcessSignal.sigterm.watch().listen((_) => trigger()));
      }
    }
    final stop = h.stop;
    if (stop != null) unawaited(stop.then((_) => trigger()));
  }

  final Completer<void> _fired = Completer<void>();
  final List<StreamSubscription<ProcessSignal>> _subs = [];

  Future<void> get fired => _fired.future;
  bool get isFired => _fired.isCompleted;

  void trigger() {
    if (!_fired.isCompleted) _fired.complete();
  }

  Future<void> close() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
  }
}

DeviceInfo _selfFrom(ArgResults r, int port, [_Setup? setup]) => DeviceInfo(
  deviceId: setup?.wiring?.identity.identity.deviceId ?? const Uuid().v4(),
  alias: (r['alias'] as String?) ?? Platform.localHostname,
  platform: Platform.operatingSystem,
  port: port,
);

(String, int)? _parseHostPort(String? s) {
  if (s == null) return null;
  final i = s.lastIndexOf(':');
  if (i <= 0) return null;
  final port = int.tryParse(s.substring(i + 1));
  if (port == null || port < 1 || port > 65535) return null;
  return (s.substring(0, i), port);
}

/// `30m`, `2h`, `90s`, `1h30m`; a bare number is minutes. Null if unusable or
/// zero.
Duration? _parseWindow(String s) {
  final text = s.trim().toLowerCase();
  final bare = int.tryParse(text);
  if (bare != null) return bare > 0 ? Duration(minutes: bare) : null;
  final m = RegExp(r'^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$').firstMatch(text);
  if (m == null) return null;
  final d = Duration(
    hours: int.tryParse(m.group(1) ?? '') ?? 0,
    minutes: int.tryParse(m.group(2) ?? '') ?? 0,
    seconds: int.tryParse(m.group(3) ?? '') ?? 0,
  );
  return d > Duration.zero ? d : null;
}

/// Seconds, possibly fractional, as a Duration; null if negative or unusable.
Duration? _parseSeconds(String? s) {
  if (s == null) return null;
  final v = double.tryParse(s);
  if (v == null || v.isNaN || v < 0 || v > 86400) return null;
  return Duration(microseconds: (v * 1e6).round());
}

String _hostPort(String host, int port) =>
    host.contains(':') ? '[$host]:$port' : '$host:$port';

String _deviceLine(DiscoveredDevice d) =>
    '${d.id} ${d.info.alias} (${d.info.platform}) '
    '${_hostPort(d.address, d.info.port)} via=${d.source.name}';

Map<String, Object?> _deviceJson(DiscoveredDevice d) => {
  'id': d.id,
  'alias': d.info.alias,
  'platform': d.info.platform,
  'deviceType': d.info.deviceType,
  'address': d.address,
  'port': d.info.port,
  'addrs': [for (final a in d.info.addrs) a.toJson()],
  'fingerprint': d.info.fingerprint,
  'version': d.info.version,
  'source': d.source.name,
  'lastSeen': d.lastSeen.toUtc().toIso8601String(),
};

Future<int> runCli(
  List<String> args, {
  CliHooks hooks = const CliHooks(),
}) async {
  final io = _Io(hooks);
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false)
    ..addFlag(
      'verbose',
      abbr: 'v',
      negatable: false,
      help: 'log protocol activity to stderr',
    );
  _addProfileOptions(
    parser.addCommand('info')
      ..addOption('to', help: 'host:port of the peer (default: this device)')
      ..addOption('alias'),
  );
  _addProfileOptions(
    parser.addCommand('devices')
      ..addOption(
        'timeout',
        help:
            'seconds to look around (default 5; with --listen: until '
            'interrupted)',
      )
      ..addFlag('json', negatable: false, help: 'machine-readable output')
      ..addFlag('scan', negatable: false, help: 'also scan the local /24')
      ..addFlag(
        'listen',
        negatable: false,
        help: 'keep running and print devices as they appear and go',
      )
      ..addOption('alias'),
  );
  final receiveParser = parser.addCommand('receive')
    ..addOption(
      'dir',
      help: 'download directory',
      defaultsTo: 'libreshare-downloads',
    )
    ..addOption('port', defaultsTo: '$kDefaultPort', help: '0 = ephemeral')
    ..addOption('alias')
    ..addFlag(
      'auto-accept',
      negatable: false,
      help: 'accept every session without asking',
    )
    ..addFlag(
      'once',
      negatable: false,
      help: 'exit after the first session finishes',
    )
    ..addOption(
      'for',
      help:
          'receive for a while, then stop (30m, 2h, 90s, 1h30m; a bare '
          'number is minutes)',
    )
    ..addFlag(
      'always',
      negatable: false,
      help: 'receive until interrupted (the default)',
    )
    ..addOption(
      'visibility',
      allowed: ['everyone', 'contacts'],
      defaultsTo: 'everyone',
      help: 'who may see this device (contacts: only paired devices)',
    )
    ..addOption('pin', help: '6-digit PIN senders must give, or auto')
    ..addFlag(
      'insecure-tofu',
      negatable: false,
      help: 'do not ask the user to compare SAS codes (still printed)',
    )
    ..addFlag(
      'no-discovery',
      negatable: false,
      help: 'do not announce this device or answer discovery',
    )
    ..addFlag('no-rate-limit', negatable: false, hide: true);
  _addProfileOptions(receiveParser);
  final sendParser = parser.addCommand('send')
    ..addOption('to', help: 'host:port of the receiver')
    ..addOption(
      'device',
      help:
          'a device from `ls devices`: alias, id (or its first characters) or '
          'a libreshare://peer link',
    )
    ..addOption('alias')
    ..addOption('pin')
    ..addOption('concurrency', defaultsTo: '3')
    ..addOption(
      'timeout',
      defaultsTo: '120',
      help: 'seconds to wait for the receiver to accept',
    )
    ..addOption(
      'find-timeout',
      defaultsTo: '5',
      help: 'with --device: seconds to look for the device',
    )
    ..addFlag(
      'scan',
      negatable: false,
      help: 'with --device: also scan the local /24',
    )
    ..addFlag(
      'insecure-tofu',
      negatable: false,
      help: 'do not ask whether the SAS codes match (still printed)',
    )
    ..addFlag(
      'allow-insecure',
      negatable: false,
      help: 'also send to a peer without TLS (no fingerprint)',
    )
    ..addOption(
      'candidate',
      help: 'candidate tier or endpoint to prioritize (e.g. wifi, lan, loopback, or host:port)',
    )
    ..addFlag(
      'fallback',
      defaultsTo: true,
      help: 'fallback to next candidate on degradation (use --no-fallback to disable)',
    );
  _addProfileOptions(sendParser);
  _addProfileOptions(
    parser.addCommand('peer-link')
      ..addOption('port', defaultsTo: '$kDefaultPort')
      ..addOption('ip', help: 'use this local address')
      ..addOption('alias'),
  );
  parser.addCommand('identity').addOption('identity-dir');
  parser.addCommand('contacts')
    ..addOption('identity-dir')
    ..addOption('id')
    ..addOption('fp')
    ..addOption('alias')
    ..addOption('trust', allowed: ['known', 'trusted'], defaultsTo: 'known');
  _addProfileOptions(
    parser.addCommand('pair')
      ..addFlag('show', negatable: false, help: 'show an invite and wait')
      ..addOption('scan', help: 'redeem the invite URI of another device')
      ..addOption('port', defaultsTo: '0')
      ..addOption('alias'),
  );

  final ArgResults top;
  try {
    top = parser.parse(args);
  } on FormatException catch (e) {
    io.err(e.message);
    io.err(_usage);
    return 64;
  }
  if (top['verbose'] == true) {
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(
      (r) => stderr.writeln(
        '[${r.loggerName}] ${r.level.name}: ${r.message}${r.error == null ? '' : ' error=${r.error}'}',
      ),
    );
  }
  final cmd = top.command;
  if (top['help'] == true || cmd == null) {
    io.out(_usage);
    return cmd == null && top['help'] != true ? 64 : 0;
  }
  switch (cmd.name) {
    case 'info':
      return _info(cmd, io, hooks);
    case 'devices':
      return _devices(cmd, io, hooks);
    case 'receive':
      return _receive(cmd, io, hooks);
    case 'send':
      return _send(cmd, io, hooks);
    case 'peer-link':
      return _peerLink(cmd, io, hooks);
    case 'identity':
      return _identity(cmd, io);
    case 'contacts':
      return _contacts(cmd, io);
    case 'pair':
      return _pair(cmd, io, hooks);
  }
  return 64;
}

String _deviceLineFor(bool secure, DiscoveredDevice d) =>
    secure && d.info.fingerprint.isEmpty
    ? '${_deviceLine(d)} legacy=1'
    : _deviceLine(d);

// ------------------------------------------------------------------- info

Future<int> _info(ArgResults r, _Io io, CliHooks h) async {
  final toArg = r['to'] as String?;
  if (toArg == null) return _localInfo(r, io, h);
  final to = _parseHostPort(toArg);
  if (to == null) {
    io.err('info: --to host:port is required');
    return 64;
  }
  final su = await _setup(r, io);
  final setup = su.setup;
  if (setup == null) return su.code;
  final engine = LibreShareEngine(
    self: _selfFrom(r, 0, setup),
    downloadDir: Directory.systemTemp,
    security: setup.wiring,
    advertiseIp: setup.advertiseIp,
  );
  try {
    final d = await engine.peerInfo(to.$1, to.$2);
    io.out(
      '${_clean(d.alias)} (${_clean(d.platform)}) id=${d.deviceId} port=${d.port} v=${d.version}',
    );
    return 0;
  } on Object catch (e) {
    io.err('info failed: ${_describe(e)}');
    return _exitForException(e) ?? 1;
  } finally {
    await engine.dispose();
    await setup.close();
  }
}

/// A fixed, key-free description of an error for a user.
String _describe(Object e) => switch (e) {
  PeerFingerprintMismatchException() =>
    'the device presented a different key than the pinned one',
  InsecurePeerException() => 'the device does not offer the secure profile',
  SasAbortedException() => 'the comparison of the codes was not completed',
  LsException(:final code) => 'refused (${code.wire})',
  _ => '${e.runtimeType}',
};

/// `ls info` without `--to`: who this device is and where it can be reached.
/// Nothing is bound or announced.
Future<int> _localInfo(ArgResults r, _Io io, CliHooks h) async {
  final su = await _setup(r, io);
  final setup = su.setup;
  if (setup == null) return su.code;
  final engine = LibreShareEngine(
    self: _selfFrom(r, 0, setup),
    downloadDir: Directory.systemTemp,
    bindAddress: h.bindAddress,
    receiveConfig: const ReceiveConfig(initialMode: ReceiveOff()),
    security: setup.wiring,
    advertiseIp: setup.advertiseIp,
  );
  try {
    await engine.start();
    final d = engine.deviceInfo;
    io.out(
      '${d.alias} (${d.platform}) id=${d.deviceId} port=${d.port} v=${d.version}',
    );
    for (final a in d.addrs) {
      io.out('ADDR ${a.ip} ${a.iface}');
    }
    return 0;
  } on Object catch (e) {
    io.err('info failed: ${_describe(e)}');
    return 1;
  } finally {
    await engine.dispose();
    await setup.close();
  }
}

// ---------------------------------------------------------------- devices

DiscoveryConfig _lookingAround(CliHooks h) =>
    h.discovery ?? const DiscoveryConfig(autoScan: false);

Future<int> _devices(ArgResults r, _Io io, CliHooks h) async {
  final json = r['json'] as bool;
  final listen = r['listen'] as bool;
  final scan = r['scan'] as bool;
  final timeoutArg = r['timeout'] as String?;
  Duration? timeout = _parseSeconds(timeoutArg);
  if (timeoutArg != null && timeout == null) {
    io.err('devices: invalid --timeout');
    return 64;
  }
  if (!listen) timeout ??= const Duration(seconds: 5);

  final su = await _setup(r, io);
  final setup = su.setup;
  if (setup == null) return su.code;

  // A send-only node: Receive stays Off, so it announces as a probe, hears
  // every receiver's answer and never shows up in anyone's list.
  final engine = LibreShareEngine(
    self: _selfFrom(r, 0, setup),
    downloadDir: Directory.systemTemp,
    bindAddress: h.bindAddress,
    discovery: _lookingAround(h),
    receiveConfig: const ReceiveConfig(initialMode: ReceiveOff()),
    security: setup.wiring,
    advertiseIp: setup.advertiseIp,
  );
  final interrupt = _Interrupt(h);
  final known = <String, DiscoveredDevice>{};
  StreamSubscription<List<DiscoveredDevice>>? sub;
  try {
    await engine.start();
    if (listen) {
      void emit(String event, DiscoveredDevice d) {
        io.out(
          json
              ? jsonEncode({'event': event, 'device': _deviceJson(d)})
              : '${event.toUpperCase()} ${event == 'lost' ? '${d.id} ${d.info.alias}' : _deviceLineFor(setup.secure, d)}',
        );
      }

      sub = engine.devices.listen((list) {
        final now = {for (final d in list) d.id: d};
        for (final d in list) {
          if (!known.containsKey(d.id)) emit('found', d);
        }
        for (final gone in known.values.toList()) {
          if (!now.containsKey(gone.id)) emit('lost', gone);
        }
        known
          ..clear()
          ..addAll(now);
      });
    }
    if (scan) unawaited(engine.scanNetwork().then((_) {}, onError: (_) {}));

    final end = timeout == null
        ? interrupt.fired
        : Future.any<void>([Future<void>.delayed(timeout), interrupt.fired]);
    await end;

    if (!listen) {
      final list = engine.currentDevices;
      if (json) {
        io.out(jsonEncode([for (final d in list) _deviceJson(d)]));
      } else {
        for (final d in list) {
          io.out('DEVICE ${_deviceLineFor(setup.secure, d)}');
        }
        io.out('DEVICES ${list.length}');
      }
    }
    return 0;
  } on Object catch (e) {
    io.err('devices failed: $e');
    return 1;
  } finally {
    await sub?.cancel();
    await interrupt.close();
    await engine.dispose();
    await setup.close();
  }
}

// ---------------------------------------------------------------- receive

Future<int> _receive(ArgResults r, _Io io, CliHooks h) async {
  final port = int.tryParse(r['port'] as String);
  if (port == null || port < 0 || port > 65535) {
    io.err('receive: invalid --port');
    return 64;
  }
  final forArg = r['for'] as String?;
  if (forArg != null && r['always'] as bool) {
    io.err('receive: --for and --always exclude each other');
    return 64;
  }
  ReceiveMode mode = const ReceiveAlways();
  if (forArg != null) {
    final window = _parseWindow(forArg);
    if (window == null) {
      io.err('receive: invalid --for (examples: 30m, 2h, 90s, 1h30m)');
      return 64;
    }
    mode = ReceiveFor(window);
  }
  final plaintext = r['insecure-plaintext'] == true;
  final contactsOnly = r['visibility'] == 'contacts';
  if (contactsOnly && plaintext) {
    io.err(
      'receive: --visibility contacts needs the secure profile (contacts are '
      'made by pairing, which needs an identity)',
    );
    return 64;
  }
  final pinArg = r['pin'] as String?;
  var pinPolicy = const PinPolicy.off();
  String? fixedPin;
  if (pinArg != null) {
    if (plaintext) {
      io.err('receive: --pin needs the secure profile');
      return 64;
    }
    if (pinArg == 'auto') {
      pinPolicy = const PinPolicy(mode: PinMode.window);
    } else if (RegExp(r'^[0-9]{6}$').hasMatch(pinArg)) {
      pinPolicy = const PinPolicy(mode: PinMode.fixed);
      fixedPin = pinArg;
    } else {
      io.err('receive: --pin takes six digits or auto');
      return 64;
    }
  }

  final su = await _setup(r, io, pinPolicy: pinPolicy, pin: fixedPin);
  final setup = su.setup;
  if (setup == null) return su.code;

  final autoAccept = r['auto-accept'] as bool;
  final tofu = r['insecure-tofu'] as bool;
  final once = r['once'] as bool;
  final lines = _Lines();
  final engine = LibreShareEngine(
    self: _selfFrom(r, port, setup),
    downloadDir: Directory(r['dir'] as String),
    preferredPort: port,
    autoAccept: autoAccept,
    bindAddress: h.bindAddress,
    enableRateLimit: !(r['no-rate-limit'] as bool),
    discovery: (r['no-discovery'] as bool)
        ? DiscoveryConfig.disabled
        : _lookingAround(h),
    receiveConfig: ReceiveConfig(initialMode: mode),
    security: setup.wiring,
    advertiseIp: setup.advertiseIp,
  );

  final done = Completer<int>();
  var failed = false;
  var lingerForPeer = false;
  final sub = engine.events.listen((e) {
    switch (e) {
      case SessionCreated(:final sessionId, :final outgoing) when !outgoing:
        io.out('SESSION $sessionId');
        // A session with a SAS is asked about once the code is known.
        final sasSession = engine.incomingInfo(sessionId)?.sasRequired ?? false;
        if (!autoAccept && !sasSession) {
          unawaited(_prompt(engine, sessionId, io, lines));
        }
      case SasReady(:final sessionId, :final code, :final outgoing)
          when !outgoing:
        unawaited(
          _incomingSas(
            engine,
            sessionId,
            code,
            io,
            lines,
            skipAsk: autoAccept && tofu,
          ),
        );
      case FileSaved(:final path):
        io.out('RECEIVED $path');
      case SessionFinished(:final success, :final reason):
        io.out(success ? 'COMPLETED' : 'FAILED ${reason ?? ''}'.trim());
        failed = failed || !success;
        if (once && !done.isCompleted) {
          lingerForPeer = !success;
          done.complete(failed ? 1 : 0);
        }
      case _:
        break;
    }
  });
  final stateSub = engine.receive.states.listen((s) {
    // The window is over (and, if a transfer was running, it has finished).
    if (s is Off && s.reason == OffReason.expired) {
      io.out('EXPIRED');
      if (!done.isCompleted) done.complete(failed ? 1 : 0);
    }
  });
  final warnSub = engine.receive.events.listen((e) {
    if (e is ExpiringSoon) {
      io.out('EXPIRING in ${e.remaining.inMinutes} min');
    }
  });
  final interrupt = _Interrupt(h);
  unawaited(
    interrupt.fired.then((_) {
      if (!done.isCompleted) done.complete(failed ? 1 : 0);
    }),
  );

  Future<void> cleanup() async {
    await interrupt.close();
    await warnSub.cancel();
    await stateSub.cancel();
    await sub.cancel();
    await lines.close();
    await engine.dispose();
    await setup.close();
  }

  final int bound;
  try {
    if (contactsOnly) {
      await engine.receive.setVisibility(ReceiveVisibility.contacts);
    }
    bound = await engine.start();
  } on Object catch (e) {
    io.err('receive failed: ${_describe(e)}');
    await cleanup();
    return 1;
  }
  io.out(
    'LISTENING ${engine.self.alias} port=$bound dir=${engine.downloadDir.absolute.path}',
  );
  final link = engine.myPeerLink;
  if (link != null) io.out('PEER-LINK ${link.toUri()}');
  if (pinArg == 'auto') io.out('PIN ${engine.pinGuard?.currentPin}');
  final st = engine.receive.state;
  if (st is On && st.until != null) {
    io.out('WINDOW until=${st.until!.toUtc().toIso8601String()}');
  }

  final code = await done.future;
  if (lingerForPeer) {
    // A session that failed on our side (e.g. rejected at once because stdin
    // is not a terminal) may be read by the sender only after this point:
    // keep serving briefly so it sees FAILED(REJECTED) instead of a refused
    // connection.
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  await cleanup();
  return code;
}

Future<void> _prompt(
  LibreShareEngine engine,
  String sessionId,
  _Io io,
  _Lines lines, {
  String lead = '',
}) async {
  final req = engine.receiver.requestFor(sessionId);
  if (req == null) return;
  final names = req.files.map((f) => _clean(f.fileName)).join(', ');
  final yes = await lines.confirm(
    '${lead}Accept ${req.files.length} file(s) from "${_clean(req.sender.alias)}" '
    '(${req.totalSize} bytes: $names)? [y/N] ',
  );
  try {
    if (yes) {
      await engine.receiver.accept(sessionId);
    } else {
      await engine.receiver.reject(sessionId);
    }
  } on Object catch (e) {
    io.err('prompt: ${e.runtimeType}');
  }
}

/// A first-contact session: show the code, then the human decides (unless
/// `--auto-accept --insecure-tofu` said nobody compares).
Future<void> _incomingSas(
  LibreShareEngine engine,
  String sessionId,
  String code,
  _Io io,
  _Lines lines, {
  required bool skipAsk,
}) async {
  final req = engine.receiver.requestFor(sessionId);
  final fp = engine.incomingInfo(sessionId)?.peer?.fingerprint ?? '';
  io.out(
    'SAS ${_sasText(code)} peer=${_clean(req?.sender.alias ?? '?')} fp=${shortFp(fp)}',
  );
  if (skipAsk) {
    try {
      await engine.receiver.accept(sessionId);
    } on Object catch (e) {
      io.err('accept: ${e.runtimeType}');
    }
    return;
  }
  await _prompt(engine, sessionId, io, lines, lead: 'Do the codes match? ');
}

// ------------------------------------------------------------------- send

Future<int> _send(ArgResults r, _Io io, CliHooks h) async {
  final toArg = r['to'] as String?;
  final deviceArg = r['device'] as String?;
  if (toArg != null && deviceArg != null) {
    io.err('send: --to and --device exclude each other');
    return 64;
  }
  (String, int)? to;
  if (deviceArg == null) {
    to = _parseHostPort(toArg);
    if (to == null) {
      io.err('send: --to host:port (or --device NAME) is required');
      return 64;
    }
  }
  final paths = r.rest;
  if (paths.isEmpty) {
    io.err('send: no files given');
    return 64;
  }
  final concurrency = int.tryParse(r['concurrency'] as String) ?? 3;
  final timeout = int.tryParse(r['timeout'] as String) ?? 120;
  final findTimeout = _parseSeconds(r['find-timeout'] as String?);
  if (deviceArg != null && findTimeout == null) {
    io.err('send: invalid --find-timeout');
    return 64;
  }
  final files = <File>[];
  for (final p in paths) {
    final f = File(p);
    if (!f.existsSync()) {
      io.err('send: not a file: $p');
      return 66;
    }
    files.add(f);
  }

  final su = await _setup(r, io, allowInsecure: r['allow-insecure'] as bool);
  final setup = su.setup;
  if (setup == null) return su.code;
  final tofu = r['insecure-tofu'] as bool;
  final fallback = r['fallback'] as bool? ?? true;
  final lines = _Lines();

  final engine = LibreShareEngine(
    self: _selfFrom(r, 0, setup),
    downloadDir: Directory.systemTemp,
    bindAddress: h.bindAddress,
    discovery: deviceArg == null ? DiscoveryConfig.disabled : _lookingAround(h),
    receiveConfig: const ReceiveConfig(initialMode: ReceiveOff()),
    security: setup.wiring,
    advertiseIp: setup.advertiseIp,
  );
  OutgoingSend? running;
  DiscoveredDevice? chosen;
  final sasPrinted = <Future<void>>[];
  final sasSub = engine.events.listen((e) {
    if (e is SasReady && e.outgoing) {
      final printed = Completer<void>();
      sasPrinted.add(printed.future);
      unawaited(() async {
        var alias = '?';
        var fp = '';
        try {
          final d = chosen?.info ?? await engine.peerInfo(to!.$1, to.$2);
          alias = d.alias;
          fp = d.fingerprint;
        } on Object {
          // the code is still shown
        }
        io.out(
          'SAS ${_sasText(e.code)} peer=${_clean(alias)} fp=${shortFp(fp)}',
        );
        printed.complete();
        if (tofu) return;
        final yes = await lines.confirm('Do the codes match? [y/N] ');
        if (!yes) await running?.cancel();
      }());
    } else if (e is ChannelStateChanged) {
      final ch = e.event;
      if (ch is ChannelTierSwitched) {
        io.out(
          'CHANNEL fallback from ${ch.fromCandidate?.kind.wire ?? "none"} to ${ch.toCandidate.kind.wire}',
        );
      }
    }
  });
  try {
    final SendResult res;
    final String target;
    if (to != null) {
      target = _hostPort(to.$1, to.$2);
      running = engine.beginSendFiles(
        files,
        host: to.$1,
        port: to.$2,
        pin: r['pin'] as String?,
        chunkConcurrency: concurrency,
        acceptTimeout: Duration(seconds: timeout),
      );
      res = await running.result;
    } else {
      await engine.start();
      final found = await _findDevice(
        engine,
        deviceArg!,
        findTimeout!,
        scan: r['scan'] as bool,
        io: io,
      );
      if (found is int) return found;
      final device = found as DiscoveredDevice;
      chosen = device;
      target = device.info.alias;
      running = engine.beginSendToCandidates(
        device,
        files,
        pin: r['pin'] as String?,
        chunkConcurrency: concurrency,
        acceptTimeout: Duration(seconds: timeout),
        enableFallback: fallback,
      );
      res = await running.result;
    }
    // Events arrive asynchronously: let a SAS line still in flight print
    // before the result lines, so the final line stays the last one.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await Future.wait(sasPrinted)
        .timeout(const Duration(seconds: 2), onTimeout: () => const <void>[]);
    final secs = res.elapsed.inMicroseconds / 1e6;
    final mbps = secs > 0 ? res.bytesSent / 1048576 / secs : 0;
    io.out(
      'SENT ${files.length} file(s) ${res.bytesSent} bytes in '
      '${secs.toStringAsFixed(2)}s (${mbps.toStringAsFixed(1)} MiB/s) '
      'status=${res.status.wire}${res.failureReason == null ? '' : ' reason=${res.failureReason!.wire}'}',
    );
    // The final line is printed from the result, not from the engine's event
    // stream: events are delivered asynchronously and would be cancelled
    // before the last one (SessionFinished) reaches a listener.
    if (res.isSuccess) {
      io.out('COMPLETED');
      return 0;
    }
    final reason = res.failureReason?.wire ?? 'UNKNOWN';
    io.out('FAILED $reason');
    io.err(
      'send failed: $reason'
      '${res.refusal == null ? '' : ' (${res.refusal!.wire})'}'
      '${res.failureReason == FailureReason.noConnection ? ' (cannot reach $target)' : ''}',
    );
    return _exitForRefusal(res.refusal);
  } on Object catch (e) {
    io.err('send failed: ${_describe(e)}');
    return _exitForException(e) ?? 1;
  } finally {
    await sasSub.cancel();
    await lines.close();
    await engine.dispose();
    await setup.close();
  }
}

/// The device [selector] names: a `libreshare://peer` link, an id (or its first
/// four or more characters) or an alias, case-insensitive. Returns the device,
/// or an exit code after printing why not.
Future<Object> _findDevice(
  LibreShareEngine engine,
  String selector,
  Duration timeout, {
  required bool scan,
  required _Io io,
}) async {
  if (selector.toLowerCase().startsWith('libreshare:')) {
    final PeerLink link;
    try {
      link = PeerLink.parse(selector);
    } on FormatException {
      io.err('send: --device is not a valid libreshare://peer link');
      return 64;
    }
    try {
      return await engine.addPeerLink(link);
    } on PeerResolveException catch (e) {
      io.err('send failed: ${e.runtimeType}');
      return 1;
    }
  }

  if (scan) unawaited(engine.scanNetwork().then((_) {}, onError: (_) {}));
  final matches = await _awaitMatches(engine, selector, timeout);
  if (matches.isEmpty) {
    io.err(
      'send: no device matching "$selector" found within '
      '${timeout.inMilliseconds / 1000}s (try --scan or a longer '
      '--find-timeout)',
    );
    return 1;
  }
  if (matches.length > 1) {
    io.err('send: "$selector" matches ${matches.length} devices, use the id:');
    for (final d in matches) {
      io.err('  ${_deviceLine(d)}');
    }
    return 64;
  }
  return matches.single;
}

List<DiscoveredDevice> _matchDevices(
  List<DiscoveredDevice> all,
  String selector,
) {
  final s = selector.trim().toLowerCase();
  if (s.isEmpty) return const [];
  final byId = all.where((d) => d.id.toLowerCase() == s).toList();
  if (byId.isNotEmpty) return byId;
  final byAlias = all.where((d) => d.info.alias.toLowerCase() == s).toList();
  if (byAlias.isNotEmpty) return byAlias;
  if (s.length < 4) return const [];
  return all.where((d) => d.id.toLowerCase().startsWith(s)).toList();
}

/// Waits until something matches (plus a moment for a second, ambiguous one)
/// or [timeout] passes.
Future<List<DiscoveredDevice>> _awaitMatches(
  LibreShareEngine engine,
  String selector,
  Duration timeout,
) async {
  final completer = Completer<List<DiscoveredDevice>>();
  Timer? settle;
  void finish() {
    if (!completer.isCompleted) {
      completer.complete(_matchDevices(engine.currentDevices, selector));
    }
  }

  final sub = engine.devices.listen((all) {
    if (_matchDevices(all, selector).isNotEmpty) {
      settle ??= Timer(const Duration(milliseconds: 300), finish);
    }
  });
  final deadline = Timer(timeout, finish);
  try {
    return await completer.future;
  } finally {
    settle?.cancel();
    deadline.cancel();
    await sub.cancel();
  }
}

// -------------------------------------------------------------- peer-link

/// `ls peer-link`: the link others scan or type to reach this device, from a
/// listener that exists only while this command runs (`ls receive` prints the
/// same line while it serves). `ls peer-link LINK`: asks the device behind
/// [LINK] who it is, checks what the link pins and prints it.
Future<int> _peerLink(ArgResults r, _Io io, CliHooks h) async {
  if (r.rest.length > 1) {
    io.err('peer-link: at most one link');
    return 64;
  }
  if (r.rest.isNotEmpty) return _resolveLink(r, r.rest.single, io, h);

  final port = int.tryParse(r['port'] as String);
  if (port == null || port < 0 || port > 65535) {
    io.err('peer-link: invalid --port');
    return 64;
  }
  InternetAddress? bind = h.bindAddress;
  final ipArg = r['ip'] as String?;
  if (ipArg != null) {
    bind = InternetAddress.tryParse(ipArg);
    if (bind == null) {
      io.err('peer-link: invalid --ip');
      return 64;
    }
  }
  final su = await _setup(r, io);
  final setup = su.setup;
  if (setup == null) return su.code;
  final engine = LibreShareEngine(
    self: _selfFrom(r, port, setup),
    downloadDir: Directory.systemTemp,
    preferredPort: port,
    bindAddress: bind,
    receiveConfig: const ReceiveConfig(initialMode: ReceiveAlways()),
    security: setup.wiring,
    advertiseIp: setup.advertiseIp,
  );
  try {
    await engine.start();
    final link = engine.myPeerLink;
    if (link == null) {
      io.err('peer-link: this device has no usable network address');
      return 1;
    }
    io.out(link.toUri());
    return 0;
  } on Object catch (e) {
    io.err('peer-link failed: ${_describe(e)}');
    return 1;
  } finally {
    await engine.dispose();
    await setup.close();
  }
}

Future<int> _resolveLink(ArgResults r, String text, _Io io, CliHooks h) async {
  final PeerLink link;
  try {
    link = PeerLink.parse(text);
  } on FormatException {
    io.err('peer-link: not a valid libreshare://peer link');
    return 64;
  }
  final su = await _setup(r, io);
  final setup = su.setup;
  if (setup == null) return su.code;
  final engine = LibreShareEngine(
    self: _selfFrom(r, 0, setup),
    downloadDir: Directory.systemTemp,
    security: setup.wiring,
    advertiseIp: setup.advertiseIp,
  );
  try {
    final d = await engine.addPeerLink(link);
    io.out('DEVICE ${_deviceLineFor(setup.secure, d)}');
    return 0;
  } on PeerResolveException catch (e) {
    io.err('peer-link failed: ${e.runtimeType}');
    return 1;
  } on Object catch (e) {
    io.err('peer-link failed: ${_describe(e)}');
    return 1;
  } finally {
    await engine.dispose();
    await setup.close();
  }
}

// --------------------------------------------------------------- identity

Future<int> _identity(ArgResults r, _Io io) async {
  if (r.rest.length != 1 || !{'show', 'rotate'}.contains(r.rest.single)) {
    io.err('identity: use `identity show` or `identity rotate`');
    return 64;
  }
  final dirArg = r['identity-dir'] as String?;
  final dir = dirArg == null ? _defaultIdentityDir() : Directory(dirArg);
  try {
    if (r.rest.single == 'rotate') {
      final id = await SecurityWiring.rotateIdentity(dir);
      io.out('ID ${id.deviceId}');
      io.out('FINGERPRINT ${id.fingerprint}');
      return 0;
    }
    final w = await SecurityWiring.open(directory: dir);
    try {
      io.out('ID ${w.identity.identity.deviceId}');
      io.out('FINGERPRINT ${w.identity.identity.fingerprint}');
    } finally {
      await w.close();
    }
    return 0;
  } on IdentityLostException catch (e) {
    io.err(
      'identity lost (${e.reason.name}): the key or its metadata is missing '
      'or damaged; it is never regenerated automatically',
    );
    return exitIdentityLost;
  } on Object catch (e) {
    io.err('identity failed: ${e.runtimeType}');
    return 1;
  }
}

// --------------------------------------------------------------- contacts

final RegExp _uuidRe = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
final RegExp _fp64Re = RegExp(r'^[0-9a-fA-F]{64}$');

Future<int> _contacts(ArgResults r, _Io io) async {
  final sub = r.rest.isEmpty ? '' : r.rest.first;
  final args = r.rest.skip(1).toList();
  final fp = r['fp'] as String?;
  final id = r['id'] as String?;
  // Usage first: nothing is opened for a malformed command.
  switch (sub) {
    case 'list':
      if (args.isNotEmpty) return _contactsUsage(io);
    case 'add':
      if (args.isNotEmpty ||
          id == null ||
          !_uuidRe.hasMatch(id) ||
          fp == null ||
          !_fp64Re.hasMatch(fp)) {
        return _contactsUsage(io);
      }
    case 'remove':
      if (args.length != 1) return _contactsUsage(io);
    case 'block' || 'unblock':
      if (args.length != 1 || !_fp64Re.hasMatch(args.single)) {
        return _contactsUsage(io);
      }
    default:
      return _contactsUsage(io);
  }
  final dirArg = r['identity-dir'] as String?;
  final SecurityWiring w;
  try {
    w = await SecurityWiring.open(
      directory: dirArg == null ? _defaultIdentityDir() : Directory(dirArg),
    );
  } on IdentityLostException {
    io.err('identity lost: it is never regenerated automatically');
    return exitIdentityLost;
  }
  try {
    final trust = w.trust;
    switch (sub) {
      case 'list':
        final list = trust.contacts;
        for (final c in list) {
          io.out(
            'CONTACT ${c.deviceId} trust=${c.trust.name} '
            'fp=${shortFp(c.fingerprint)} alias=${_clean(c.alias)}',
          );
        }
        io.out('CONTACTS ${list.length}');
      case 'add':
        await trust.pin(
          deviceId: id!,
          fingerprint: fp!,
          alias: (r['alias'] as String?) ?? 'contact',
          trust: r['trust'] == 'trusted' ? PeerTrust.trusted : PeerTrust.known,
        );
      case 'remove':
        if (!trust.contacts.any((c) => c.deviceId == args.single)) {
          io.err('contacts: no such contact');
          return 1;
        }
        await trust.remove(args.single);
        try {
          await w.secrets.delete('kpair/${args.single}');
        } on Object {
          // best effort
        }
      case 'block':
        await trust.block(args.single);
      case 'unblock':
        await trust.unblock(args.single);
    }
    return 0;
  } on KeyChangedException {
    io.err('contacts: that device id is pinned with another key');
    return exitKeyChanged;
  } on Object catch (e) {
    io.err('contacts failed: ${e.runtimeType}');
    return 1;
  } finally {
    await w.close();
  }
}

int _contactsUsage(_Io io) {
  io.err(
    'contacts: list | add --id UUID --fp 64HEX [--alias A] [--trust '
    'known|trusted] | remove ID | block FP | unblock FP',
  );
  return 64;
}

// ------------------------------------------------------------------- pair

Future<int> _pair(ArgResults r, _Io io, CliHooks h) async {
  final show = r['show'] as bool;
  final scan = r['scan'] as String?;
  if (show == (scan != null) || r.rest.isNotEmpty) {
    io.err('pair: use `pair --show` or `pair --scan URI`');
    return 64;
  }
  if (r['insecure-plaintext'] == true) {
    io.err('pair: pairing needs the secure profile');
    return 64;
  }
  if (scan != null) {
    final u = Uri.tryParse(scan.trim());
    if (u == null ||
        u.scheme.toLowerCase() != 'libreshare' ||
        u.host.toLowerCase() != 'pair') {
      io.err('pair: not a libreshare://pair invite');
      return 64;
    }
  }
  final port = int.tryParse(r['port'] as String);
  if (port == null || port < 0 || port > 65535) {
    io.err('pair: invalid --port');
    return 64;
  }
  final su = await _setup(r, io);
  final setup = su.setup;
  if (setup == null) return su.code;
  final engine = LibreShareEngine(
    self: _selfFrom(r, port, setup),
    downloadDir: Directory.systemTemp,
    preferredPort: port,
    bindAddress: h.bindAddress,
    receiveConfig: ReceiveConfig(
      initialMode: show ? const ReceiveAlways() : const ReceiveOff(),
    ),
    security: setup.wiring,
    advertiseIp: setup.advertiseIp,
  );
  final lines = _Lines();
  final interrupt = _Interrupt(h);
  try {
    if (scan != null) return await _pairScan(engine, scan.trim(), io);
    return await _pairShow(engine, io, lines, interrupt);
  } finally {
    await interrupt.close();
    await lines.close();
    await engine.dispose();
    await setup.close();
  }
}

Future<int> _pairScan(LibreShareEngine engine, String uri, _Io io) async {
  try {
    final u = Uri.parse(uri);
    final accepted = await engine.redeemPairInvite(uri);
    if (!accepted) {
      io.err('pair: the other device declined');
      return 1;
    }
    final fp = u.queryParameters['fp'] ?? '';
    io.out(
      'PAIRED ${_clean(u.queryParameters['n'] ?? '?')} '
      'fp=${shortFp(fp.toUpperCase())}',
    );
    return 0;
  } on FormatException {
    io.err('pair: not a valid libreshare://pair invite');
    return 64;
  } on Object catch (e) {
    io.err('pair failed: ${_describe(e)}');
    return _exitForException(e) ??
        (e is LsException && e.code == LsErrorCode.notFound
            ? exitAuthRefused
            : 1);
  }
}

Future<int> _pairShow(
  LibreShareEngine engine,
  _Io io,
  _Lines lines,
  _Interrupt interrupt,
) async {
  final paired = Completer<DeviceInfo>();
  PairPrompt? asked;
  final sub = engine.events.listen((e) {
    final p = asked;
    if (e is ContactChanged && p != null && e.deviceId == p.sender.deviceId) {
      if (!paired.isCompleted) paired.complete(p.sender);
    }
  });
  try {
    await engine.start();
    final String uri;
    try {
      uri = engine.createPairInvite();
    } on StateError {
      io.err('pair: no usable address (use --advertise-ip)');
      return 1;
    }
    io.out('PAIR $uri');
    var declined = false;
    var prompted = false;
    while (!interrupt.isFired && !paired.isCompleted) {
      final p = engine.pairing.pendingPrompt;
      if (p != null && !prompted) {
        prompted = true;
        asked = p;
        io.out(
          'PAIR-REQUEST ${_clean(p.sender.alias)} fp=${shortFp(p.fingerprint)}',
        );
        final yes = await lines.confirm('Pair? [y/N] ');
        engine.pairing.decide(accept: yes);
        declined = !yes;
        if (declined) break;
      } else if (p == null && prompted && !paired.isCompleted) {
        // decided; wait for the contact to be stored
      } else if (!engine.pairing.hasActiveInvite && !prompted) {
        io.err('pair: the invite expired');
        return 1;
      }
      await Future.any<void>([
        Future<void>.delayed(const Duration(milliseconds: 100)),
        paired.future.then((_) {}),
        interrupt.fired,
      ]);
    }
    if (paired.isCompleted) {
      final who = await paired.future;
      io.out(
        'PAIRED ${_clean(who.alias)} fp=${shortFp(asked?.fingerprint ?? '')}',
      );
      return 0;
    }
    return declined ? 1 : 0;
  } on Object catch (e) {
    io.err('pair failed: ${_describe(e)}');
    return 1;
  } finally {
    await sub.cancel();
  }
}
