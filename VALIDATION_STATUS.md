# YATRI CABS v1.0.5+6 — Validation Status

## Completed in this packaging environment

- Source tree unpacked and inspected from the v36 baseline.
- Removed the custom `afterEvaluate { tasks.named("assembleRelease") ... }` APK-copy hook.
- Verified the Gradle wrapper configuration points to Gradle 8.12.
- Verified Android manifest declares a `location` Foreground Service and the required foreground-service/location permissions.
- Verified the native service notification uses a bundled drawable small icon and an immutable `PendingIntent`.
- Verified active-ride service/task-removal/PiP communication code is present.
- Verified documentation files are present and updated.
- Verified the output archive with `unzip -t` after packaging.
- Replaced the CI `flutter build apk --release` step with direct Gradle 8.12 `:app:assembleRelease`, explicit APK discovery, and branch-specific artifact upload.
- Fixed CI workflow references to a missing `android/gradlew` wrapper script; the project uses the GitHub Actions Gradle 8.12 installation directly.
- CI generates/verifies the Gradle 8.12 Wrapper and invokes `./gradlew :app:assembleRelease` from `android/`.
- Updated documentation for the new CI build path.

## Not executed here

- Flutter package resolution (`flutter pub get`).
- Dart static analysis (`flutter analyze`).
- Release APK compilation in this packaging environment (Flutter/Android SDK unavailable). The repository CI workflow now performs `gradle :app:assembleRelease` with Gradle 8.12.
- Installation on a physical Android phone.
- Xiaomi/Redmi/POCO, OPPO/realme, Samsung, OnePlus, vivo, Lava, or Android Go OEM behavior tests.

The reason is environmental: this working container does not provide the Flutter SDK, Android SDK/ADB, emulator, or connected physical device. No claim is made that these tests passed.

## Required release-gate tests

1. Build the release APK using the repository CI workflow or `gradle :app:assembleRelease`.
2. Install the release APK.
3. Start an active ride while the app is visible.
4. Confirm the ongoing YATRI active-ride notification appears.
5. Lock the screen and verify real GPS distance continues.
6. Enter PiP and verify the service continues.
7. Use Back during the ride and verify PiP rather than ride closure.
8. Remove the task from Recents and verify the service/notification behavior.
9. Simulate GPS signal loss and recovery.
10. End the ride and verify the foreground service, GPS listener, and notification stop cleanly.
11. Repeat on representative OEM devices, especially Xiaomi/Redmi/POCO.

## Gradle Wrapper packaging note (v40)

- `android/gradlew` and `android/gradlew.bat` are now present.
- `gradle-wrapper.properties` remains pinned to Gradle 8.12.
- CI generates the official Gradle Wrapper JAR with `gradle wrapper --gradle-version 8.12` before invoking `./gradlew`.
- The official binary wrapper JAR was not fabricated in this packaging environment because no local Gradle distribution was available and external binary retrieval was unavailable.
- The official Gradle 8.12 wrapper JAR checksum is recorded in `android/gradle/wrapper/gradle-wrapper.jar.sha256` for verification when the JAR is generated on a developer/CI machine.

## v1.0.5+6 CI patch

The GitHub Actions workflow now explicitly runs `chmod +x android/gradlew` before executing the wrapper. This is required when the repository files were added/updated through a web upload path that does not preserve the POSIX executable bit.
