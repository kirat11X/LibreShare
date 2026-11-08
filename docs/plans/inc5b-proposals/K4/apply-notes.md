# Card K4 Apply Notes

## Summary
Introduces CLI flags (`--hide-ip`, `--port-map`) and disclosure notices in `ls_cli.dart`, updates firewall rules in `docs/user/guide.md` to cover direct origin range 53330-53349, and validates the `CreateLinkSheet` toggle and disclosure UI.

## Target Files
- `docs/user/guide.md`
- `packages/libreshare_cli/lib/ls_cli.dart`
- `packages/libreshare_cli/test/link_hide_ip_test.dart`
- `apps/libreshare_app/test/widgets/hide_my_ip_test.dart`

## Application Instructions
```bash
patch -p1 < docs/plans/inc5b-proposals/K4/patch.diff
cp docs/plans/inc5b-proposals/K4/test/cli/link_hide_ip_test.dart packages/libreshare_cli/test/
cp docs/plans/inc5b-proposals/K4/test/widgets/hide_my_ip_test.dart apps/libreshare_app/test/widgets/
```

## Verification Steps
```bash
dart analyze --fatal-infos packages/libreshare_cli/lib/ apps/libreshare_app/lib/
dart test packages/libreshare_cli/test/link_hide_ip_test.dart
flutter test --no-pub apps/libreshare_app/test/widgets/hide_my_ip_test.dart
```
