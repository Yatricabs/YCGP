# Android Build Toolchain

This build uses:

- Android Gradle Plugin: 8.11.1
- Gradle wrapper: 8.14
- Kotlin Gradle Plugin: 2.2.20
- Java/JDK: 17

The project intentionally does not enable AGP 9 built-in Kotlin/new DSL migration.
The Flutter Gradle plugin currently requires Kotlin >= 2.2.20 for this Flutter SDK.

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
