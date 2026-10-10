import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val signingPropertiesFile = file(System.getenv("DDL_SIGNING_PROPERTIES")
    ?: "${System.getProperty("user.home")}/.ddl-killer-secrets/signing.properties")
val signingProperties = Properties()
if (signingPropertiesFile.exists()) signingPropertiesFile.inputStream().use { signingProperties.load(it) }
if (gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) } && !signingPropertiesFile.exists()) {
    throw GradleException("Release signing configuration missing: set DDL_SIGNING_PROPERTIES")
}

android {
    namespace = "com.aliceandandy.plan_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Keep the published ID for compatible updates; independent forks must use their own ID.
        applicationId = "com.aliceandandy.plan_app"
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
            if (signingPropertiesFile.exists()) {
                storeFile = file(signingProperties.getProperty("storeFile"))
                storePassword = signingProperties.getProperty("storePassword")
                keyAlias = signingProperties.getProperty("keyAlias")
                keyPassword = signingProperties.getProperty("keyPassword")
            }
        }
    }
    flavorDimensions += "channel"
    productFlavors {
        create("stable") {
            dimension = "channel"
            manifestPlaceholders["appLabel"] = "DDL Killer"
        }
        create("beta") {
            dimension = "channel"
            applicationIdSuffix = ".beta"
            manifestPlaceholders["appLabel"] = "DDL Killer Beta"
        }
    }
    buildTypes {
        release {
            // Retain the existing certificate for compatible updates; keep secrets outside the repository.
            signingConfig = signingConfigs.getByName("release")
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
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
