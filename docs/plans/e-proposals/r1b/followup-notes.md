# R1b follow-up: dispose-safe `_drive` backstop (2026-11-07)
Clone: .toolchain/scratch/e5-r1b-followup/clone (rsync of the current real tree). Real tree untouched. Only apps/libreshare_app/lib/providers/transfers_provider.dart changed (patch: followup-transfers-provider.diff, 1 section; `patch -p1 --dry-run` on a copy: rc=0).

Change: the `sub.asFuture().timeout(2s)` backstop in `TransfersNotifier._drive` is replaced by a Timer we own plus a Completer, raced with `sub.asFuture()` via `Future.any`; `ref.onDispose` cancels the Timer and completes the wait, the Timer is cancelled in `finally`, and it is only created while `ref.mounted`. After dispose `_drive` falls through to the existing `if (!ref.mounted) return;`. Mounted behaviour is unchanged (2 s backstop, `_finish` with the refusal code).
Caveat: Riverpod also runs onDispose callbacks when `build` re-runs (engine restart); a send still in its last 2 s backstop then ends that wait early and goes to `_finish` right away. Edge case, harmless.

Evidence (clone/apps/libreshare_app, `flock -o /tmp/libreshare-heavy.lock flutter test <file>`, TMPDIR=.toolchain/tmp, tools/env.sh; each rc echoed on the next line, 2026-11-07):
- d1b_sender_dialog_test x3: rc=0,0,0 (+7 each)
- d1v_retry_guard_test x3: rc=0,0,0 (+2 each)
- once each, all rc=0: d1b_engine_lifecycle (+14), d1b_listening_ports_helper (+2), d1b_pin_settings (+13), d1v_mode_save_fail (+1), d1v_retry_throw (+1), d1v_selector_snapback (+3), d1v_settings_save (+2), d1v_unmount_save (+1), transfer_screen (+20)
- `dart analyze --fatal-infos lib/providers/transfers_provider.dart`: rc=0; `dart format --output=none --set-exit-if-changed`: rc=0.
Not run: a red run of the unpatched clone (the orchestrator's bisect logs cover it); no whole suites. No test looked wrong.

## Round 2 (2026-11-07): no retained closure
`ref.onDispose` returns a RemoveListener; `_drive` keeps it (`removeDispose`) and calls it in the same `finally` as `timer.cancel()`, so after the wait no closure, Timer or Completer stays registered on the notifier. Diff regenerated against the current real tree (1 section, `patch -p1 --dry-run` rc=0; the real file differs from the clone only in this hunk).
Engine-restart case: Riverpod also runs onDispose callbacks when `build` re-runs (engine restart; the notifier instance stays). A send that is in its last 2 s backstop (its `send.result` already done, waiting for the event stream's done) then has the Timer cancelled and the wait ended at once, so `_drive` calls `_finish` immediately (still mounted) instead of up to 2 s later; any event not yet delivered by then is replaced by the result-based `_finish` data (success/reason/refusal from `send.result`). A send still awaiting `send.result` is unaffected.
Re-run (clone, flock -o /tmp/libreshare-heavy.lock, single files, 2026-11-07): d1b_sender_dialog x3 rc=0,0,0 (+7); d1v_retry_guard x3 rc=0,0,0 (+2); transfer_screen rc=0 (+20); d1b_engine_lifecycle +14, d1b_listening_ports_helper +2, d1b_pin_settings +13, d1v_mode_save_fail +1, d1v_retry_throw +1, d1v_selector_snapback +3, d1v_settings_save +2, d1v_unmount_save +1 all rc=0; `dart analyze --fatal-infos` file rc=0; `dart format --output=none --set-exit-if-changed` file rc=0.
