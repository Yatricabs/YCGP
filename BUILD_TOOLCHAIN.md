# Android Build Toolchain

This build uses:

- Android Gradle Plugin: 9.0.1
- Gradle wrapper: 9.1.0
- Kotlin Gradle Plugin: 2.3.20
- Java/JDK: 17

The project uses the AGP 9-compatible Kotlin plugin and Gradle wrapper required by
the current Flutter toolchain.

Build from the project root:

```powershell
flutter clean
flutter pub get
cd android
.\gradlew --stop
.\gradlew clean
cd ..
flutter build apk --release
```

Expected APK:
`build\app\outputs\flutter-apk\app-release.apk`
