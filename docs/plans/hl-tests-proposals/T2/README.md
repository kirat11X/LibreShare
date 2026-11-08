# Card T2: CLI End-to-End Matrix Integration Suite

## Purpose
A black-box integration test matrix verifying the compiled `ls` command-line binary (`bin/main.dart`) across realistic, adversarial, and edge-case transfer scenarios.

## Destination in Real Tree
`packages/libreshare_cli/test/cli_matrix_e2e_test.dart`

## Test Matrix Coverage
1. **Matrix 1 (Boundary Sizes):** 0-byte file, 1 KiB file, 4 MiB - 1 B file, 4 MiB + 1 B chunk boundary file. Byte-for-byte SHA-256 verification and leftover temp file cleanup verification.
2. **Matrix 2 (Unicode & Emoji Trees):** Nested directory paths with emoji (`📁_fotos`), Japanese (`2026_日本語/富士山.txt`), and right-to-left Arabic script (`العربية.pdf`).
3. **Matrix 3 (Collisions):** Pre-existing file with the same name (`conflict.txt`) triggers safe non-destructive collision renaming (`conflict (1).txt`) preserving both files intact.
4. **Matrix 4 (Windows Reserved & Trailing Dots):** Windows DOS 8.3 device name (`CON.txt`) and trailing dots (`foo...`) sanitized safely to `_CON.txt` and `foo`.
5. **Matrix 5 (PIN Authentication):** Receiver with mandatory `--pin 481920`. Bad PIN `000000` exits with rc=82 (`EX_NOPERM`). Correct PIN `481920` exits with rc=0.
6. **Matrix 6 (Consent & Unattended):** Receiver without `--auto-accept` when stdin is closed declines consent cleanly; sender exits with non-zero failure code without hanging.
