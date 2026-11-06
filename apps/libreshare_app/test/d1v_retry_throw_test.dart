// Verifier test V11 (delta mutation d): when `beginSendTo` throws inside
// retryWithPin, the view must go back to the finished "PIN required" view
// (dialog available, dismiss works) instead of staying in `preparing`.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/providers/engine_provider.dart';
import 'package:libreshare_app/providers/transfers_provider.dart';
import 'package:libreshare_core/libreshare_core.dart';

import 'helpers/d1b_helpers.dart';
import 'helpers/harness.dart';

const String correctPin = '381920';

/// Forwards what TransfersNotifier uses; `beginSendTo` can be made to throw.
class SwitchEngine implements LibreShareEngine {
  SwitchEngine(this.real);
  final LibreShareEngine real;
  bool failNext = false;

  @override
  Stream<LsEvent> get events => real.events;

  @override
  OutgoingSend beginSendTo(
    DiscoveredDevice device,
    List<File> files, {
    String? pin,
    int chunkConcurrency = 3,
    Duration acceptTimeout = kPermissionTimeout,
    Duration probeTimeout = const Duration(milliseconds: 1500),
  }) {
    if (failNext) {
      failNext = false;
      throw StateError('engine cannot start a send');
    }
    return real.beginSendTo(
      device,
      files,
      pin: pin,
      chunkConcurrency: chunkConcurrency,
      acceptTimeout: acceptTimeout,
      probeTimeout: probeTimeout,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('V11 retryWithPin: a throwing beginSendTo restores the PIN-required view (dismiss works) and a later retry still succeeds', () async {
    SwitchEngine? sw;
    final h = await AppHarness.create(
      overrides: [
        engineOrNullProvider.overrideWith((ref) {
          final a = ref.watch(engineProvider);
          if (a.isLoading || a.hasError) return null;
          return sw = SwitchEngine(a.requireValue);
        }),
      ],
    );
    addTearDown(() => h.dispose());
    await h.boot();
    final bob = await SecureBob.start(h.sandbox, '127.0.0.36', pin: correctPin);
    addTearDown(bob.close);
    final n = h.container.read(transfersProvider.notifier);
    final key = n.startSend(bob.device, [h.pick(h.makeFile('a.txt', 64))]);
    await waitForReal(() => n.find(key)?.pinRequired == true, maxRounds: 500);
    expect(n.find(key)?.pinRequired, isTrue, reason: 'precondition');
    await waitForReal(() => false, maxRounds: 10); // let _drive end

    sw!.failNext = true;
    expect(n.retryWithPin(key, correctPin), isFalse);
    final v = n.find(key)!;
    expect(
      v.phase,
      isNot(TransferPhase.preparing),
      reason: 'must not stay in preparing',
    );
    expect(v.isFinished, isTrue);
    expect(v.pinRequired, isTrue, reason: 'the PIN dialog is available again');

    // A later retry still works (the failed attempt left no stale state).
    expect(n.retryWithPin(key, correctPin), isTrue);
    await waitForReal(
      () => n.find(key)?.phase == TransferPhase.completed,
      maxRounds: 500,
    );
    expect(n.find(key)?.phase, TransferPhase.completed);
    expect(bob.received, hasLength(1));
    n.dismiss(key);
    expect(n.find(key), isNull);
  }, timeout: kSixtySeconds);
}
