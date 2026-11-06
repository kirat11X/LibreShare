// F3 defect 3: "Open" and "Show in folder" on Android.
//
// New symbols (services/file_launcher.dart):
//   const String kFileOpenerChannel = 'dev.libreshare/file_opener';
//   class AndroidFileLauncher implements FileLauncher {
//     AndroidFileLauncher({MethodChannel? channel});  // default: kFileOpenerChannel
//   }
//   FileLauncher createFileLauncher({required bool isAndroid, MethodChannel? channel});
//     // Android -> AndroidFileLauncher, else the existing SystemFileLauncher;
//     // fileLauncherProvider's default is createFileLauncher(isAndroid: Platform.isAndroid).
// Channel contract: open / showInFolder, arguments {'path': <the saved file's
// path as the UI passes it>}, answer bool. Any other outcome (false, null, a
// PlatformException, MissingPluginException, a non-bool) is "could not": the
// launcher returns false and never throws, and the UI shows the fallback text
// "Could not open it here. The file is saved at <location>".
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/services/file_launcher.dart';

import '../helpers/f3_fakes.dart';

const String filePath = '/storage/emulated/0/Download/LibreShare/photo.jpg';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the channel name is the documented one', () {
    expect(kFileOpenerChannel, 'dev.libreshare/file_opener');
  });

  group('AndroidFileLauncher on the channel', () {
    test('open asks the channel to open the file', () async {
      final calls = f3MockChannel(kFileOpenerChannel, (_) async => true);
      final ok = await AndroidFileLauncher().open(filePath);
      expect(ok, isTrue);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'open');
      expect(calls.single.arguments, {'path': filePath});
    });

    test(
      'showInFolder asks the channel to open the containing folder',
      () async {
        final calls = f3MockChannel(kFileOpenerChannel, (_) async => true);
        final ok = await AndroidFileLauncher().showInFolder(filePath);
        expect(ok, isTrue);
        expect(calls.single.method, 'showInFolder');
        expect(calls.single.arguments, {'path': filePath});
      },
    );

    test('open and showInFolder are different calls', () async {
      final calls = f3MockChannel(kFileOpenerChannel, (_) async => true);
      final l = AndroidFileLauncher();
      await l.open('/a/one.txt');
      await l.showInFolder('/a/two.txt');
      expect(calls.map((c) => c.method), ['open', 'showInFolder']);
      expect(calls.map((c) => (c.arguments as Map)['path']), [
        '/a/one.txt',
        '/a/two.txt',
      ]);
    });

    test('the native answer is passed on', () async {
      f3MockChannel(kFileOpenerChannel, (_) async => false);
      expect(await AndroidFileLauncher().open(filePath), isFalse);
      expect(await AndroidFileLauncher().showInFolder(filePath), isFalse);
    });

    test('a native error means "could not", not a crash', () async {
      f3MockChannel(kFileOpenerChannel, (_) async {
        throw PlatformException(code: 'no_activity', message: 'no viewer');
      });
      expect(await AndroidFileLauncher().open(filePath), isFalse);
      expect(await AndroidFileLauncher().showInFolder(filePath), isFalse);
    });

    test('a channel that is not registered means "could not"', () async {
      expect(await AndroidFileLauncher().open(filePath), isFalse);
      expect(await AndroidFileLauncher().showInFolder(filePath), isFalse);
    });

    test('a null or non-bool answer means "could not"', () async {
      f3MockChannel(kFileOpenerChannel, (_) async => null);
      expect(await AndroidFileLauncher().open(filePath), isFalse);
      f3MockChannel(kFileOpenerChannel, (_) async => 'yes');
      expect(await AndroidFileLauncher().open(filePath), isFalse);
    });

    test('an explicit channel is used instead of the default', () async {
      final calls = f3MockChannel('test/other_channel', (_) async => true);
      final l = AndroidFileLauncher(
        channel: const MethodChannel('test/other_channel'),
      );
      expect(await l.open(filePath), isTrue);
      expect(calls, hasLength(1));
    });
  });

  group('choosing the launcher', () {
    test('Android gets the channel launcher', () {
      expect(createFileLauncher(isAndroid: true), isA<AndroidFileLauncher>());
    });

    test('desktop keeps the process launcher', () {
      final l = createFileLauncher(isAndroid: false);
      expect(l, isA<SystemFileLauncher>());
      expect(l, isNot(isA<AndroidFileLauncher>()));
    });
  });

  group('the completion screen with the Android launcher', () {
    final saved = f3Received([filePath]);

    testWidgets('Open and Show in folder reach the channel', (tester) async {
      final calls = f3MockChannel(kFileOpenerChannel, (_) async => true);
      await f3PumpTransfer(
        tester,
        F3StubTransfers([saved]),
        launcher: AndroidFileLauncher(),
      );
      await tester.tap(find.byKey(const Key('transfer-open')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('transfer-show-folder')));
      await tester.pump();
      expect(calls.map((c) => c.method), ['open', 'showInFolder']);
      expect(calls.map((c) => (c.arguments as Map)['path']), [
        filePath,
        filePath,
      ]);
      // It worked: no apology.
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('when the channel says no, the message names the location', (
      tester,
    ) async {
      f3MockChannel(kFileOpenerChannel, (_) async => false);
      await f3PumpTransfer(
        tester,
        F3StubTransfers([saved]),
        launcher: AndroidFileLauncher(),
      );
      await tester.tap(find.byKey(const Key('transfer-open')));
      await tester.pump();
      await tester.pump();
      expect(
        find.text('Could not open it here. The file is saved at $filePath'),
        findsOneWidget,
      );
    });

    testWidgets('when the channel throws, the same message appears', (
      tester,
    ) async {
      f3MockChannel(kFileOpenerChannel, (_) async {
        throw PlatformException(code: 'boom');
      });
      await f3PumpTransfer(
        tester,
        F3StubTransfers([saved]),
        launcher: AndroidFileLauncher(),
      );
      await tester.tap(find.byKey(const Key('transfer-show-folder')));
      await tester.pump();
      await tester.pump();
      expect(
        find.textContaining('Could not open it here. The file is saved at '),
        findsOneWidget,
      );
      expect(
        find.textContaining('/storage/emulated/0/Download/LibreShare'),
        findsWidgets,
      );
    });
  });
}
