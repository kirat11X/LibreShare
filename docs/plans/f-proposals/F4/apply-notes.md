# Card F4 Apply Notes: Android Background Receive Service

## Manifest Changes (`AndroidManifest.xml`)
Add the following permissions and service definitions to `apps/libreshare_app/android/app/src/main/AndroidManifest.xml`:

```xml
<!-- Foreground service permissions for background reception -->
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />
<uses-permission android:name="android.permission.WAKE_LOCK" />

<application ...>
    <!-- Background Receive Foreground Service -->
    <service
        android:name=".ReceiveService"
        android:exported="false"
        android:foregroundServiceType="connectedDevice|dataSync" />

    <!-- Quick Settings Tile -->
    <service
        android:name=".ReceiveTileService"
        android:exported="true"
        android:permission="android.permission.BIND_QUICK_SETTINGS_TILE">
        <intent-filter>
            <action android:name="android.service.quicksettings.action.QS_TILE" />
        </intent-filter>
    </service>
</application>
```

### Security & Privacy Rules Maintained
1. `ReceiveService` is strictly `android:exported="false"`.
2. `ReceiveTileService` requires `android.permission.BIND_QUICK_SETTINGS_TILE` and is `exported="true"` as required by Android OS SystemUI.
3. `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` is deliberately omitted (Google Play policy compliance).
4. `usesCleartextTraffic` is left untouched.
