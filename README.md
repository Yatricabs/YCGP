# YATRI CABS GPS Billing - Android

Android-only Flutter project.

## Build the APK (recommended: GitHub Actions)

FlutLab's own web build server can intermittently fail with a generic
`Request failed with status code 400` before Gradle even runs. This project
now ships with a ready-to-use GitHub Actions workflow so you don't have to
depend on FlutLab's build server at all.

1. Create a new **private** GitHub repository (e.g. `yatri-cabs-app`).
2. Push this entire folder's contents to that repo's `main` branch.
3. Go to the repo's **Actions** tab. The `Build Android APK` workflow runs
   automatically on every push (or click **Run workflow** to trigger it
   manually).
4. Once it finishes (green check), open the workflow run and scroll to
   **Artifacts** at the bottom - download `yatri-cabs-release-apk`, which
   contains `app-release.apk`.

No Android Studio or local Flutter install needed - GitHub's servers do the
build and give you the full Gradle log if anything fails.

## Alternative: Codemagic

A `codemagic.yaml` is also included. If you'd rather use Codemagic:
1. Sign up at codemagic.io and connect the same GitHub repo.
2. Codemagic auto-detects `codemagic.yaml` and shows the
   `yatri-cabs-android` workflow - just click **Start new build**.
3. Download the APK from the build's **Artifacts** section.

## Important V11 fix (still included)

This version includes a Gradle workaround for Flutter tooling that reports:

`Gradle build failed to produce an .apk file. It's likely that this file was generated under /app/build, but the tool couldn't find it.`

Modern Android Gradle Plugin projects can successfully generate the release APK at:

`android/app/build/outputs/apk/release/app-release.apk`

while older Flutter/FlutLab artifact detection expects:

`build/app/outputs/flutter-apk/app-release.apk`

This version automatically copies the generated release APK to Flutter's expected path after `assembleRelease` (this also matches the path GitHub Actions/Codemagic look for above).

## Build configuration

- Gradle: 8.12
- Android NDK: 27.0.12077973
- Android Gradle Plugin: 8.7.3
- Kotlin: 2.1.0
- Dart/Flutter compatible with FlutLab Flutter 3.32 / Dart 3.8.1
- google_maps_flutter: 2.13.1
- google_maps_flutter_web override: 0.5.14+2
- geolocator: 14.0.2

## Gradle wrapper

`distributionUrl=https://services.gradle.org/distributions/gradle-8.12-bin.zip`

## App behavior

- Estimated Km is hard-coded to 291 KM.
- Distance Covered starts at 0.0 KM.
- GPS is sampled every 2 seconds during the ride.
- Distance is accumulated using GPS coordinates with `Geolocator.distanceBetween`.
- GPS drift below 3 m, poor fixes above 50 m accuracy, and jumps above 100 m per 2-second sample are ignored.
- Android location permissions are included.
- The app requests exemption from Android battery optimization.
- Google Maps Android API key is configured in AndroidManifest.xml.
