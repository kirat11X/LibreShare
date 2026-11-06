// F3 defect 3 (b): the completion screen of a received transfer says where the
// files are, in plain words, under the key `transfer-saved-location`:
//   * a folder under public shared storage (Download, Documents, Pictures, ...)
//     reads "Downloads/<folder>" (see f3_saved_location_function_test.dart);
//   * any other folder is shown as its real path;
//   * a sent transfer shows no location.
// When Open / Show in folder cannot work the existing fallback stays:
//   "Could not open it here. The file is saved at <path>".
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/providers/transfers_provider.dart';
import 'package:libreshare_app/services/file_launcher.dart';

import 'helpers/f3_fakes.dart';

const String publicFile = '/storage/emulated/0/Download/LibreShare/photo.jpg';
const String privateFolder =
    '/storage/emulated/0/Android/data/dev.libreshare.libreshare_app/files/'
    'Download/LibreShare';

String locationText(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('transfer-saved-location'))).data!;

void main() {
  group('saved location on the completion screen', () {
    testWidgets('a public Download folder reads "Downloads/<folder>"', (
      tester,
    ) async {
      await f3PumpTransfer(
        tester,
        F3StubTransfers([
          f3Received([publicFile]),
        ]),
      );
      expect(locationText(tester), contains('Downloads/LibreShare'));
      expect(locationText(tester), isNot(contains('/storage/emulated')));
      expect(locationText(tester), isNot(contains('Android/data')));
    });

    testWidgets('the app-private default shows the real path', (tester) async {
      await f3PumpTransfer(
        tester,
        F3StubTransfers([
          f3Received(['$privateFolder/photo.jpg']),
        ]),
      );
      expect(locationText(tester), contains(privateFolder));
    });

    testWidgets('a desktop folder shows the real path', (tester) async {
      await f3PumpTransfer(
        tester,
        F3StubTransfers([
          f3Received(['/home/me/Downloads/LibreShare/a.txt']),
        ]),
      );
      expect(locationText(tester), contains('/home/me/Downloads/LibreShare'));
    });

    testWidgets('several files in one folder name that folder once', (
      tester,
    ) async {
      await f3PumpTransfer(
        tester,
        F3StubTransfers([
          f3Received([
            '/storage/emulated/0/Documents/Work/a.pdf',
            '/storage/emulated/0/Documents/Work/b.pdf',
          ]),
        ]),
      );
      expect(locationText(tester), contains('Documents/Work'));
      expect(find.byKey(const Key('transfer-saved-location')), findsOneWidget);
    });

    testWidgets('a sent transfer shows no location', (tester) async {
      await f3PumpTransfer(
        tester,
        F3StubTransfers([f3Outgoing(phase: TransferPhase.completed)]),
      );
      expect(find.byKey(const Key('transfer-done')), findsOneWidget);
      expect(find.byKey(const Key('transfer-saved-location')), findsNothing);
    });
  });

  group('when the platform cannot open it', () {
    testWidgets('Open: the message names the file path', (tester) async {
      await f3PumpTransfer(
        tester,
        F3StubTransfers([
          f3Received([publicFile]),
        ]),
        launcher: FakeFileLauncher(succeeds: false),
      );
      await tester.tap(find.byKey(const Key('transfer-open')));
      await tester.pump();
      await tester.pump();
      expect(
        find.text('Could not open it here. The file is saved at $publicFile'),
        findsOneWidget,
      );
    });

    testWidgets('Show in folder: the message names the folder', (tester) async {
      await f3PumpTransfer(
        tester,
        F3StubTransfers([
          f3Received([publicFile]),
        ]),
        launcher: FakeFileLauncher(succeeds: false),
      );
      await tester.tap(find.byKey(const Key('transfer-show-folder')));
      await tester.pump();
      await tester.pump();
      expect(
        find.text(
          'Could not open it here. The file is saved at '
          '/storage/emulated/0/Download/LibreShare',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a launcher that throws gets the same message, no crash', (
      tester,
    ) async {
      await f3PumpTransfer(
        tester,
        F3StubTransfers([
          f3Received([publicFile]),
        ]),
        launcher: ThrowingFileLauncher(),
      );
      await tester.tap(find.byKey(const Key('transfer-open')));
      await tester.pump();
      await tester.pump();
      expect(
        find.text('Could not open it here. The file is saved at $publicFile'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('when opening works there is no apology', (tester) async {
      final launcher = FakeFileLauncher();
      await f3PumpTransfer(
        tester,
        F3StubTransfers([
          f3Received([publicFile]),
        ]),
        launcher: launcher,
      );
      await tester.tap(find.byKey(const Key('transfer-open')));
      await tester.pump();
      await tester.pump();
      expect(launcher.opened, [publicFile]);
      expect(find.textContaining('Could not open it here'), findsNothing);
    });
  });
}
