# ADR 0001: Flutter UI on a GUI-free pure-Dart core

- Status: accepted
- Date: 2026-11-03
- Spec: `docs/LIBRESHARE_BUILD_SPEC.md` sections 1, 1.1, 2, 10

## Context

LibreShare must ship on Windows, Linux and Android in one semester (macOS best effort, iOS stretch) and speak a LocalSend-style protocol: UDP multicast and mDNS discovery, HTTPS REST over mutually authenticated self-signed TLS, 4 MiB SHA-256-verified resumable chunks, and a tunnel fallback. The team builds with Claude Code in a headless Linux container with no GUI and no Wi-Fi radio, so every behaviour has to be reachable and verifiable without a screen.

Stack options compared in the spec (section 1.1): Flutter, Tauri 2 (Rust + web UI), Electron, Compose Multiplatform, .NET MAUI/Avalonia, React Native, Go (Wails/Fyne), Python, and a Rust/Go core with native UIs. Electron lacks Android; MAUI lacks Linux; React Native lacks Linux; Tauri's mobile features still need custom Swift/Kotlin plugins and Rust skills; a native-UI-per-platform design needs two to four UIs and does not fit a semester.

## Decision

1. Build the app with **Flutter 3.47 / Dart 3.13** (pinned to 3.47.9 / 3.13.7 in `.fvmrc`, `tools/env.sh` and CI).
2. Put all networking, crypto, chunking, session logic and fallback in **`packages/libreshare_core`, a pure-Dart package that never imports Flutter**. CI fails the build if `package:flutter` (or `dart:ui`) appears under `packages/libreshare_core/lib`.
3. Platform-specific code (bonsoir mDNS, Android foreground service and `MulticastLock`, MediaStore, secure storage, notifications) lives in `apps/libreshare_app/lib/platform/` and plugs into the core through interfaces (`Clock`, `FileSystem`, `SecretStore`, `MdnsBackend`, `TunnelProvider`).
4. Provide **`packages/libreshare_cli`** on top of the same engine so that two instances can transfer files on loopback and Docker networks in CI. UI and CLI use only `engine/libreshare_engine.dart`.
5. Use Dart pub workspaces for the monorepo; persistence is atomic JSON files plus a JSONL event log (no native database in the core).
6. Use `dart:io` (`HttpServer`, `HttpClient`, `RawDatagramSocket`) plus `shelf`, `crypto` and `cryptography`; defer a Rust core to a later optimisation (LocalSend shipped on pure Dart `shelf`/`dio` before moving networking to Rust).

## Consequences

- Positive: one codebase for three MVP platforms; LocalSend is a Flutter precedent; the whole protocol, security and fallback logic is covered by `dart test`, the CLI and Docker (including `tc netem` fault injection) without a GUI; the core can be reused by a different UI.
- Positive: the "core must not import Flutter" rule is mechanically enforced, which keeps platform code out of the protocol layer.
- Negative: pure-Dart hashing and TLS may fall short of gigabit speeds; mitigated by isolate hashing, parallel chunks and a benchmark gate (NFR-02), with a Rust-core ADR as the escape hatch.
- Negative: every platform capability needs an interface plus an adapter, which is more ceremony than calling plugins directly; accepted for testability.
- Negative: Flutter plugin maturity varies (file picker, foreground task, mobile scanner); versions must be re-checked with `pub outdated` each sprint, and the lockfile is committed.
- Tauri 2 (Rust + React) remains the documented alternative and Compose Multiplatform the second alternative if Flutter proves unworkable.
