# Contributing to LibreShare

Thank you for your interest in contributing to LibreShare! LibreShare is a free, open-source peer-to-peer file sharing application licensed under the MIT License.

This guide outlines our development workflow, architectural boundaries, and coding standards.

---

## 1. Golden Architectural Rule: Pure-Dart Core

The core protocol and networking library (`packages/libreshare_core`) is strictly headless and GUI-independent.

- **Never import Flutter in the core:** `packages/libreshare_core/lib` must **NEVER** import `package:flutter` or `dart:ui`.
- **Automated Verification:** Every build verifies this invariant:
  ```bash
  grep -RnE "package:flutter|dart:ui" packages/libreshare_core/lib
  # Must exit with rc=1 (no matches)
  ```
- **Logging Rule:** Do not use `print()` in `packages/libreshare_core/lib`. Use `package:logging` instead. (The CLI package `packages/libreshare_cli` uses `print()` intentionally for console output.)

---

## 2. Test-First Development (TDD)

All contributions must follow test-driven practices:

1. **Write failing tests first:** Before implementing logic or bugfixes, add failing tests that prove the defect or define the new contract. Verify that they fail for the intended reason.
2. **Never weaken or modify existing acceptance tests:** Pre-existing tests under `test/` represent stable contracts. You may add new test files, but existing assertions must not be relaxed or deleted.
3. **Security-critical code requires verification:** Any modification touching crypto, authentication, TLS, trust store, PIN guard, path sanitization, or `file_receiver.dart` requires negative test cases, mutation testing (verifying that removing guards causes test failure), and multi-agent review.

---

## 3. Coding Style and Verification

Before submitting any changes, verify that your code adheres to project standards:

- **Environment:** Always source the project environment first:
  ```bash
  source tools/env.sh
  ```
- **Code Formatting:**
  ```bash
  dart format --output=none --set-exit-if-changed .
  ```
- **Static Analysis:**
  ```bash
  dart analyze --fatal-infos
  # Must report zero errors, warnings, or infos
  ```
- **Run Test Suites:**
  ```bash
  # Core tests (pure Dart)
  (cd packages/libreshare_core && dart test -j 1)

  # CLI tests
  (cd packages/libreshare_cli && dart test -j 1)

  # Flutter app tests
  (cd apps/libreshare_app && flutter test --concurrency=2)
  ```

---

## 4. Submitting changes

- **Pull requests or patches:** open a pull request from a branch of your fork, or send a unified diff (`git diff` or `diff -ruN`). Keep one topic per change and include the tests that go with it.
- **Before you submit:** run the formatting, analysis and test commands of section 3 and say in the description which of them you ran and their results.
- **Protocol changes:** a change to the wire protocol must update `docs/protocol/LSP-1.md`, the JSON schemas and the conformance tests together.
- **Zero secret ingestion:** never commit or submit signing keystores (`*.jks`, `*.keystore`), `key.properties`, `local.properties`, private keys, PINs, tokens, or live credentials. All test keys must be throw-away synthetic fixtures.
