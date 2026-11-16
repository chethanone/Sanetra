plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.visionassistant.vision_assistant"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.visionassistant.vision_assistant"
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
        manifestPlaceholders["appLabel"] = "Vision Assistant"
    }

    buildFeatures {
        resValues = true
    }

    flavorDimensions += "mode"
    productFlavors {
        create("production") {
            dimension = "mode"
            applicationId = "com.visionassistant.vision_assistant"
            manifestPlaceholders["appLabel"] = "Vision Assistant"
            resValue("string", "app_name", "Vision Assistant")
        }
        create("candidate") {
            dimension = "mode"
            applicationId = "com.visionassistant.vision_assistant.candidate"
            manifestPlaceholders["appLabel"] = "VisionMission Candidate"
            resValue("string", "app_name", "VisionMission Candidate")
        }
        create("candidate_d3") {
            dimension = "mode"
            applicationId = "com.visionassistant.vision_assistant.candidate_d3"
            manifestPlaceholders["appLabel"] = "VisionMission D3"
            resValue("string", "app_name", "VisionMission D3")
        }
        create("candidate_d4") {
            dimension = "mode"
            applicationId = "com.visionassistant.vision_assistant.candidate_d4"
            manifestPlaceholders["appLabel"] = "VisionMission D4"
            resValue("string", "app_name", "VisionMission D4")
        }
        create("identitycandidate") {
            dimension = "mode"
            applicationId = "com.visionassistant.vision_assistant.identitycandidate"
            manifestPlaceholders["appLabel"] = "VisionMission Identity"
            resValue("string", "app_name", "VisionMission Identity")
        }
        create("identitycandidate_v2") {
            dimension = "mode"
            applicationId = "com.visionassistant.vision_assistant.identitycandidate_v2"
            manifestPlaceholders["appLabel"] = "VisionMission Identity V2"
            resValue("string", "app_name", "VisionMission Identity V2")
        }
        create("identitycandidate_n5") {
            dimension = "mode"
            applicationId = "com.visionassistant.vision_assistant.identitycandidate_n5"
            manifestPlaceholders["appLabel"] = "VisionMission N5"
            resValue("string", "app_name", "VisionMission N5")
        }
        create("unified_v52") {
            dimension = "mode"
            applicationId = "com.visionassistant.vision_assistant.unified_v52"
            manifestPlaceholders["appLabel"] = "VisionMission 5.2"
            resValue("string", "app_name", "VisionMission 5.2")
        }
        create("visionmission") {
            dimension = "mode"
            applicationId = "com.visionassistant.vision_assistant.visionmission"
            manifestPlaceholders["appLabel"] = "Sanetra"
            resValue("string", "app_name", "Sanetra")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
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

dependencies {
    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.28.0")
}
