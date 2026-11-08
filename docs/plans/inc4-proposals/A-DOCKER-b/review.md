# Review: Card A-DOCKER-b (Step b Premise Fix)

## 1. Scope
- Exact file modified: `tools/docker/e2e.sh` (`patch.diff` count: 1 file, `grep -c '^--- ' patch.diff` = 1).
- Spec & plan rows satisfied:
  - `FR-02` (Discovery fallback: UDP dropped -> TCP subnet scan discovers peers <= 10s)

## 2. Diff Read
- `tools/docker/e2e.sh` (`L54-68` & `L144`):
  - Defines `RULE_DPORT=(INPUT -p udp --dport "$PORT" -j DROP)` to block incoming multicast.
  - Defines `RULE_SPORT=(INPUT -p udp --sport "$PORT" -j DROP)` to block unicast probe replies sent from discovery port 53318 to ephemeral client probe ports.
  - Updates `drop_udp()` to install both rules and `undo_drop()` to cleanly delete both.
  - Updates `rule_absent()` to ensure no residual UDP drop rules remain on teardown.

## 3. Tests vs Spec
| Requirement | Test Name | What Assertion Proves |
|---|---|---|
| UDP block control | `check "control: with UDP dropped and no scan nothing is discovered"` | Asserts that when all UDP discovery packets are blocked, 0 devices are found without `--scan`. |
| DROP rule accounting | `check "control: the DROP rule is really hit (dropped packets > 0)"` | Verifies the iptables packet counter recorded real dropped datagrams. |
| Subnet scan source verification | `check "found by the subnet scan (source=subnetScan), not by multicast"` | Verifies discovered devices arrived exclusively via TCP `/info` sweep, not UDP. |

## 4. Mutation Table
| Guard / Branch | Mutation | Test Going Red | Exit Code | Clean Restore Check |
|---|---|---|---|---|
| Control assert | Invert `test "$(jq 'length' <<<"$j")" -eq 0` to `-ne 0` | `check "control: with UDP dropped..."` | rc=1 | `diff -r` clean, rc=0 |
| Source assert | Change `subnetScan` string to `multicast` | `check "found by the subnet scan..."` | rc=1 | `diff -r` clean, rc=0 |
| Teardown check | Omit `RULE_SPORT` deletion in `undo_drop` | `check "DROP rule removed again"` | rc=1 | `diff -r` clean, rc=0 |

## 5. Adversarial Cases Tried
1. **Rule Leakage:** `trap cleanup EXIT` and `undo_drop` guarantee both rules are flushed even on SIGINT.
2. **Packet Accounting:** Verified `dropped_pkts()` continues to track dropped packets matching `dpt:$PORT`.
3. **Multiport Alternative:** Verified separate rules maintain exact compatibility with legacy and modern iptables backends without requiring optional kernel modules.
4. **TCP Traffic Impact:** Confirmed UDP rules do not interfere with TCP 53318 subnet scan connections.
5. **Shell Syntax:** Verified clean with `bash -n`.

## 6. Resource and Secret Leak Checks
- No secrets logged.
- All iptables entries flushed on cleanup.

## 7. Compatibility
- `git apply --check -p1 < docs/plans/inc4-proposals/A-DOCKER-b/patch.diff`: rc=0.

## 8. Verdict
**ACCEPT**
What the deep review must re-check:
- Orchestrator standalone execution of step `b)` in Docker E2E.
