# A/B of the S4a receiver patch and persist cadence (current tree)

Clones of the current real tree in `.toolchain/scratch/speed-prof2/`: A = unchanged; B = A + `S4a/patch.diff` (applied cleanly with `patch -p1`, dry-run first); C = B + `kResumePersistEvery` 8 to 32 (only in `resume_store.dart`). Each run: 300 MiB loopback, `LS_C=3`, `flock -o /tmp/libreshare-heavy.lock`, bench `cmp` check. 6 interleaved pairs per profile, order alternating; no other work from me in between.

## Summary (MiB/s)
| comparison | median base (range) | median variant (range) | median ratio | median paired diff | pairs variant > base |
|---|---|---|---|---|---|
| B vs A secure | 73.6 (69.6-84.9) | 84.7 (68.2-93.4) | +15.0% | +6.9 | 5/6 |
| B vs A plain | 119.4 (102.0-127.8) | 97.5 (86.4-105.9) | -18.4% | -23.6 | 1/6 |
| C vs B secure | 77.0 (57.0-91.0) | 81.3 (71.0-88.6) | +5.7% | -0.9 | 3/6 |
| C vs B plain | 91.8 (66.2-103.9) | 103.5 (65.1-120.6) | +12.8% | +8.2 | 4/6 |

## Pair values (MiB/s; secure then plain)
| pair | AB secure A / B | AB plain A / B | BC secure B / C | BC plain B / C |
|---|---|---|---|---|
| p1 | 82.8 / 88.8 | 124.6 / 93.8 | 88.5 / 81.6 | 93.6 / 120.6 |
| p2 | 73.7 / 81.4 | 110.1 / 103.0 | 77.2 / 71.0 | 83.0 / 94.5 |
| p3 | 69.7 / 87.9 | 121.3 / 86.4 | 76.7 / 81.1 | 98.1 / 98.0 |
| p4 | 69.6 / 93.4 | 127.8 / 87.2 | 61.5 / 88.6 | 66.2 / 65.1 |
| p5 | 84.9 / 68.2 | 102.0 / 105.9 | 57.0 / 77.5 | 103.9 / 108.9 |
| p6 | 73.5 / 75.2 | 117.6 / 101.2 | 91.0 / 82.7 | 89.9 / 110.4 |

All 48 runs printed `Byte-identical (cmp verified)`.

## Verdicts
- **B (S4a) secure:** median +15% (84.7 vs 73.6), ranges overlap, B beat A in 5 of 6 pairs (median paired +6.9 MiB/s, about +9%). Suggestive, not beyond the noise. The estimated +20 to 35% from my profile is not supported.
- **B (S4a) plain:** -18% (97.5 vs 119.4); B lost in 5 of 6 pairs, median paired -23.6 MiB/s, ranges barely overlap. A real regression. Likely cause (hypothesis, not measured): plain pieces are already large (about 3 MB), so the patch serialises hash then write per chunk and allocates a 4 MiB buffer per chunk, losing the overlap of disk writes with network reads.
- **C (persist every 32) vs B:** secure +5.7% (median paired about 0, 3 of 6 positive); plain +12.8% (median paired +8.2, 4 of 6 positive, ranges 65 to 121). Neither is beyond the noise. The resume-bitmap cost is not a clear lever at this noise level.
- Correction to the profile report: `kResumePersistEvery` is already 8, so the 16 ms/chunk store cost is an average over persisting chunks, not a per-chunk fsync.

## Recommendation
1. Do not merge S4a as written: it regresses plain by about 18 to 24%.
2. If the buffering idea is kept, gate it on small pieces only (for example piece size below 64 KiB, the secure case) and write it as a new variant D with its own 6-pair A/B on both profiles before any decision.
3. Do not spend effort on persist cadence (C) for speed; it is within noise. Keep the resume crash-consistency cadence unless a crash test justifies changing it.
4. Run-to-run spread is about 20 to 40%, so any future claim needs interleaved pairs; single or three-run comparisons are not trustworthy.
