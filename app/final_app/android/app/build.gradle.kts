import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.sanetra.assistivevision"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.sanetra.assistivevision"
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
            applicationId = "com.sanetra.assistivevision"
            manifestPlaceholders["appLabel"] = "Sanetra"
            resValue("string", "app_name", "Sanetra")
        }
        create("candidate") {
            dimension = "mode"
            applicationId = "com.sanetra.assistivevision.candidate"
            manifestPlaceholders["appLabel"] = "Sanetra Candidate"
            resValue("string", "app_name", "Sanetra Candidate")
        }
        create("candidate_d3") {
            dimension = "mode"
            applicationId = "com.sanetra.assistivevision.candidate_d3"
            manifestPlaceholders["appLabel"] = "VisionMission D3"
            resValue("string", "app_name", "VisionMission D3")
        }
        create("candidate_d4") {
            dimension = "mode"
            applicationId = "com.sanetra.assistivevision.candidate_d4"
            manifestPlaceholders["appLabel"] = "VisionMission D4"
            resValue("string", "app_name", "VisionMission D4")
        }
        create("identitycandidate") {
            dimension = "mode"
            applicationId = "com.sanetra.assistivevision.identitycandidate"
            manifestPlaceholders["appLabel"] = "VisionMission Identity"
            resValue("string", "app_name", "VisionMission Identity")
        }
        create("identitycandidate_v2") {
            dimension = "mode"
            applicationId = "com.sanetra.assistivevision.identitycandidate_v2"
            manifestPlaceholders["appLabel"] = "VisionMission Identity V2"
            resValue("string", "app_name", "VisionMission Identity V2")
        }
        create("identitycandidate_n5") {
            dimension = "mode"
            applicationId = "com.sanetra.assistivevision.identitycandidate_n5"
            manifestPlaceholders["appLabel"] = "VisionMission N5"
            resValue("string", "app_name", "VisionMission N5")
        }
        create("unified_v52") {
            dimension = "mode"
            applicationId = "com.sanetra.assistivevision.unified_v52"
            manifestPlaceholders["appLabel"] = "VisionMission 5.2"
            resValue("string", "app_name", "VisionMission 5.2")
        }
        create("visionmission") {
            dimension = "mode"
            applicationId = "com.sanetra.assistivevision"
            manifestPlaceholders["appLabel"] = "Sanetra"
            resValue("string", "app_name", "Sanetra")
        }
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
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
