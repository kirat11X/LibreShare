import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/platform/autostart/autostart_common.dart';
import 'package:libreshare_app/platform/autostart/autostart_linux.dart';

/// What a Desktop Entry reader does with an `Exec` value: undo the file-level
/// string escapes, then split into arguments honouring the quoting rules (spec
/// "The Exec key"). Used to prove that what we write parses back to the
/// original arguments.
List<String> parseExecLikeAShell(String fileValue) {
  final value = fileValue.replaceAll(r'\\', r'\');
  final args = <String>[];
  final current = StringBuffer();
  var inQuotes = false;
  var started = false;
  for (var i = 0; i < value.length; i++) {
    final c = value[i];
    if (inQuotes) {
      if (c == '"') {
        inQuotes = false;
      } else if (c == r'\' && i + 1 < value.length) {
        current.write(value[++i]);
      } else if (c == '%' && i + 1 < value.length && value[i + 1] == '%') {
        current.write('%');
        i++;
      } else {
        current.write(c);
      }
    } else if (c == '"') {
      inQuotes = true;
      started = true;
    } else if (c == ' ') {
      if (started || current.isNotEmpty) args.add(current.toString());
      current.clear();
      started = false;
    } else if (c == '%' && i + 1 < value.length && value[i + 1] == '%') {
      current.write('%');
      i++;
    } else {
      current.write(c);
    }
  }
  if (started || current.isNotEmpty) args.add(current.toString());
  return args;
}

void main() {
  late Directory tmp;
  late String configHome;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ls_autostart_test_');
    configHome = '${tmp.path}/xdg-config';
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  LinuxAutostart make({
    Map<String, String>? env,
    String executable = '/opt/LibreShare/libreshare',
  }) => LinuxAutostart(
    environment: env ?? {'XDG_CONFIG_HOME': configHome},
    executable: executable,
  );

  File entryFile() => File('$configHome/autostart/libreshare.desktop');

  group('entry content', () {
    test('golden file for a plain path', () async {
      await make().setEnabled(true);
      expect(
        entryFile().readAsStringSync(),
        '[Desktop Entry]\n'
        '# Written by LibreShare; delete this file or switch it off in Settings to stop autostart.\n'
        'Type=Application\n'
        'Version=1.0\n'
        'Name=LibreShare\n'
        'Comment=Start LibreShare in the background\n'
        'Exec=/opt/LibreShare/libreshare --hidden\n'
        'TryExec=/opt/LibreShare/libreshare\n'
        'Icon=libreshare\n'
        'Terminal=false\n'
        'StartupNotify=false\n'
        'Categories=Network;FileTransfer;\n'
        'X-GNOME-Autostart-enabled=true\n',
      );
    });

    test('a path with spaces is double-quoted', () {
      final text = LinuxAutostart.buildEntry(
        executable: '/home/ann/My Apps/libreshare',
      );
      expect(text, contains('Exec="/home/ann/My Apps/libreshare" --hidden\n'));
      expect(text, contains('TryExec=/home/ann/My Apps/libreshare\n'));
    });

    test('quote, backslash, dollar, backtick and percent are escaped', () {
      // Double quote: \" at the quoting level, \\" in the file.
      expect(
        LinuxAutostart.buildEntry(executable: '/tmp/we"ird/x'),
        contains(r'Exec="/tmp/we\\"ird/x" --hidden'),
      );
      // Backslash: four in the file (spec: quoting escape, then string escape).
      expect(
        LinuxAutostart.buildEntry(executable: r'/tmp/a\b'),
        contains(r'Exec="/tmp/a\\\\b" --hidden'),
      );
      expect(
        LinuxAutostart.buildEntry(executable: r'/tmp/$HOME/x'),
        contains(r'Exec="/tmp/\\$HOME/x" --hidden'),
      );
      expect(
        LinuxAutostart.buildEntry(executable: '/tmp/a`b/x'),
        contains(r'Exec="/tmp/a\\`b/x" --hidden'),
      );
      // A literal percent would otherwise be read as a field code.
      expect(
        LinuxAutostart.buildEntry(executable: '/tmp/100%/x'),
        contains('Exec=/tmp/100%%/x --hidden'),
      );
      // TryExec is not parsed as a command line: only the string escape.
      expect(
        LinuxAutostart.buildEntry(executable: r'/tmp/a\b'),
        contains(r'TryExec=/tmp/a\\b'),
      );
    });

    test('whatever we write parses back to [path, --hidden]', () {
      const nasty = [
        '/opt/LibreShare/libreshare',
        '/home/ann/My Apps/libreshare',
        '/tmp/we"ird/x',
        r'/tmp/a\b',
        r'/tmp/\\double',
        r'/tmp/$HOME/`x`',
        "/tmp/it's/x",
        '/tmp/100%/x y',
        '/tmp/(paren)/x;y&z|w',
        '/tmp/ünï/中文 dir/x',
      ];
      for (final path in nasty) {
        final entry = LinuxAutostart.parseEntry(
          LinuxAutostart.buildEntry(executable: path),
        );
        expect(parseExecLikeAShell(entry.exec!), [
          path,
          '--hidden',
        ], reason: path);
        expect(entry.tryExec!.replaceAll(r'\\', r'\'), path, reason: path);
      }
    });

    test('a path with control characters is refused', () {
      expect(
        () => LinuxAutostart.buildEntry(executable: '/tmp/a\nb'),
        throwsA(isA<AutostartException>()),
      );
    });
  });

  group('enable / disable', () {
    test('round trip creates and removes exactly one file', () async {
      final service = make();
      expect(service.isSupported, isTrue);
      expect(await service.isEnabled(), isFalse);

      await service.setEnabled(true);
      expect(entryFile().existsSync(), isTrue);
      expect(await service.isEnabled(), isTrue);
      expect(entryFile().parent.listSync().map((e) => e.path.split('/').last), [
        'libreshare.desktop',
      ], reason: 'no temp file left behind');

      await service.setEnabled(false);
      expect(entryFile().existsSync(), isFalse);
      expect(await service.isEnabled(), isFalse);
    });

    test('enabling twice and disabling twice are idempotent', () async {
      final service = make();
      await service.setEnabled(true);
      final first = entryFile().readAsStringSync();
      await service.setEnabled(true);
      expect(entryFile().readAsStringSync(), first);

      await service.setEnabled(false);
      await service.setEnabled(false); // nothing to remove: must not throw
      expect(entryFile().existsSync(), isFalse);
    });

    test('the autostart directory is created on demand', () async {
      expect(Directory('$configHome/autostart').existsSync(), isFalse);
      await make().setEnabled(true);
      expect(Directory('$configHome/autostart').existsSync(), isTrue);
    });

    test('defaults to ~/.config when XDG_CONFIG_HOME is unset or relative', () {
      final home = tmp.path;
      expect(
        make(env: {'HOME': home}).entryPath,
        '$home/.config/autostart/libreshare.desktop',
      );
      expect(
        make(env: {'HOME': home, 'XDG_CONFIG_HOME': 'relative/dir'}).entryPath,
        '$home/.config/autostart/libreshare.desktop',
        reason: 'the spec says relative XDG_CONFIG_HOME values are ignored',
      );
      expect(
        make(env: {'HOME': home, 'XDG_CONFIG_HOME': configHome}).entryPath,
        '$configHome/autostart/libreshare.desktop',
      );
      expect(make(env: const {}).entryPath, isNull);
    });

    test('no config home: reading is false, writing throws', () async {
      final service = make(env: const {});
      expect(await service.isEnabled(), isFalse);
      await expectLater(
        service.setEnabled(true),
        throwsA(isA<AutostartException>()),
      );
    });

    test('a write failure surfaces as AutostartException', () async {
      // A *file* where the autostart directory should be.
      Directory(configHome).createSync(recursive: true);
      File('$configHome/autostart').writeAsStringSync('not a directory');
      await expectLater(
        make().setEnabled(true),
        throwsA(isA<AutostartException>()),
      );
    });

    test(
      'an entry switched off by the desktop is reported as disabled',
      () async {
        final service = make();
        await service.setEnabled(true);
        final text = entryFile().readAsStringSync();

        entryFile().writeAsStringSync(
          text.replaceFirst(
            'X-GNOME-Autostart-enabled=true',
            'X-GNOME-Autostart-enabled=false',
          ),
        );
        expect(await service.isEnabled(), isFalse);

        entryFile().writeAsStringSync('$text\nHidden=true\n');
        expect(await service.isEnabled(), isFalse);

        // Enabling again rewrites the file and clears both switches.
        await service.setEnabled(true);
        expect(await service.isEnabled(), isTrue);
      },
    );
  });

  group('AppImage', () {
    const appImage = '/home/ann/Apps/LibreShare-1.0.AppImage';
    const mounted = '/tmp/.mount_LibreSXyz/usr/bin/libreshare';

    test(r'Exec uses $APPIMAGE, not the squashfs mount path', () async {
      final service = make(
        env: {'XDG_CONFIG_HOME': configHome, 'APPIMAGE': appImage},
        executable: mounted,
      );
      expect(service.executablePath, appImage);
      await service.setEnabled(true);
      final entry = LinuxAutostart.parseEntry(entryFile().readAsStringSync());
      expect(entry.exec, '$appImage --hidden');
      expect(entry.tryExec, appImage);
      expect(entryFile().readAsStringSync(), isNot(contains('.mount_')));
    });

    test('by default the running binary is used', () {
      expect(
        LinuxAutostart(environment: {'XDG_CONFIG_HOME': configHome})
            .executablePath,
        Platform.resolvedExecutable,
      );
    });

    test('without APPIMAGE the running executable is used', () {
      expect(make(executable: mounted).executablePath, mounted);
      // An empty variable counts as unset.
      expect(
        make(
          env: {'XDG_CONFIG_HOME': configHome, 'APPIMAGE': ''},
          executable: mounted,
        ).executablePath,
        mounted,
      );
    });

    test('self-heal rewrites the entry after the AppImage moved', () async {
      await make(
        env: {
          'XDG_CONFIG_HOME': configHome,
          'APPIMAGE': '/home/ann/Downloads/LibreShare.AppImage',
        },
      ).setEnabled(true);

      final moved = make(
        env: {'XDG_CONFIG_HOME': configHome, 'APPIMAGE': appImage},
        executable: mounted,
      );
      expect(await moved.selfHeal(), isTrue);
      expect(
        LinuxAutostart.parseEntry(entryFile().readAsStringSync()).exec,
        '$appImage --hidden',
      );
      expect(await moved.selfHeal(), isFalse, reason: 'already up to date');
    });

    test('self-heal never creates an entry', () async {
      expect(await make().selfHeal(), isFalse);
      expect(entryFile().existsSync(), isFalse);
    });

    test('self-heal respects an entry the user switched off', () async {
      await make().setEnabled(true);
      final disabled = entryFile().readAsStringSync().replaceFirst(
        'X-GNOME-Autostart-enabled=true',
        'X-GNOME-Autostart-enabled=false',
      );
      entryFile().writeAsStringSync(disabled);

      final moved = make(executable: '/somewhere/else/libreshare');
      expect(await moved.selfHeal(), isFalse);
      expect(entryFile().readAsStringSync(), disabled);
    });
  });
}
