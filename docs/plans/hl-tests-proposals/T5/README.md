# Card T5: Soak & Stress Reliability Suite

## Purpose
Long-running load and soak tests proving memory bounds, session concurrency, descriptor recycling, and event-stream integrity under sustained multi-file stress.

## Destinations in Real Tree
- `packages/libreshare_core/test/integration/soak_stress_test.dart`
- `packages/libreshare_core/test/integration/soak_rss_child.dart`

## Key Capabilities Tested
1. **1,000 Tiny Files in a Single Session:** Tests manifest scaling and stream pipe efficiency over 1,000 discrete file transfers. Asserts byte parity and confirms 0 leftover `.part` or `.tmp` files.
2. **Concurrent Fan-In (10 Senders to 1 Receiver):** 10 distinct sender engines concurrently initiate and complete transfers to a single receiver. Validates server socket multiplexing and proves event-stream integrity (exactly 10 `SessionFinished(success: true)` terminal events).
3. **50 Sequential Sessions of 10 Files (500 files total):** Tests descriptor and port recycling across back-to-back transfer sessions.
4. **Child Process RSS Growth Bound (< 150 MB over 1 GiB):** Uses dedicated isolated child process (`soak_rss_child.dart`) to measure heap and native memory growth over a 1 GiB loopback transfer. Actual measured growth: **~68 MB to ~86 MB** (well below the 150 MB bound).
