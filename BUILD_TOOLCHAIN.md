# Android Build Toolchain

## Current workspace

This build uses:

- Android Gradle Plugin: 9.0.1
- Gradle wrapper: 9.2.0
- Kotlin Gradle Plugin: 2.2.20
- Java/JDK: 17

The app still applies the Kotlin Gradle plugin because the current Flutter
toolchain reports the third-party `floating` plugin as incompatible with
built-in Kotlin. The deprecation warning is dependency/toolchain-related, not
an app source error. Revisit this when `floating` publishes a built-in-Kotlin
compatible release.

Build from the project root:

```powershell
flutter clean
flutter pub get
cd android
.\gradlew --stop
\.\gradlew clean
cd ..
flutter build apk --release
```

GitHub Actions installs and accepts the Android SDK licenses, then explicitly
installs the required `ndk;30.0.16138531` package before Gradle runs. The CI
workflow also uses Flutter 3.47.2 and Gradle 9.2.0 to match this workspace.

Expected APK:
`build\app\outputs\flutter-apk\app-release.apk`

The release APK generated in the current workspace is also available at
`build\app\outputs\apk\release\app-release.apk` when the direct Gradle task
is used.
