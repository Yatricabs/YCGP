plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.yatricabs.gpsbilling"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.yatricabs.gpsbilling"
        minSdk = 21
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

// FlutLab / older Flutter tooling workaround:
// Modern Android Gradle Plugin DSL can successfully create the APK at
// android/app/build/outputs/apk/release/app-release.apk, while the Flutter
// CLI still looks for it at build/app/outputs/flutter-apk/app-release.apk.
// Copy the release APK to Flutter's expected location after assembleRelease.
val copyReleaseApkToFlutterExpectedLocation = tasks.register("copyReleaseApkToFlutterExpectedLocation") {
    doLast {
        val sourceApk = layout.buildDirectory
            .file("outputs/apk/release/app-release.apk")
            .get()
            .asFile

        val expectedDir = rootProject.projectDir.parentFile
            .resolve("build/app/outputs/flutter-apk")
        val expectedApk = expectedDir.resolve("app-release.apk")

        if (!sourceApk.exists()) {
            throw GradleException("Release APK was not found at: ${sourceApk.absolutePath}")
        }

        expectedDir.mkdirs()
        sourceApk.copyTo(expectedApk, overwrite = true)
        println("[YATRI] APK copied to Flutter expected location: ${expectedApk.absolutePath}")
    }
}

afterEvaluate {
    tasks.named("assembleRelease") {
        finalizedBy(copyReleaseApkToFlutterExpectedLocation)
    }
}

