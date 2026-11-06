# apply-notes R1c/R1d
- Conflicts: none expected with R1a/R1b (different files). patch.diff dry-run applies cleanly to the real tree (rc=0).
- Windows launcher contract (rundll32 url.dll,FileProtocolHandler <path>; explorer.exe /select, <path> as separate argv; '/' -> '\') is UNVERIFIED on a real Windows host: accepted by orchestrator as in tests-plan.md, check at step 8 of docs/test-reports/windows-manual.md.
- isPathWithin is already exported (barrel exports filename_sanitizer.dart whole): no barrel change needed. The app does not use it.
- Behaviour on Linux/Android unchanged (launcher regression tests green; sanitizer/fuzz suites green in full core run).
- New test files (copies here): e5_paths_windows_test.dart, e5_file_launcher_command_test.dart, path_within_windows_test.dart. Copy them into apps/libreshare_app/test/ and packages/libreshare_core/test/unit/.
