plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.portableai.portable_ai_flutter"
    compileSdk = flutter.compileSdkVersion
    // fcllama/jni requires NDK 28.2; newer NDKs remain compatible with the
    // other Android plugins used by this application.
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.portableai.portable_ai_flutter"
        // Product requirement: Android 10 (API 29) minimum.
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
            // Keep the release build unminified while the native ARMv7/FCLlama
            // integration is being validated. R8 currently fails on Flutter's
            // optional Play Store deferred-component classes, which this APK
            // does not use. This is not a model-size or RAM restriction.
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}
