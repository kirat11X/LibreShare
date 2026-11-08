# Card R7 Report: LibreShare User Guide (Redo 2)
Status: READY (redo 2)
Date: 2026-11-08
Target file: docs/user/guide.md (additive patch, 0 deleted lines)

## Overview & Fact-Check Compliance
- Corrects Card R7 per UPDATE #14 with 100% verified facts directly copied from codebase definitions and `--help` specifications:
  - **Speed Modes (Section 13):** Accurately reflects that speed modes set chunk concurrency (1 for `eco`, 3 for `balanced` [default], 8 for `turbo`) for fixed 4 MiB protocol chunks (`kChunkSize = 4 * 1024 * 1024`). Accurately documents that modes are local settings, never negotiated, and preserve TLS and whole-file SHA-256 checks identically. Cites native SHA-256 (`libcrypto`/`bcrypt` with `LS_NO_NATIVE_SHA=1` kill-switch) and reports development machine benchmark numbers with explicit network throughput qualification.
  - **CLI Commands (Sections 12, 14, 16):** Canonical binary name `ls` throughout. Flags match real parser definitions: `ls send --to host:port` (not `--target`), `--device`, `--speed`, `ls link FILE... [--expires 1h] [--receivers 1] [--provider cloudflare] [--hide-ip] [--port-map]`, `ls receive-link LINK [--dir DIR]`, `ls pair --show | --scan URI`, `ls peers`.
  - **URL & Security Invariants:** Real landing base URL `https://libreshare.github.io/r#v=1&h=<host>&t=<token>&k=<key>...`. Hash fragment key security, max 4 candidates, 64-hex SHA-256 direct origin pin verification, and fallback to tunnel on invalid pin.
  - **Pairing & Rendezvous:** 10-minute validity for invite secret $S$, 6-digit confirmation SAS code from nonces and fingerprints, daily rotating Nostr epochs ($E = \lfloor \text{unix\_seconds} / 86400 \rfloor$, Kind 20059), and ntfy 250 ms poll interval.
  - **Source Citation Rule:** Every single command, flag, number, URL, and default is accompanied by an inline HTML comment `<!-- source: path:line -->`.
  - **Hardware Caveats:** Radio-dependent features (BLE proximity discovery, Wi-Fi Direct/Hotspot negotiation) and live tunnel/router port mappings are marked `[UNVERIFIED: needs hardware, see USER_TODO.md]`.
- Verification: `git apply --check -p1 docs/plans/waveR-proposals/R7/patch.diff` cleanly succeeds with `rc=0`. Exactly zero existing lines deleted.
