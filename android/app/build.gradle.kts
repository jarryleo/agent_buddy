plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "cn.leo.agent_buddy"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications uses java.time APIs not available
        // on minSdk < 26; core library desugaring backports them so we
        // can keep `minSdk` at Flutter's default.
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "cn.leo.agent_buddy"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            storeFile = file("../keystore/key.jks")
            storePassword = "123456"
            keyAlias = "123456"
            keyPassword = "123456"
            enableV2Signing = true
        }
    }

    buildTypes {
        debug {
            isDebuggable = true
            isMinifyEnabled = false
            isShrinkResources = false
            signingConfig = signingConfigs.getByName("release")
        }
        release {
            isDebuggable = false
            isMinifyEnabled = true
            isShrinkResources = true
            signingConfig = signingConfigs.getByName("release")
        }
    }
    //控制输出apk的名称
    applicationVariants.all {
        val variant = this
        variant.outputs
            .filterIsInstance<com.android.build.gradle.internal.api.BaseVariantOutputImpl>()
            .forEach { output ->
                val apkName = "AgentBuddy"
                val buildType = variant.buildType.name
                val fileName =
                    "${apkName}_${versionName}_${variant.flavorName}_${buildType}.apk"
                output.outputFileName = fileName
            }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("com.google.android.gms:play-services-location:21.3.0")
    // Required by the file tool's SAF working-dir bridge
    // (`DocumentFile.fromTreeUri`, `createFile`, `findFile`,
    // etc). Explicit because we use it directly in
    // `FileBridge.kt` — most other plugins that need it pull
    // it in transitively, but the file tool doesn't have a
    // plugin wrapper.
    implementation("androidx.documentfile:documentfile:1.0.1")
    // Required by `flutter_local_notifications` (and any plugin that
    // uses java.time.* on older API levels). See the
    // isCoreLibraryDesugaringEnabled block above.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
