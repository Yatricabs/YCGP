# YATRI CABS Validation Status

## Automated checks completed

- `flutter pub get` completed successfully.
- `flutter analyze` passes with no Dart issues.
- `flutter build apk --debug --no-pub` completed successfully after the refactor.
- Android Gradle debug compilation completed successfully with Gradle 9.2.0.
- The refactored source has no stale references to the removed inline color, channel, or diagnostics implementations.
- Git whitespace validation passes with `git diff --check`.

## Emulator checks completed

- The current APK installed successfully on the Android emulator.
- The active ride notification was posted on `yatri_active_ride_v2` as an ongoing public foreground-service notification.
- Home navigation entered Android PiP: the task reported `mode=pinned` and `mLastReportedPictureInPictureMode=true`.
- The diagnostics viewer is reachable from Ride Options and the settings icon.

## Manual phone checks still required

These depend on hardware, OEM settings, or a long-running ride and cannot be claimed from the emulator alone:

1. Receive a phone call during an active ride and verify distance continues.
2. Lock the screen on the target phone and verify the YATRI notification remains visible and GPS updates continue.
3. Remove YATRI from Recents and verify the foreground service remains active.
4. Pick a SAF folder, uninstall/reinstall, re-pick the folder, and verify ride recovery from the backup JSON.
5. Simulate a long GPS signal gap and verify watchdog recovery.
6. Validate Xiaomi/Redmi/POCO, OPPO/realme, Samsung, OnePlus, vivo, and Lava battery-management behavior where those devices are part of deployment.

## Known build warnings

The build succeeds, but Flutter currently reports compatibility warnings for:

- Kotlin Gradle Plugin `2.2.20`, which Flutter says will soon require `2.3.20`.
- The third-party `floating` plugin, which still applies the legacy Kotlin Gradle plugin and uses a deprecated Android PiP API.
- Android SDK command-line tools reporting an SDK XML version mismatch.

The app source builds successfully; these warnings are tracked in `BUILD_TOOLCHAIN.md` and require upstream/plugin or local SDK updates rather than a Dart behavior change.
