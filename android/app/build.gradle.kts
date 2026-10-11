import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
    // END: FlutterFire Configuration
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing: android/key.properties (git-ignored, never committed), e.g.
//   storeFile=/absolute/path/to/melai-release.jks
//   storePassword=...
//   keyAlias=melai
//   keyPassword=...
// See docs/RELEASE.md. A release build without it FAILS instead of being signed
// with the debug key.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) FileInputStream(keystorePropertiesFile).use { load(it) }
}

android {
    // The app's real id. It must match the Android app registered in Firebase
    // (android/app/google-services.json) and the Play Console listing.
    namespace = "ph.melainuts.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "ph.melainuts.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            // R8: shrink, optimise and obfuscate the Java/Kotlin side. Build the Dart side with
            //   flutter build appbundle --release --obfuscate --split-debug-info=build/symbols ...
            // (keep build/symbols for crash de-obfuscation; never ship it).
            isMinifyEnabled = true
            isShrinkResources = true
            // Explicit (it is also the release default): a release build can never be debugged.
            isDebuggable = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// Refuse to produce an unsigned / debug-signed release.
gradle.taskGraph.whenReady {
    val wantsRelease = allTasks.any { it.name.contains("Release") && it.project == project }
    if (wantsRelease && !keystorePropertiesFile.exists()) {
        throw GradleException(
            "android/key.properties is missing: release builds must be signed with the release key. See docs/RELEASE.md."
        )
    }
}
