/// Linux start-with-session via an XDG autostart entry (design 01 section 2.1).
///
/// The app writes `$XDG_CONFIG_HOME/autostart/libreshare.desktop` (default
/// `~/.config/autostart`). No systemd unit: the systemd XDG-autostart generator
/// already turns these files into user units, and GNOME, KDE and XFCE read
/// them directly (also under Wayland - no display-server API involved).
///
/// File format: freedesktop Desktop Entry spec 1.5, key `Exec` (quoting rules
/// of section "The Exec key") and `TryExec`.
library;

import 'dart:io';

import '../platform_log.dart';
import '../platform_services.dart';
import 'autostart_common.dart';

class LinuxAutostart implements AutostartService, SelfHealingAutostart {
  /// [environment] and [executable] are injectable for tests (a temp
  /// `XDG_CONFIG_HOME`, a fake binary path); production uses the process
  /// environment and [Platform.resolvedExecutable].
  LinuxAutostart({Map<String, String>? environment, this._executable})
    : _environment = environment ?? Platform.environment;

  static const PlatformLog _log = PlatformLog('autostart');

  /// File name inside the autostart directory.
  static const String fileName = 'libreshare.desktop';

  final Map<String, String> _environment;
  final String? _executable;

  @override
  bool get isSupported => true;

  /// `$XDG_CONFIG_HOME` when it is set to an absolute path (the spec says to
  /// ignore relative values), else `$HOME/.config`. `null` without either.
  String? get configHome {
    final xdg = _environment['XDG_CONFIG_HOME'];
    if (xdg != null && xdg.startsWith('/')) return xdg;
    final home = _environment['HOME'];
    if (home != null && home.isNotEmpty) return '$home/.config';
    return null;
  }

  /// Absolute path of the entry this service manages, or `null` without a
  /// config home.
  String? get entryPath {
    final home = configHome;
    return home == null ? null : '$home/autostart/$fileName';
  }

  /// The binary the entry starts. AppImage: the absolute `$APPIMAGE` path (set
  /// by the AppImage runtime with symlinks resolved), not the squashfs mount
  /// path that [Platform.resolvedExecutable] would give, which changes on every
  /// launch. Otherwise the running executable (.deb: `/usr/bin/libreshare` or
  /// wherever the package puts it).
  String get executablePath {
    final appImage = _environment['APPIMAGE'];
    if (appImage != null && appImage.isNotEmpty) {
      return appImage.startsWith('/') ? appImage : File(appImage).absolute.path;
    }
    return _executable ?? Platform.resolvedExecutable;
  }

  @override
  Future<bool> isEnabled() async {
    final path = entryPath;
    if (path == null) return false;
    try {
      final file = File(path);
      if (!file.existsSync()) return false;
      return parseEntry(file.readAsStringSync()).isActive;
    } on Object catch (e) {
      _log.warning('cannot read $path', e);
      return false;
    }
  }

  @override
  Future<void> setEnabled(bool enabled) async {
    final path = entryPath;
    if (path == null) {
      throw const AutostartException(
        'neither XDG_CONFIG_HOME nor HOME is set; cannot locate the autostart directory',
      );
    }
    try {
      if (enabled) {
        _writeAtomically(path, buildEntry(executable: executablePath));
        _log.info('autostart enabled ($path)');
      } else {
        final file = File(path);
        if (file.existsSync()) file.deleteSync();
        _log.info('autostart disabled');
      }
    } on AutostartException {
      rethrow;
    } on Object catch (e) {
      throw AutostartException(
        'cannot ${enabled ? 'write' : 'remove'} $path',
        e,
      );
    }
  }

  /// Rewrites an existing, user-enabled entry whose `Exec` no longer matches
  /// the running binary (the user moved the AppImage). Never creates an entry
  /// and never re-enables one the user switched off in their desktop's
  /// settings.
  @override
  Future<bool> selfHeal() async {
    final path = entryPath;
    if (path == null) return false;
    try {
      final file = File(path);
      if (!file.existsSync()) return false;
      final current = parseEntry(file.readAsStringSync());
      if (!current.isActive) return false;
      final wanted = buildEntry(executable: executablePath);
      final expected = parseEntry(wanted);
      if (current.exec == expected.exec &&
          current.tryExec == expected.tryExec) {
        return false;
      }
      _writeAtomically(path, wanted);
      _log.info('autostart entry repaired (executable moved)');
      return true;
    } on Object catch (e) {
      _log.warning('autostart self-heal failed', e);
      return false;
    }
  }

  // ----------------------------------------------------------- file format

  /// The full text of the entry for [executable]. Pure; the golden test pins it.
  static String buildEntry({required String executable}) {
    final exec = '${quoteExecArgument(executable)} $kHiddenFlag';
    final tryExec = escapeStringValue(executable);
    return '[Desktop Entry]\n'
        '# Written by LibreShare; delete this file or switch it off in Settings to stop autostart.\n'
        'Type=Application\n'
        'Version=1.0\n'
        'Name=LibreShare\n'
        'Comment=Start LibreShare in the background\n'
        'Exec=${escapeStringValue(exec)}\n'
        'TryExec=$tryExec\n'
        'Icon=libreshare\n'
        'Terminal=false\n'
        'StartupNotify=false\n'
        'Categories=Network;FileTransfer;\n'
        'X-GNOME-Autostart-enabled=true\n';
  }

  /// Quotes one argument for the Desktop Entry `Exec` key (spec "The Exec
  /// key"): an argument containing a reserved character is wrapped in double
  /// quotes with `"`, `` ` ``, `$` and `\` backslash-escaped; a literal `%` is
  /// written `%%` everywhere. The result is still *unescaped* with respect to
  /// the file's string escapes - [buildEntry] applies [escapeStringValue] on
  /// top, which is how a literal backslash ends up as four in the file.
  static String quoteExecArgument(String argument) {
    _rejectControlCharacters(argument);
    final percent = argument.replaceAll('%', '%%');
    if (percent.isNotEmpty && !_needsQuotes.hasMatch(percent)) return percent;
    final escaped = percent.replaceAllMapped(
      RegExp(r'["`$\\]'),
      (m) => '\\${m[0]}',
    );
    return '"$escaped"';
  }

  /// The general string-value escape of the Desktop Entry spec: backslash is
  /// written `\\`. (Other escapes such as `\n` are never needed here.)
  static String escapeStringValue(String value) =>
      value.replaceAll(r'\', r'\\');

  // Reserved characters that force quoting (spec, "The Exec key").
  static final RegExp _needsQuotes = RegExp(r'''[ \t\n"'\\<>~|&;$*?#()`]''');

  static void _rejectControlCharacters(String s) {
    if (s.codeUnits.any((c) => c < 0x20 || c == 0x7f)) {
      throw const AutostartException(
        'the executable path contains control characters',
      );
    }
  }

  /// Minimal reader for the `[Desktop Entry]` group.
  static DesktopEntry parseEntry(String text) {
    final values = <String, String>{};
    var inGroup = false;
    for (final raw in text.split('\n')) {
      final line = raw.trimRight();
      if (line.isEmpty || line.startsWith('#')) continue;
      if (line.startsWith('[')) {
        inGroup = line == '[Desktop Entry]';
        continue;
      }
      if (!inGroup) continue;
      final eq = line.indexOf('=');
      if (eq <= 0) continue;
      values[line.substring(0, eq).trim()] = line.substring(eq + 1).trim();
    }
    return DesktopEntry._(values);
  }

  static void _writeAtomically(String path, String content) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    final tmp = File('$path.tmp');
    tmp.writeAsStringSync(content, flush: true);
    tmp.renameSync(path);
  }
}

/// The few keys of an autostart entry that [LinuxAutostart] cares about.
class DesktopEntry {
  const DesktopEntry._(this.values);

  final Map<String, String> values;

  String? get exec => values['Exec'];
  String? get tryExec => values['TryExec'];

  /// `false` when the desktop's own startup settings switched the entry off
  /// (`Hidden=true`, or GNOME's `X-GNOME-Autostart-enabled=false`), or when it
  /// is not a launchable application entry.
  bool get isActive =>
      values['Type'] == 'Application' &&
      (exec?.isNotEmpty ?? false) &&
      values['Hidden']?.toLowerCase() != 'true' &&
      values['X-GNOME-Autostart-enabled']?.toLowerCase() != 'false';
}
