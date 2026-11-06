// ReceiveController (design 01 s1): the whole state machine on a fake clock,
// no sockets. The twelve rows of the s1.6 test plan come first, then the edges
// around them (env causes, settings, shutdown).
import 'dart:async';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/manual_clock.dart';

const _m10 = Duration(minutes: 10);
const _h1 = Duration(hours: 1);

class Rig {
  Rig({
    ReceivePlatformCaps caps = const ReceivePlatformCaps(),
    ReceivePersisted? persisted,
    bool contacts = false,
    Duration drainGrace = const Duration(minutes: 5),
  }) : store = InMemoryReceiveSettingsStore(persisted) {
    controller = ReceiveController(
      gate: gate,
      store: store,
      clock: clock,
      scheduler: clock,
      caps: caps,
      env: env.stream,
      settings: persisted?.settings ?? const ReceiveSettings(),
      contactsSupported: contacts,
      drainGrace: drainGrace,
    );
    controller.states.listen(states.add);
    controller.events.listen(events.add);
  }

  final ManualClock clock = ManualClock();
  final FakeGate gate = FakeGate();
  final InMemoryReceiveSettingsStore store;
  final StreamController<EnvEvent> env = StreamController<EnvEvent>();
  late final ReceiveController controller;
  final List<ReceiveState> states = [];
  final List<ReceiveEvent> events = [];

  ReceiveState get state => controller.state;
  ReceiveRuntime get stored => store.value.runtime;
  DateTime get now => clock.now();

  Future<void> sendEnv(EnvEvent e) async {
    env.add(e);
    await pumpEventQueue();
  }

  List<T> eventsOf<T extends ReceiveEvent>() => events.whereType<T>().toList();
}

void main() {
  group('design 01 s1.6 test plan', () {
    test('off_to_always_binds_and_announces', () async {
      final r = Rig();
      expect(r.state, const Off(OffReason.neverEnabled));

      await r.controller.turnOn(const ReceiveAlways());

      expect(r.gate.opens, 1);
      expect(r.gate.policy, AnnouncePolicy.periodic);
      expect(r.gate.accepting, isTrue);
      expect(
        r.state,
        isA<On>()
            .having((s) => s.until, 'until', isNull)
            .having((s) => s.since, 'since', r.now)
            .having(
              (s) => s.visibility,
              'visibility',
              ReceiveVisibility.everyone,
            ),
      );
      expect(r.clock.pending, 0, reason: 'Always arms no timer');
      expect(r.stored.state, ReceiveRuntimeState.on);
      expect(r.stored.mode, const ReceiveAlways());
      expect(r.stored.cleanStop, isFalse);
      // Starting is visible on the way.
      await pumpEventQueue();
      expect(r.states, [const Starting(), isA<On>()]);
    });

    test('for_10m_expires_exactly', () async {
      final r = Rig();
      await r.controller.turnOn(const ReceiveFor(_m10));
      final on = r.state as On;
      expect(on.until, r.now.add(_m10));

      await r.clock.advance(_m10 - const Duration(seconds: 1));
      expect(r.state, isA<On>());
      expect(r.gate.listening, isTrue);

      await r.clock.advance(const Duration(seconds: 1));
      expect(r.state, const Off(OffReason.expired));
      expect(r.gate.listening, isFalse);
      expect(r.gate.calls, contains('close(graceful)'));
      expect(r.gate.policy, AnnouncePolicy.none);
      expect(r.stored.state, ReceiveRuntimeState.off);
      expect(r.stored.offReason, OffReason.expired);
      expect(r.clock.pending, 0);
      expect(
        r.eventsOf<StateChanged>().last,
        isA<StateChanged>().having(
          (e) => e.cause,
          'cause',
          ReceiveCause.expired,
        ),
      );
    });

    test('expiring_soon_fires_once_at_t_minus_15m', () async {
      final r = Rig();
      await r.controller.turnOn(const ReceiveFor(_h1));

      await r.clock.advance(const Duration(minutes: 44, seconds: 59));
      expect(r.eventsOf<ExpiringSoon>(), isEmpty);
      await r.clock.advance(const Duration(seconds: 1));
      expect(r.eventsOf<ExpiringSoon>(), hasLength(1));
      expect(
        r.eventsOf<ExpiringSoon>().single.remaining,
        const Duration(minutes: 15),
      );

      await r.clock.advance(const Duration(minutes: 20));
      expect(r.eventsOf<ExpiringSoon>(), hasLength(1), reason: 'only once');
      expect(r.state, const Off(OffReason.expired));

      // Windows of 15 minutes or less never warn.
      for (final d in const [
        Duration(minutes: 15),
        _m10,
        Duration(minutes: 1),
      ]) {
        final s = Rig();
        await s.controller.turnOn(ReceiveFor(d));
        await s.clock.advance(d);
        expect(s.eventsOf<ExpiringSoon>(), isEmpty, reason: '$d');
        expect(s.state, const Off(OffReason.expired));
      }
    });

    test('expiry_with_active_session_drains', () async {
      final r = Rig();
      await r.controller.turnOn(const ReceiveFor(Duration(minutes: 20)));
      final start = r.now;
      r.gate.setActive(1);

      await r.clock.advance(const Duration(minutes: 20));
      expect(r.state, Draining(start.add(const Duration(minutes: 25))));
      expect(
        r.gate.listening,
        isTrue,
        reason: 'listener stays for the transfer',
      );
      expect(r.gate.accepting, isFalse, reason: 'new sessions get BUSY');
      expect(r.gate.policy, AnnouncePolicy.none);
      expect(r.eventsOf<ExpiredWhileBusy>().single.activeSessions, 1);

      // The transfer finishes: the listener closes without force.
      r.gate.setActive(0);
      await pumpEventQueue();
      expect(r.state, const Off(OffReason.expired));
      expect(r.gate.calls, contains('close(graceful)'));
      expect(r.gate.accepting, isTrue, reason: 'reset for the next window');
      expect(r.clock.pending, 0);
    });

    test('drain deadline forces the close', () async {
      final r = Rig();
      await r.controller.turnOn(const ReceiveFor(Duration(minutes: 20)));
      r.gate.setActive(2);
      await r.clock.advance(const Duration(minutes: 20));
      expect(r.state, isA<Draining>());

      await r.clock.advance(const Duration(minutes: 4, seconds: 59));
      expect(r.state, isA<Draining>());
      await r.clock.advance(const Duration(seconds: 1));
      expect(r.state, const Off(OffReason.expired));
      expect(r.gate.calls.last, anyOf('close(forced)', 'accepting(true)'));
      expect(r.gate.calls, contains('close(forced)'));
      expect(r.eventsOf<StateChanged>().last.cause, ReceiveCause.drainTimeout);
      expect(r.clock.pending, 0);
    });

    test(
      'the OS time limit caps the drain (hardStop = limit - margin)',
      () async {
        final r = Rig(
          caps: const ReceivePlatformCaps(osTimeout: Duration(minutes: 21)),
        );
        await r.controller.turnOn(const ReceiveFor(Duration(minutes: 20)));
        final start = r.now;
        r.gate.setActive(1);
        await r.clock.advance(const Duration(minutes: 20));
        // 21 min - 8 s after the start: 52 s of grace instead of 5 minutes.
        expect(
          r.state,
          Draining(start.add(const Duration(minutes: 20, seconds: 52))),
        );
        await r.clock.advance(const Duration(seconds: 52));
        expect(r.state, const Off(OffReason.expired));
      },
    );

    test('platform_timeout_pauses_then_resume_gets_fresh_window', () async {
      final r = Rig();
      await r.controller.turnOn(const ReceiveFor(_h1));
      await r.clock.advance(const Duration(minutes: 30));

      await r.controller.platformTimeout();
      expect(r.state, const Paused(PauseReason.platformTimeout));
      expect(r.gate.listening, isFalse);
      expect(r.gate.policy, AnnouncePolicy.none);
      expect(r.clock.pending, 0, reason: 'no timer survives a platform pause');
      expect(r.stored.state, ReceiveRuntimeState.paused);
      expect(r.stored.pauseReason, PauseReason.platformTimeout);

      await r.clock.advance(const Duration(hours: 3));
      expect(r.state, const Paused(PauseReason.platformTimeout));

      await r.controller.resume();
      expect(r.gate.opens, 2);
      final on = r.state as On;
      expect(on.until, r.now.add(_h1), reason: 'a full window, not the rest');
      await r.clock.advance(_h1 - const Duration(seconds: 1));
      expect(r.state, isA<On>());
      await r.clock.advance(const Duration(seconds: 1));
      expect(r.state, const Off(OffReason.expired));
    });

    test('visibility_change_does_not_rebind', () async {
      final r = Rig(contacts: true);
      await r.controller.turnOn(const ReceiveAlways());
      r.gate.calls.clear();

      await r.controller.setVisibility(ReceiveVisibility.contacts);
      expect(r.gate.calls, ['announce(replyToTrusted)']);
      expect(r.gate.opens, 0);
      expect((r.state as On).visibility, ReceiveVisibility.contacts);
      expect(r.store.value.settings.visibility, ReceiveVisibility.contacts);

      await r.controller.setVisibility(ReceiveVisibility.everyone);
      expect(r.gate.calls, ['announce(replyToTrusted)', 'announce(periodic)']);
      expect(r.gate.listening, isTrue);
    });

    test(
      'contacts-only is refused until pairing exists (Increment 3)',
      () async {
        final r = Rig();
        await r.controller.turnOn(const ReceiveAlways());
        await expectLater(
          r.controller.setVisibility(ReceiveVisibility.contacts),
          throwsUnsupportedError,
        );
        expect(r.controller.settings.visibility, ReceiveVisibility.everyone);
        expect(r.gate.policy, AnnouncePolicy.periodic);
      },
    );

    test('always_is_clamped_on_android_caps', () async {
      final r = Rig(
        caps: const ReceivePlatformCaps(maxContinuous: Duration(hours: 6)),
      );
      await r.controller.turnOn(const ReceiveAlways());
      expect((r.state as On).until, r.now.add(const Duration(hours: 6)));
      await r.clock.advance(const Duration(hours: 6));
      expect(r.state, const Off(OffReason.expired));

      // A longer explicit window is clamped too.
      await r.controller.turnOn(const ReceiveFor(Duration(hours: 12)));
      expect((r.state as On).until, r.now.add(const Duration(hours: 6)));
      // ...a shorter one is not.
      await r.controller.turnOn(const ReceiveFor(_h1));
      expect((r.state as On).until, r.now.add(_h1));
    });

    test('network_loss_pauses_and_auto_resumes_within_window', () async {
      final r = Rig();
      await r.controller.turnOn(const ReceiveFor(_h1));
      final until = (r.state as On).until;
      await r.clock.advance(_m10);

      await r.sendEnv(const NetworkDown());
      expect(r.state, const Paused(PauseReason.noNetwork));
      expect(r.gate.listening, isFalse);
      expect(r.gate.policy, AnnouncePolicy.none);
      expect(
        r.clock.pending,
        greaterThan(0),
        reason: 'the window keeps running',
      );

      await r.clock.advance(_m10);
      await r.sendEnv(const NetworkUp());
      expect(r.gate.opens, 2);
      expect(r.state, isA<On>().having((s) => s.until, 'same window', until));
      expect(r.gate.policy, AnnouncePolicy.periodic);

      await r.clock.advance(const Duration(minutes: 40));
      expect(r.state, const Off(OffReason.expired));
    });

    test('after the window ended, network back does not resume', () async {
      final r = Rig();
      await r.controller.turnOn(const ReceiveFor(_m10));
      await r.sendEnv(const NetworkDown());
      expect(r.state, const Paused(PauseReason.noNetwork));

      await r.clock.advance(_m10);
      expect(r.state, const Off(OffReason.expired));
      await r.sendEnv(const NetworkUp());
      expect(r.state, const Off(OffReason.expired));
      expect(r.gate.opens, 1);
    });

    test(
      'battery and permission pauses resume only when every cause is gone',
      () async {
        final r = Rig();
        await r.controller.turnOn(const ReceiveAlways());
        await r.sendEnv(const NetworkDown());
        await r.sendEnv(const BatteryLow());
        expect(
          r.state,
          const Paused(PauseReason.batteryLow),
          reason: 'newest cause',
        );

        await r.sendEnv(const NetworkUp());
        expect(r.state, const Paused(PauseReason.batteryLow));
        await r.sendEnv(const BatteryOk());
        expect(r.state, isA<On>());
        expect(r.gate.opens, 2);

        await r.sendEnv(const PermissionLost());
        expect(r.state, const Paused(PauseReason.permissionMissing));
        await r.sendEnv(const PermissionGranted());
        expect(r.state, isA<On>());
        // Screen events are carried but ignored.
        await r.sendEnv(const ScreenOff());
        await r.sendEnv(const ScreenOn());
        expect(r.state, isA<On>());
      },
    );

    group('restore', () {
      ReceivePersisted dirty({
        required ReceiveMode mode,
        required Duration? untilIn,
        bool clean = false,
        ReceiveRuntimeState state = ReceiveRuntimeState.on,
      }) => ReceivePersisted(
        runtime: ReceiveRuntime(
          state: state,
          mode: mode,
          until: untilIn == null
              ? null
              : DateTime.utc(2026, 11, 3, 12).add(untilIn),
          cleanStop: clean,
        ),
      );

      test(
        'restore_after_crash_in_window re-enters On with the time left',
        () async {
          final r = Rig(
            persisted: dirty(
              mode: const ReceiveFor(_h1),
              untilIn: const Duration(minutes: 30),
            ),
          );
          await r.controller.restore();
          expect(r.gate.opens, 1);
          expect((r.state as On).until, r.now.add(const Duration(minutes: 30)));
          await r.clock.advance(const Duration(minutes: 29, seconds: 59));
          expect(r.state, isA<On>());
          await r.clock.advance(const Duration(seconds: 1));
          expect(r.state, const Off(OffReason.expired));
          expect(
            r.controller.lastMode,
            const ReceiveFor(_h1),
            reason: 'resume() repeats the original window, not the remainder',
          );
        },
      );

      test('an unlimited window survives a crash', () async {
        final r = Rig(
          persisted: dirty(mode: const ReceiveAlways(), untilIn: null),
        );
        await r.controller.restore();
        expect((r.state as On).until, isNull);
        expect(r.gate.opens, 1);
      });

      test('restore_after_window is Off(expired)', () async {
        final r = Rig(
          persisted: dirty(
            mode: const ReceiveFor(_h1),
            untilIn: const Duration(minutes: -1),
          ),
        );
        await r.controller.restore();
        expect(r.state, const Off(OffReason.expired));
        expect(r.gate.opens, 0);
      });

      test('restore_with_userStopped_hint is Off(user)', () async {
        final r = Rig(
          persisted: dirty(mode: const ReceiveAlways(), untilIn: null),
        );
        await r.controller.restore(hint: ExitHint.userStopped);
        expect(r.state, const Off(OffReason.user));
        expect(r.gate.opens, 0);
        expect(r.stored.state, ReceiveRuntimeState.off);
      });

      test('a clean exit does not restart receiving', () async {
        final r = Rig(
          persisted: dirty(
            mode: const ReceiveAlways(),
            untilIn: null,
            clean: true,
          ),
        );
        await r.controller.restore();
        expect(r.state, const Off(OffReason.user));
        expect(r.gate.opens, 0);
      });

      test('Android (resumeAfterCrash: false) waits for a tap in Paused(osStopped)', () async {
        final r = Rig(
          caps: const ReceivePlatformCaps(resumeAfterCrash: false),
          persisted: dirty(
            mode: const ReceiveFor(_h1),
            untilIn: const Duration(minutes: 30),
          ),
        );
        await r.controller.restore();
        expect(r.state, const Paused(PauseReason.osStopped));
        expect(r.gate.opens, 0);
        await r.controller.resume();
        expect((r.state as On).until, r.now.add(_h1));
      });

      test(
        'nothing stored is Off(neverEnabled); a stored Off keeps its reason',
        () async {
          final r = Rig();
          await r.controller.restore();
          expect(r.state, const Off(OffReason.neverEnabled));

          final s = Rig(
            persisted: const ReceivePersisted(
              runtime: ReceiveRuntime(offReason: OffReason.expired),
            ),
          );
          await s.controller.restore();
          expect(s.state, const Off(OffReason.expired));
        },
      );

      test('restore loads the stored settings', () async {
        final r = Rig(
          persisted: const ReceivePersisted(
            settings: ReceiveSettings(
              defaultMode: ReceiveFor(_m10),
              autostart: true,
            ),
          ),
        );
        // The Rig seeds the controller with them; start from defaults to prove
        // restore() does the loading.
        final c = ReceiveController(
          gate: r.gate,
          store: r.store,
          clock: r.clock,
          scheduler: r.clock,
        );
        expect(c.settings.autostart, isFalse);
        await c.restore();
        expect(c.settings.autostart, isTrue);
        expect(c.settings.defaultMode, const ReceiveFor(_m10));
        await c.turnOn();
        expect((c.state as On).until, r.now.add(_m10));
        await c.dispose();
      });
    });

    test('bind_failure_is_failed_and_leaks_no_timer', () async {
      final r = Rig();
      r.gate.failOpen = const SocketException('address in use');
      await r.controller.turnOn(const ReceiveFor(_h1));

      expect(r.state, isA<Failed>());
      expect(r.clock.pending, 0);
      expect(r.gate.policy, AnnouncePolicy.none);
      expect(r.gate.listening, isFalse);
      expect(r.stored.state, ReceiveRuntimeState.off);

      // A later attempt works.
      await r.controller.turnOn(const ReceiveFor(_h1));
      expect(r.state, isA<On>());
      expect(r.clock.pending, greaterThan(0));
    });

    test('turn_on_twice_and_off_during_starting_are_idempotent', () async {
      final r = Rig();
      r.gate.holdOpen = Completer<void>();

      final a = r.controller.turnOn(const ReceiveAlways());
      final b = r.controller.turnOn(const ReceiveAlways());
      final off = r.controller.turnOff();
      await pumpEventQueue();
      expect(r.state, const Starting());
      expect(r.gate.opens, 1);

      r.gate.holdOpen!.complete();
      await Future.wait([a, b, off]);
      expect(r.gate.opens, 1, reason: 'one bind');
      expect(r.state, const Off(OffReason.user));
      expect(r.gate.listening, isFalse);
      expect(r.gate.closes, 1);
      expect(r.clock.pending, 0);
    });

    test(
      'turning on twice in a row binds once and re-arms the window',
      () async {
        final r = Rig();
        await r.controller.turnOn(const ReceiveFor(_m10));
        await r.clock.advance(const Duration(minutes: 5));
        final since = (r.state as On).since;

        // "Extend": a new window from now, same listener.
        await r.controller.turnOn(const ReceiveFor(_h1));
        expect(r.gate.opens, 1);
        expect(r.state, isA<On>().having((s) => s.since, 'since', since));
        expect((r.state as On).until, r.now.add(_h1));

        await r.clock.advance(_m10);
        expect(r.state, isA<On>(), reason: 'the old 10 min timer is gone');
      },
    );

    test('wall_clock_jump_backwards_does_not_extend_window', () async {
      final r = Rig();
      await r.controller.turnOn(const ReceiveFor(_m10));
      await r.clock.advance(const Duration(minutes: 5));

      r.clock.jumpWallClock(const Duration(hours: -1));
      await r.clock.advance(const Duration(minutes: 4, seconds: 59));
      expect(r.state, isA<On>());
      await r.clock.advance(const Duration(seconds: 1));
      expect(
        r.state,
        const Off(OffReason.expired),
        reason: 'scheduler time rules',
      );
    });

    test('a wall-clock jump forwards does not cut the window short', () async {
      final r = Rig();
      await r.controller.turnOn(const ReceiveFor(_m10));
      r.clock.jumpWallClock(const Duration(hours: 5));
      await pumpEventQueue();
      expect(r.state, isA<On>());
      await r.clock.advance(_m10);
      expect(r.state, const Off(OffReason.expired));
    });
  });

  group('around the plan', () {
    test('turnOff from every live state', () async {
      for (final setup in <Future<void> Function(Rig)>[
        (r) async => r.controller.turnOn(const ReceiveAlways()),
        (r) async {
          await r.controller.turnOn(const ReceiveFor(_h1));
          await r.controller.platformTimeout();
        },
        (r) async {
          await r.controller.turnOn(const ReceiveFor(_m10));
          r.gate.setActive(1);
          await r.clock.advance(_m10);
          expect(r.state, isA<Draining>());
        },
      ]) {
        final r = Rig();
        await setup(r);
        await r.controller.turnOff();
        expect(r.state, const Off(OffReason.user));
        expect(r.gate.listening, isFalse);
        expect(r.gate.policy, AnnouncePolicy.none);
        expect(r.gate.accepting, isTrue);
        expect(r.clock.pending, 0);
        expect(r.stored.offReason, OffReason.user);
      }
    });

    test(
      'turnOff with a transfer running drops the connection, otherwise waits',
      () async {
        final r = Rig();
        await r.controller.turnOn(const ReceiveAlways());
        r.gate.setActive(1);
        await r.controller.turnOff();
        expect(r.gate.calls, contains('close(forced)'));

        await r.controller.turnOn(const ReceiveAlways());
        r.gate.setActive(0);
        await r.controller.turnOff();
        expect(r.gate.calls.last, 'accepting(true)');
        expect(r.gate.calls, contains('close(graceful)'));
      },
    );

    test(
      'turnOff while never enabled is recorded as the user\'s choice',
      () async {
        final r = Rig();
        await r.controller.turnOff();
        expect(r.state, const Off(OffReason.user));
        expect(r.stored.offReason, OffReason.user);
        expect(r.gate.calls, isEmpty);
        // ...but an expired window keeps its reason.
        await r.controller.turnOn(const ReceiveFor(_m10));
        await r.clock.advance(_m10);
        await r.controller.turnOff();
        expect(r.state, const Off(OffReason.expired));
      },
    );

    test('resume works after expiry and is a no-op while receiving', () async {
      final r = Rig();
      await r.controller.turnOn(const ReceiveFor(_m10));
      await r.controller.resume();
      expect(r.gate.opens, 1);
      await r.clock.advance(_m10);
      expect(r.state, const Off(OffReason.expired));

      await r.controller.resume();
      expect(r.state, isA<On>());
      expect((r.state as On).until, r.now.add(_m10));
    });

    test('turnOn(ReceiveOff) is turnOff', () async {
      final r = Rig();
      await r.controller.turnOn(const ReceiveAlways());
      await r.controller.turnOn(const ReceiveOff());
      expect(r.state, const Off(OffReason.user));
    });

    test('a window can be turned back on while draining', () async {
      final r = Rig();
      await r.controller.turnOn(const ReceiveFor(_m10));
      r.gate.setActive(1);
      await r.clock.advance(_m10);
      expect(r.state, isA<Draining>());

      await r.controller.turnOn(const ReceiveFor(_h1));
      expect(r.state, isA<On>());
      expect(r.gate.accepting, isTrue);
      expect(r.gate.policy, AnnouncePolicy.periodic);
      expect(r.gate.opens, 1);
      // The drain watcher is gone: finishing the transfer changes nothing.
      r.gate.setActive(0);
      await pumpEventQueue();
      expect(r.state, isA<On>());
    });

    test('settings are persisted and visible', () async {
      final r = Rig();
      const next = ReceiveSettings(
        defaultMode: ReceiveFor(_h1),
        autostart: true,
        startHidden: false,
        androidWindow: Duration(hours: 12),
        receiveOnBoot: true,
      );
      await r.controller.updateSettings(next);
      expect(r.controller.settings, next);
      expect(r.store.value.settings, next);
      await r.controller.turnOn();
      expect((r.state as On).until, r.now.add(_h1));
    });

    test(
      'shutdown marks a clean stop; the next start does not receive',
      () async {
        final r = Rig();
        await r.controller.turnOn(const ReceiveAlways());
        await r.controller.shutdown();
        expect(r.state, const Off(OffReason.user));
        expect(r.stored.state, ReceiveRuntimeState.on);
        expect(r.stored.cleanStop, isTrue);
        expect(r.clock.pending, 0);
        expect(r.gate.closes, 0, reason: 'the owner closes its own listener');

        final next = Rig(persisted: r.store.value);
        await next.controller.restore();
        expect(next.state, const Off(OffReason.user));
        expect(next.gate.opens, 0);

        // The same controller can serve a restarted owner...
        await r.controller.turnOn(const ReceiveAlways());
        expect(r.state, isA<On>());
        expect(r.stored.cleanStop, isFalse);
        // ...but not after dispose: operations are ignored, not errors.
        await r.controller.dispose();
        await r.controller.turnOn(const ReceiveAlways());
        expect(r.state, const Off(OffReason.user));
      },
    );

    test('dispose cancels timers and closes the streams', () async {
      final r = Rig();
      await r.controller.turnOn(const ReceiveFor(_h1));
      var done = false;
      r.controller.states.listen(null, onDone: () => done = true);
      await r.controller.dispose();
      await pumpEventQueue();
      expect(r.clock.pending, 0);
      expect(done, isTrue);
      await r.controller.dispose(); // idempotent
    });

    test('StateChanged carries the cause of each transition', () async {
      final r = Rig();
      await r.controller.turnOn(const ReceiveFor(_m10));
      await r.controller.platformTimeout();
      await r.controller.resume();
      await r.controller.turnOff();
      await pumpEventQueue();
      expect(
        [for (final e in r.eventsOf<StateChanged>()) e.cause],
        [
          ReceiveCause.turnOn, // Starting
          ReceiveCause.turnOn, // On
          ReceiveCause.platformTimeout,
          ReceiveCause.resume, // Starting
          ReceiveCause.resume, // On
          ReceiveCause.turnOff,
        ],
      );
    });

    test('a failing store never breaks the state machine', () async {
      final gate = FakeGate();
      final clock = ManualClock();
      final c = ReceiveController(
        gate: gate,
        store: _ThrowingStore(),
        clock: clock,
        scheduler: clock,
      );
      await c.turnOn(const ReceiveAlways());
      expect(c.state, isA<On>());
      await c.turnOff();
      expect(c.state, const Off(OffReason.user));
      await c.dispose();
    });
  });
}

class _ThrowingStore implements ReceiveSettingsStore {
  @override
  Future<ReceivePersisted> load() async => throw const FileSystemException('x');

  @override
  Future<void> save(ReceivePersisted data) async =>
      throw const FileSystemException('disk full');
}
