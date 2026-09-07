plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.portableai.portable_ai_flutter"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = JavaVersion.VERSION_17.toString() }

    defaultConfig {
        applicationId = "com.portableai.portable_ai_flutter"
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Native llama.cpp is prebuilt explicitly for ARMv7 by CI and packaged
        // from src/main/jniLibs. Do not let AGP/Flutter configure CMake for arm64.
        ndk { abiFilters += setOf("armeabi-v7a") }
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    dependencies {
        androidTestImplementation("androidx.test:runner:1.6.2")
        androidTestImplementation("androidx.test:core:1.6.1")
        androidTestImplementation("junit:junit:4.13.2")
    }
}

flutter { source = "../.." }
