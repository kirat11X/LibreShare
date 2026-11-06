// F3 defect 1 (wording), unit level: TransferView gets an OPTIONAL named
// constructor/copyWith parameter `bool wasTransferring` (default false; true
// once the transfer reached TransferPhase.transferring, i.e. data had started
// to move). failureText() then picks the text for FailureReason.noConnection:
//   wasTransferring == false -> "Could not reach <peer>. Check that ..."
//   wasTransferring == true  -> "The connection to <peer> was lost. Keep both
//                               apps open and on the same Wi-Fi, then try again."
// Every other reason reads the same whatever the flag says.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/providers/transfers_provider.dart';
import 'package:libreshare_app/screens/transfer_screen.dart';
import 'package:libreshare_core/libreshare_core.dart';

import 'helpers/f3_fakes.dart';

TransferView lost({
  String peer = 'Pixel 8',
  FailureReason reason = FailureReason.noConnection,
  bool wasTransferring = true,
}) => TransferView(
  key: 't1',
  sessionId: 's-t1',
  direction: TransferDirection.outgoing,
  phase: TransferPhase.failed,
  peerAlias: peer,
  peerPlatform: 'android',
  peerAddress: '192.168.1.20',
  files: const [
    TransferFile(id: 'f1', name: 'a.bin', size: 1000000, done: 400000),
  ],
  createdAt: f3T0,
  failure: reason,
  wasTransferring: wasTransferring,
);

void main() {
  const lostText =
      'The connection to Pixel 8 was lost. Keep both apps open and on the same '
      'Wi-Fi, then try again.';
  const startText =
      'Could not reach Pixel 8. Check that you are on the same network and '
      'that Receive is on.';

  test('a connection lost mid-transfer has its own text', () {
    expect(failureText(lost()), lostText);
  });

  test('without data having moved it is still "Could not reach"', () {
    expect(failureText(lost(wasTransferring: false)), startText);
  });

  test('the two texts are different and name the peer', () {
    final a = failureText(lost());
    final b = failureText(lost(wasTransferring: false));
    expect(a, isNot(b));
    expect(a, isNot(contains('Could not reach')));
    expect(b, isNot(contains('lost')));
    expect(failureText(lost(peer: 'Work-PC')), contains('Work-PC'));
    expect(failureText(lost(peer: 'Work-PC')), isNot(contains('Pixel 8')));
  });

  test('the new text is plain: no exception text, fingerprint or trace', () {
    f3ExpectPlain(failureText(lost()));
  });

  test('other reasons ignore the flag', () {
    for (final reason in FailureReason.values) {
      if (reason == FailureReason.noConnection) continue;
      expect(
        failureText(lost(reason: reason)),
        failureText(lost(reason: reason, wasTransferring: false)),
        reason: '$reason',
      );
    }
    expect(
      failureText(lost(reason: FailureReason.cancelled)),
      'The transfer was cancelled.',
    );
  });

  test('the flag survives copyWith and defaults to false', () {
    final t = lost();
    expect(t.copyWith(speed: 0).wasTransferring, isTrue);
    expect(f3Outgoing().wasTransferring, isFalse);
  });

  testWidgets('the failed screen shows the lost-connection text', (
    tester,
  ) async {
    await f3PumpTransfer(tester, F3StubTransfers([lost()]));
    expect(
      tester.widget<Text>(find.byKey(const Key('failure-text'))).data,
      lostText,
    );
    expect(find.text(startText), findsNothing);
  });
}
