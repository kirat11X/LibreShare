# tools/loopback_smoke.sh --secure fix (measured 2026-11-06, `date`)

Snapshot of the original: `.toolchain/snap/secure-smoke/loopback_smoke.sh.before`. Logs: `.toolchain/tmp/ssf.log`, `.toolchain/tmp/ssf2.log`. All runs under `flock -o /tmp/libreshare-heavy.lock`, `TMPDIR=$REPO/.toolchain/tmp`.

## Change (secure path only; plain branch lines untouched, test files untouched)
- Receiver and sender each get `--identity-dir` = fresh dirs (`$WORK/id-rx`, `$WORK/id-tx`) under the script's own `mktemp -d` (inside `$TMPDIR`), removed by the existing `cleanup` trap. `info` also uses the sender dir. Every run is a first contact; `~/.config/libreshare` is never read or written.
- Sender output is `tee`d to `$WORK/tx.log`. After the transfer the script extracts the `SAS ddd ddd` line of each side and exits 1 ("SAS check FAILED: ...", no digits in the message) unless both are 6-digit and equal. On success prints `SAS codes matched on both sides`. The 100 MiB `cmp` and the leftover check are kept.
- Flag verified with `ls receive --help`: `--identity-dir DIR`.

## Runs (command / rc / start time)
| command | rc | start |
|---|---|---|
| `tools/loopback_smoke.sh 1 53941 --secure` (dev check) | 0 | before the sequence |
| `tools/loopback_smoke.sh 100 53942` (plain) | 0, byte-identical | 2026-11-06 14:04:22 |
| `tools/loopback_smoke.sh 100 53943 --secure` | 0, SAS matched, byte-identical | 14:08:34 |
| `tools/loopback_smoke.sh 100 53944 --secure` | 0, same | 14:10:26 |
| `tools/loopback_smoke.sh 100 53945 --secure` | 0, same | 14:18:59 |
| `dart test test/loopback_smoke_secure_test.dart` run 1 | 0, `+2: All tests passed!` | 14:41:58 |
| same, run 2 | 0, `+2` | 15:07:37 |
| same, run 3 | 0, `+2` | 15:16:57 |
| negative: scratch copy (`.toolchain/tmp/neg_smoke.sh`) with receiver code forced to `000000`, `1 53950 --secure` | 1, "SAS check FAILED: the two codes differ" | 14:25:05 |

(Run 1 of the three test runs only started after waiting ~25 min on the shared lock.)

## ~/.config/libreshare (sha256, first 16 hex)
| file | before | after |
|---|---|---|
| contacts.json | 0f030bbe7683711a | 0f030bbe7683711a |
| identity.json | 5d7d4b5ec3d3b211 | 5d7d4b5ec3d3b211 |
Identical (rechecked at 20:46 after all runs). contacts.json mtime is the old 11:57:26 baseline; nothing there was edited or deleted.
