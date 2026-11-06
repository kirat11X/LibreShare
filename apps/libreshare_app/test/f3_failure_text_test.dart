// F3 defect 1 (wording): a failed send must say whether the other device could
// not be reached at the start or the connection dropped mid-transfer.
//   start:   "Could not reach <peer>. Check that you are on the same network and
//             that Receive is on."                       (existing text, kept)
//   dropped: "The connection to <peer> was lost. Keep both apps open and on the
//             same Wi-Fi, then try again."               (new text)
// Both are FailureReason.noConnection; the difference is whether the transfer
// had started moving data: TransfersNotifier sets the optional TransferView
// field `wasTransferring` (see f3_failure_lost_test.dart for the unit tests on
// that field). This file only uses symbols that exist today.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/providers/transfers_provider.dart';
import 'package:libreshare_app/screens/transfer_screen.dart';
import 'package:libreshare_core/libreshare_core.dart';

import 'helpers/f3_fakes.dart';
import 'helpers/harness.dart';

const String startText =
    'Could not reach Ghost. Check that you are on the same network and that '
    'Receive is on.';
const String lostText =
    'The connection to Pixel 8 was lost. Keep both apps open and on the same '
    'Wi-Fi, then try again.';

void main() {
  // Plaintext fixture peers against the app's secure engine (see the harness).
  setUpAll(() => AppHarness.legacyPlaintextPeers = true);
  tearDownAll(() => AppHarness.legacyPlaintextPeers = false);

  group('failure texts', () {
    test('an unreachable peer keeps the "Could not reach" text', () {
      final t = f3Outgoing(
        phase: TransferPhase.failed,
        failure: FailureReason.noConnection,
        files: const [TransferFile(id: 'f1', name: 'a', size: 100)],
        peer: 'Ghost',
      );
      expect(failureText(t), startText);
      expect(startText, contains('Ghost'));
    });

    test('every reason, direction and flag yields one plain sentence', () {
      for (final reason in [...FailureReason.values, null]) {
        for (final outgoing in [true, false]) {
          for (final local in [true, false]) {
            final base = outgoing
                ? f3Outgoing(
                    phase: TransferPhase.failed,
                    failure: reason,
                    peer: 'Pixel 8',
                  )
                : f3Received(const ['/d/a.txt']);
            final t = base.copyWith(
              phase: TransferPhase.failed,
              failure: reason,
              localFileError: local,
            );
            f3ExpectPlain(
              failureText(t),
              reason: '$reason outgoing=$outgoing local=$local',
            );
          }
        }
      }
    });

    testWidgets('the failed screen shows the unreachable text for a send that '
        'never started', (tester) async {
      await f3PumpTransfer(
        tester,
        F3StubTransfers([
          f3Outgoing(
            phase: TransferPhase.failed,
            failure: FailureReason.noConnection,
            peer: 'Ghost',
            files: const [TransferFile(id: 'f1', name: 'a', size: 100)],
          ),
        ]),
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('failure-text'))).data,
        startText,
      );
    });
  });

  group('failure texts against the real engine', () {
    testWidgets('a device that is not there: "Could not reach"', (
      tester,
    ) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      await tester.startApp(h);
      final ghost = DiscoveredDevice(
        info: DeviceInfo(
          deviceId: 'ghost-device',
          alias: 'Ghost',
          platform: 'linux',
          deviceType: 'desktop',
          port: 1,
        ),
        address: '127.0.0.9',
        lastSeen: h.clock.now(),
        source: DiscoverySource.manual,
      );
      final key = h.container.read(transfersProvider.notifier).startSend(
        ghost,
        [h.pick(h.makeFile('a.txt', 5))],
      );
      await tester.settleUntil(
        () =>
            h.container.read(transfersProvider).single.phase ==
            TransferPhase.failed,
        what: 'no connection',
        maxRounds: 400,
      );
      final t = h.container.read(transfersProvider).single;
      expect(t.key, key);
      expect(failureText(t), startText);
      expect(t.failure, FailureReason.noConnection);
      await tester.stopApp(h);
    });

    testWidgets(
      'the other device vanishes mid-transfer: "connection was lost"',
      (tester) async {
        final h = (await tester.runAsync(AppHarness.create))!;
        final peer = (await tester.runAsync(
          () => h.startPeer('Pixel 8', platform: 'android'),
        ))!;
        // 48 MiB written in blocks; enough that the sender is still mid-way when
        // the first progress event arrives.
        final file = File('${h.sandbox.path}/src/big.bin')
          ..createSync(recursive: true);
        final raf = file.openSync(mode: FileMode.write);
        final block = List<int>.generate(1 << 20, (i) => (i * 31 + 7) & 0xff);
        for (var i = 0; i < 48; i++) {
          raf.writeFromSync(block);
        }
        raf.closeSync();
        h.picker.files = [h.pick(file)];
        await tester.startApp(h);
        await tester.settleUntil(
          () => h.engine.currentDevices.any((d) => d.id == peer.id),
          what: 'peer listed',
        );
        final device = h.engine.currentDevices.single;

        var killed = false;
        final sub = h.container.listen<List<TransferView>>(transfersProvider, (
          _,
          next,
        ) {
          if (killed || next.isEmpty) return;
          if (next.first.bytesDone > 0 && !next.first.isFinished) {
            killed = true;
            unawaited(peer.engine.dispose(force: true));
          }
        });
        h.container.read(transfersProvider.notifier).startSend(device, [
          h.pick(file),
        ]);
        await tester.settleUntil(
          () => h.container.read(transfersProvider).first.isFinished,
          what: 'transfer ended',
          maxRounds: 600,
        );
        sub.close();
        final t = h.container.read(transfersProvider).first;
        expect(killed, isTrue, reason: 'the peer was taken away mid-transfer');
        expect(t.phase, TransferPhase.failed);
        expect(t.failure, FailureReason.noConnection);
        expect(failureText(t), lostText);
        f3ExpectPlain(failureText(t));
        await tester.stopApp(h);
      },
    );
  });
}
