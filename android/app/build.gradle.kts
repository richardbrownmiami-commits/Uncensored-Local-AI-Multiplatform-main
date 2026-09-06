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

        // This APK is specifically the 32-bit ARMv7 build. Prevent native
        // plugins such as FCLlama from being configured/packaged for arm64.
        ndk {
            abiFilters += setOf("armeabi-v7a")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
            // Keep release unminified. The app does not use deferred Play
            // components, and R8 was failing on those optional classes.
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}
