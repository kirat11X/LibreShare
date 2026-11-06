# Card F3 Apply Notes: Notifications Logic & Seam

## Dependency Request for Orchestrator
To wire real platform notifications, the orchestrator should add the following dependency to `apps/libreshare_app/pubspec.yaml`:

```yaml
dependencies:
  flutter_local_notifications: ^17.2.3  # BSD-3-Clause
```

### Android Configuration Requirements
1. **Permissions (`AndroidManifest.xml`)**:
   ```xml
   <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
   <uses-permission android:name="android.permission.VIBRATE"/>
   ```
2. **Core Library Desugaring**:
   If Java 8+ APIs (such as `java.time`) are required by modern notification libraries, ensure `coreLibraryDesugaringEnabled = true` in `android/app/build.gradle`.
3. **Notification Channels**:
   - Channel ID: `dev.libreshare.transfers`
   - Name: "LibreShare Transfers"
   - Importance: High (with heads-up prompt for incoming transfer consent).

### Proposed Target Locations for Patch
- `apps/libreshare_app/lib/platform/notifications/notification_service.dart`
- `apps/libreshare_app/lib/providers/notification_provider.dart`
- `apps/libreshare_app/test/notifications_test.dart`
