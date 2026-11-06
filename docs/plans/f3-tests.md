# F3 tests (hand-over, tester -> coder)

All files under `apps/libreshare_app/test/`. Helpers: `helpers/f3_fakes.dart`. Validated against a throw-away prototype of the fixes (scratchpad copy, not in the repo): all new tests pass there; 7 mutations each turned a file red.

## Files and groups
| File | Group |
|---|---|
| `f3_format_test.dart` | decimal `formatBytes`/`formatSpeed` table, rollover, negatives; source scan "no other lib file divides by 1000/1024 or uses unit keys"; 4 UI places (transfer waiting/progress/done, Send screen) |
| `f3_failure_text_test.dart` | existing-API only: start text kept, all reasons plain (no exception/hex64/trace), real engine: unreachable peer, peer killed mid-transfer |
| `f3_failure_lost_test.dart` | `wasTransferring` -> "connection lost" text, other reasons unchanged, widget |
| `f3_device_identity_test.dart` | `resolveDeviceAlias` (Android channel, fallbacks, trim, 64-cp cut, emoji, desktop unchanged) |
| `f3_alias_store_test.dart` | typed name wins over default (green today, guard) |
| `platform/f3_file_opener_test.dart` | `AndroidFileLauncher` channel calls, false/throw/missing/non-bool, `createFileLauncher`, completion screen with it |
| `f3_saved_location_function_test.dart` | `describeSavedLocation` table |
| `f3_saved_location_test.dart` | `transfer-saved-location` line, fallback snackbar (Open and Show in folder), throwing launcher |
| `f3_storage_prompt_test.dart` | first-Receive prompt on Android: Keep / Choose, never again (same run, restart), Settings card, not-Android, folder already set |
| `f3_device_address_test.dart` | manual device keeps address vs foreign multicast sighting; re-add confirms new; announced device follows latest |
| `f3_home_layout_test.dart` | empty Home: FAB vs 3 empty-state buttons, heights 560-1400 at scale 1.0/1.3, plus required 360x640 |

## New symbols (minimal signatures)
- `services/format.dart`: `formatBytes(num)` convention: decimal (1 KB = 1000 B), units B/KB/MB/GB/TB, B whole, others 2 decimals below 10 and 1 decimal from 10, value rounding to 1000 moves up a unit, negative -> "0 B". `formatSpeed` uses it.
- `services/device_identity.dart`: `const kDeviceInfoChannel = 'dev.libreshare/device_info'; const kAndroidFallbackAlias = 'Android phone'; Future<String> resolveDeviceAlias({bool? isAndroid, MethodChannel? channel, String Function()? hostname})`. `main()` must pass `defaultAlias: await resolveDeviceAlias()` to `loadOrCreate`.
- `services/file_launcher.dart`: `const kFileOpenerChannel = 'dev.libreshare/file_opener'; class AndroidFileLauncher implements FileLauncher { AndroidFileLauncher({MethodChannel? channel}); }` (never throws); `FileLauncher createFileLauncher({required bool isAndroid, MethodChannel? channel})`; `fileLauncherProvider` default uses it with `Platform.isAndroid`.
- `services/paths.dart`: `String describeSavedLocation(String folderPath)` (public roots `/storage/emulated/<n>/`, `/storage/self/primary/`, `/sdcard/` + FIRST segment Download|Documents|Pictures|DCIM|Music|Movies; Download -> "Downloads"; else path unchanged).
- `providers/platform_providers.dart`: `final isAndroidProvider = Provider<bool>((ref) => Platform.isAndroid)` (must NOT use `defaultTargetPlatform`: flutter_test says Android).
- `providers/transfers_provider.dart`: `TransferView({..., bool wasTransferring = false})` + `copyWith(wasTransferring:)`; set true when data starts moving (first progress / accepted). `failureText`: `noConnection` + flag -> new key (text below).
- `AppSettings`: one persisted bool "storage question answered" (default false, survives restart).
- Widget keys: `storage-prompt` (root), `storage-prompt-choose` ("Choose a folder"), `storage-prompt-keep` ("Keep default"), `transfer-saved-location` (Text, only for received transfers with saved files; text contains `describeSavedLocation(savedFolder)`).
- Texts: lost = `The connection to {peer} was lost. Keep both apps open and on the same Wi-Fi, then try again.`; start text unchanged. Prompt must contain the default folder path. Fallback `Could not open it here. The file is saved at {path}` unchanged (file path for Open, folder for Show in folder); a throwing launcher must give it too.
- Behaviour: prompt appears BEFORE Receive turns on (Receive Off while it is open); Android + `downloadDir == null` + not answered only; Keep or Choose both mark answered and Receive then turns on; Choose = existing `pickDirectory` then `setDownloadDir`.
- Core `PeerRegistry.seen`: a manual/qr entry keeps its address (and source) when a non-manual source reports another address; a manual/qr sighting still replaces it. Other devices still follow the latest address.
- Home: list viewport must end above the FAB (e.g. body bottom padding) so no empty-state button is ever visible under it.

## Kotlin channel contracts (not unit-testable here)
- `dev.libreshare/device_info`, method `deviceName`, no args -> String? : `Settings.Global.getString(contentResolver, "device_name")`, else `Build.MODEL`; null/empty allowed; no exception for a missing setting. Register in `MainActivity.configureFlutterEngine` like `MulticastLockChannel`.
- `dev.libreshare/file_opener`, args `{ "path": String }` (the saved FILE path), answer `true` only if an activity was started:
  - `open`: content Uri via FileProvider (declare provider `${applicationId}.fileprovider`, paths: external-path "." and external-files-path "."), MIME from extension (fallback `*/*`), `ACTION_VIEW`, `FLAG_GRANT_READ_URI_PERMISSION | FLAG_ACTIVITY_NEW_TASK`; `false` if the file is missing or `ActivityNotFoundException`.
  - `showInFolder`: open the parent folder: `ACTION_VIEW` with the DocumentsContract uri of the folder (`content://com.android.externalstorage.documents/document/primary%3A<relative dir>`, type `vnd.android.document/directory`), fallback `DownloadManager.ACTION_VIEW_DOWNLOADS` for paths under Download; `false` if none resolves.
  - Unexpected failures: `result.error(code, message, null)` (Dart treats it as false). No new storage permission.

## Red state on the real tree
| File | State |
|---|---|
| format (22), failure_text (mid-transfer e2e, 1), saved_location (5), device_address (2), home_layout (1: scale 1.0 sweep; scale 1.3 and 360x640 pass today) | red on behaviour |
| device_identity, failure_lost, file_opener, saved_location_function, storage_prompt | compile error: only the new symbols above |
| alias_store, rest of format/failure_text/address/layout | green guards |

## SPEC-GAPs
1. Decimal convention changes values asserted by EXISTING tests (their owner must update them; I did not touch them): `incoming_test.dart:72` "4.9 KB" -> "5.00 KB"; `send_flow_test.dart:52` "294 KB" -> "301.0 KB"; `transfer_screen_test.dart` 151 "2.0 MB" -> "2.10 MB", 181 "1.0 MB / 2.0 MB" -> "1.05 MB / 2.10 MB", 182 "1.0 MB/s" -> "1.05 MB/s", 193 "512 KB / 1.0 MB" -> "524.3 KB / 1.05 MB", 212 "512 KB/s" -> "524.3 KB/s", 228 "10.0 MB/s" -> "10.5 MB/s".
2. Existing transfer-screen test keeps default views (progress > 0, `wasTransferring` false) expecting "Could not reach": that is why the discriminator is a new field, not `bytesDone`.
3. Incoming transfer + `noConnection` still says "Could not reach" (nonsense for a receiver); not tested.
4. Picker cancelled after "Choose a folder", dismissing the prompt by tapping outside, tray toggle and Resume paths: not specified, not tested.
5. A persisted alias "localhost" from an old install is not migrated (cannot tell it from a typed name).
6. At 360x640 with test fonts there is no overlap today (fonts are wider than a phone's); the sweep to 1400 dp is what reproduces defect 10.
7. Selection of `AndroidFileLauncher` by `Platform.isAndroid` and `main()` wiring are not testable here.

## Recommended mutation checks
Asked-flag never saved; `describeSavedLocation` matching "Download" anywhere; no unit rollover; launcher returning true on error; flag ignored in `failureText`; registry exemption off; FAB padding 0; trim after truncate in `resolveDeviceAlias`; prompt shown after Receive on.

Full app suite on the real tree (`--concurrency=2`, alone): +269 passed, -36 failed (31 behaviour reds + 5 compile errors); every failure is in an f3 file, all 249 existing tests pass.
