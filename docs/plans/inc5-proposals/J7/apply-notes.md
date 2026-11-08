# Apply Notes for Card J7: App UI (Create Link Sheet, Receive Link Dialog, Deep Links, Sleep Inhibitor)

## 1. Apply Patch
Apply `patch.diff` with `patch -p0 < docs/plans/inc5-proposals/J7/patch.diff` from the repo root to create:
- `apps/libreshare_app/lib/platform/sleep_inhibitor.dart`
- `apps/libreshare_app/lib/services/deep_link_handler.dart`
- `apps/libreshare_app/lib/widgets/create_link_sheet.dart`
- `apps/libreshare_app/lib/widgets/receive_link_dialog.dart`

## 2. Copy Test Files
```bash
cp docs/plans/inc5-proposals/J7/test/widgets/link_share_ui_test.dart apps/libreshare_app/test/widgets/
```

## 3. Dependencies
Requires `libreshare_core` Increment 5 modules (`ShareLink`, `b64urlEncode`).
