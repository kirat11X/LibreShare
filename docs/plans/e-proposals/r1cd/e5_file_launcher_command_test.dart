// E5 / R1c: the argument lists handed to Process.start by SystemFileLauncher,
// as PURE functions (no Process, no Windows needed).
//
// SEAM NEEDED in lib/services/file_launcher.dart (does not exist yet):
//
//   class LaunchCommand {
//     const LaunchCommand(this.executable, this.arguments);
//     final String executable;
//     final List<String> arguments;
//   }
//   /// [platform] is Platform.operatingSystem ('linux', 'windows', 'macos',
//   /// 'android', ...). null = this platform has no process launcher.
//   LaunchCommand? openCommand(String path, {required String platform});
//   LaunchCommand? showInFolderCommand(String path, {required String platform});
//
// SystemFileLauncher must call these with Platform.operatingSystem and start
// the returned command (so the tests below describe what really runs).
//
// Windows contract (UNVERIFIED on a real Windows host: the orchestrator
// decides whether to accept it):
//  - `/` in the path becomes `\` (explorer and rundll32 reject forward
//    slashes),
//  - the path is ONE list element, never fused with an option, never split at
//    space, `#`, `&`, `,`, quote or non-ASCII; Dart's own argv quoting then
//    protects it,
//  - show-in-folder is `explorer.exe`, ['/select,', path] (the documented
//    `/select, <path>` form; the path is a separate element so Dart quotes
//    it when it holds a space),
//  - open is `rundll32`, ['url.dll,FileProtocolHandler', path].
//
// Every test name starts with the guard it protects.
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/services/file_launcher.dart';

void main() {
  const nasty = <String>[
    r'C:\Users\Me\Downloads\plain.txt',
    r'C:\Users\Me\My Documents\a b.txt',
    r'C:\Users\Me\Downloads\song #1.mp3',
    r'C:\Users\Me\Downloads\rock&roll.mp3',
    r'C:\Users\Me\Downloads\a,b,c.txt',
    r'C:\Users\Me\Downloads\say "hi".txt',
    'C:\\Users\\Me\\Downloads\\café über 日本語.txt',
    r"C:\Users\Me\Downloads\it's 100%.txt",
    r'\\host\share\dir with space\f.bin',
  ];

  group('Windows open', () {
    for (final path in nasty) {
      test('guard win-open-single-arg: $path stays ONE argument', () {
        final c = openCommand(path, platform: 'windows')!;
        expect(c.executable, 'rundll32');
        expect(c.arguments, ['url.dll,FileProtocolHandler', path]);
      });
    }

    test('guard win-forward-slashes: C:/Users/Me/a b.txt -> backslashes', () {
      final c = openCommand('C:/Users/Me/a b.txt', platform: 'windows')!;
      expect(c.arguments.last, r'C:\Users\Me\a b.txt');
    });

    test('guard win-forward-slashes: mixed separators are all backslashes', () {
      final c = openCommand(r'C:\Users/Me\x/y z.txt', platform: 'windows')!;
      expect(c.arguments.last, r'C:\Users\Me\x\y z.txt');
    });
  });

  group('Windows show in folder', () {
    for (final path in nasty) {
      test('guard win-select-not-fused: $path is its own element after '
          '"/select,"', () {
        final c = showInFolderCommand(path, platform: 'windows')!;
        expect(c.executable, 'explorer.exe');
        expect(c.arguments, ['/select,', path]);
      });
    }

    test('guard win-forward-slashes: C:/a b/c.txt -> backslashes', () {
      final c = showInFolderCommand('C:/a b/c.txt', platform: 'windows')!;
      expect(c.arguments, ['/select,', r'C:\a b\c.txt']);
    });

    test('guard win-select-not-fused: no element other than the first '
        'carries the /select option, and the path never contains it', () {
      final c = showInFolderCommand(r'C:\x,y\a.txt', platform: 'windows')!;
      expect(c.arguments.where((a) => a.startsWith('/select')).length, 1);
      expect(c.arguments.first, '/select,');
      expect(c.arguments.last, r'C:\x,y\a.txt');
    });
  });

  group('other platforms (regression, unchanged behaviour)', () {
    const posix = '/home/me/Downloads/a b #1 & c, "d" é.txt';

    test('guard linux-open: xdg-open <path>', () {
      final c = openCommand(posix, platform: 'linux')!;
      expect(c.executable, 'xdg-open');
      expect(c.arguments, [posix]);
    });

    test('guard linux-show: xdg-open <parent directory>', () {
      final c = showInFolderCommand(posix, platform: 'linux')!;
      expect(c.executable, 'xdg-open');
      expect(c.arguments, ['/home/me/Downloads']);
    });

    test('guard macos-open: open <path>', () {
      final c = openCommand(posix, platform: 'macos')!;
      expect(c.executable, 'open');
      expect(c.arguments, [posix]);
    });

    test('guard macos-show: open -R <path>', () {
      final c = showInFolderCommand(posix, platform: 'macos')!;
      expect(c.executable, 'open');
      expect(c.arguments, ['-R', posix]);
    });

    test('guard posix-slashes-untouched: backslashes in a POSIX file name '
        'are NOT turned into separators', () {
      const odd = r'/home/me/a\b.txt';
      expect(openCommand(odd, platform: 'linux')!.arguments, [odd]);
      expect(openCommand(odd, platform: 'macos')!.arguments, [odd]);
    });

    for (final os in ['android', 'ios', 'fuchsia']) {
      test('guard no-launcher-on-$os: null (UI shows where the file is)', () {
        expect(openCommand('/x/y', platform: os), isNull);
        expect(showInFolderCommand('/x/y', platform: os), isNull);
      });
    }
  });
}
