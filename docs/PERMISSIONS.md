# Android permissions audit (S5, plan Т-5.1)

Invariant S5: dangerous permissions only where a feature needs them. This
document maps every `uses-permission` in the shipped manifest to the code that
consumes it, the feature flag it belongs to, and the verdict for store builds
(foss / google / cut).

State at the time of writing: a single manifest, no product flavors
(`android/app/build.gradle.kts` comment for Т-0.2: the `oneme` flavor was
removed; `foss` is the base mode without FCM, per plan Phase 6). Backend
feature gating exists in Dart as `Capabilities`
(`lib/core/backends/capabilities.dart`) — per-network message capabilities —
but no `FEATURE_NFC_BLE` / `FEATURE_GEO`-style product flags exist in the
codebase yet; those belong to Komet features that are not ported (manifest
comment, Phase 3+). Where the table says «flag — none yet», the flag column
records the future owner of the permission so it is cut when the flag is off.

## Manifest inventory

Effective manifest: `android/app/src/main/AndroidManifest.xml` (the only
manifest; `AndroidManifest-connection.xml` is the standalone snippet that was
merged into it by Т-0.1/Т-0.2 and is kept for history — its permission set is
identical to the live one).

Aapt-style check (grep `uses-permission` over `android/app/src/main/`):

```
$ grep -rh 'uses-permission' android/app/src/main/AndroidManifest*.xml | sort -u
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_REMOTE_MESSAGING"/>
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
<uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"/>
```

7 distinct permissions, all normal/install class (none are runtime dangerous
permissions; POST_NOTIFICATIONS is the only runtime one and the app never
requests it at runtime yet — see table).

## Permission → consumer → flag → verdict

| # | Permission | Class | Code consumer (grep evidence) | Feature / flag | Verdict |
|---|-----------|-------|------------------------------|----------------|---------|
| 1 | `INTERNET` | normal | TDLib FFI client opens `libtdjson` and exchanges traffic: `lib/core/backends/telegram/td_ffi_client.dart` (`DynamicLibrary.open`, send/receive loop). MAX kolibri transport is the other future consumer. | Base connectivity — every build | **нужно в foss и google** (без него мессенджер не работает) |
| 2 | `ACCESS_NETWORK_STATE` | normal | `ConnectionForegroundService.registerNetworkCallback()` (`android/.../ConnectionForegroundService.kt`, `ConnectivityManager.registerDefaultNetworkCallback`, `NET_CAPABILITY_VALIDATED`) — resets the reconnect backoff when connectivity returns. | Core connection (Т-1.9 FGS) — same flag as #1 | **нужно в foss и google** (reconnect policy; companion of INTERNET) |
| 3 | `POST_NOTIFICATIONS` | runtime (API 33+) | Foreground-service status notification: `ConnectionNotification.build()` builds the ongoing «N аккаунтов подключено» + «Пауза» notification; `ConnectionForegroundService.goForeground()` posts it via `startForeground`. FGS notifications are exempt from POST_NOTIFICATIONS on API 33+, but the permission keeps the channel visible if the user muted FGS. No `requestPermissions()` call exists anywhere in `android/` yet — the app relies on the FGS exemption; the runtime ask belongs to a later UI task. | Core connection (Т-1.9) | **нужно в foss и google**, но с оговоркой: пока ни один вызов не требует runtime-запроса (FGS-exempt); когда появится UI-спрос — оставить только для foss/google сборок с каналом соединения |
| 4 | `FOREGROUND_SERVICE` | normal | `ConnectionForegroundService` (`foregroundServiceType="remoteMessaging"`) holds the process and the background Flutter engine (`ConnectionEngine`) alive under Doze. | Core connection (Т-1.9) | **нужно в foss и google** (это ядро гарантии доставки в фоне) |
| 5 | `FOREGROUND_SERVICE_REMOTE_MESSAGING` | normal (API 34+) | Same service: `goForeground()` passes `ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING` on API 34+; manifest declares the matching typed permission. | Core connection (Т-1.9) | **нужно в foss и google** (обязательное типизированное разрешение для #4 при targetSdk 34+) |
| 6 | `RECEIVE_BOOT_COMPLETED` | normal | `ConnectionBootReceiver` (`ConnectionForegroundService.kt`, class at line ~190) restarts the FGS on `ACTION_BOOT_COMPLETED`. | Core connection (Т-1.9) | **нужно в foss и google** (автостарт после ребута — та же фича; в google-сборке Play оценивает user-visible выгоду, выгода описана в FGS-нотификации) |
| 7 | `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | normal (appop-guarded) | **Код-потребитель отсутствует.** No `isIgnoringBatteryOptimizations`, no `Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`, no PowerManager usage anywhere in `android/app/src/main/kotlin/` or `lib/` (grep over the tree returns only the two manifest lines). The FGS comment in `ConnectionEngine.kt` mentions Doze as the *reason* the service exists, but the exemption-ask itself was never implemented. | Core connection (Т-1.9) — would be the same flag | **вырезать из store-сборок сейчас**: заявлен, но не используется. Play policy actively restricts this permission (needs a core-feature justification + declaration form); shipping it unused risks a review rejection. Re-add only when a real «запросить исключение из Doze» screen lands, and then only in google build (foss users can enable it manually in settings; battery-optimization asks violate the foss spirit) |

## Permissions from the plan §3.1 that are NOT in the manifest

The plan's long list (`CAMERA`, `RECORD_AUDIO`, `LOCATION`, `BLUETOOTH`, `NFC`,
`REQUEST_INSTALL_PACKAGES`, …) is the Komet upstream surface (manifest comment:
«Komet-специфика (NFC HCE, deep links, FCM, upload/call services) не
переносится — это Фаза 3+»). None of these appear in the wellmagram manifest,
and none should be added until the corresponding feature flag exists
(`FEATURE_NFC_BLE`, `FEATURE_GEO`, `FEATURE_CALLS`…) — that is exactly the S5
invariant this table will enforce going forward. `Capabilities.pushRegistration`
(the only push-related flag today) is `false` for Telegram and unused by any
manifest permission — FCM is not wired (Phase 6).

## Summary for store builds

- Keep in both foss and google: `INTERNET`, `ACCESS_NETWORK_STATE`,
  `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_REMOTE_MESSAGING`,
  `RECEIVE_BOOT_COMPLETED`, `POST_NOTIFICATIONS` (all backed by the Т-1.9
  connection service, all with concrete code consumers).
- Cut now: `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` (declared, zero code
  consumers, Play-policy risk). Removing it is a one-line manifest deletion,
  safe: nothing references it.
- When flavors land (Phase 6, foss/google split), this table is the source of
  truth: a permission whose flag is off must be absent from that flavor's
  manifest.
