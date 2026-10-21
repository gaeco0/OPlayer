import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseSigningFile = rootProject.file("key.properties")
val releaseSigning = Properties().apply {
    if (releaseSigningFile.exists()) releaseSigningFile.inputStream().use { load(it) }
}

val checkReleaseSigning by tasks.registering {
    doLast {
        require(releaseSigningFile.exists() &&
            listOf("storeFile", "storePassword", "keyAlias", "keyPassword").all {
                !releaseSigning.getProperty(it).isNullOrBlank()
            }) {
            "Release signing requires android/key.properties and the original OPlayer signing keystore."
        }
        require(rootProject.file(releaseSigning.getProperty("storeFile")).isFile) {
            "Release signing keystore is missing. Restore the original key; do not generate a replacement."
        }
    }
}

tasks.matching { it.name == "preReleaseBuild" }.configureEach {
    dependsOn(checkReleaseSigning)
}

android {
    namespace = "com.oplayer.oplayer"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion
    packaging {
        jniLibs.useLegacyPackaging = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.oplayer.oplayer"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            storeFile = releaseSigning.getProperty("storeFile")?.let { rootProject.file(it) }
            storePassword = releaseSigning.getProperty("storePassword")
            keyAlias = releaseSigning.getProperty("keyAlias")
            keyPassword = releaseSigning.getProperty("keyPassword")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("io.github.jamaismagic.ffmpeg:ffmpeg-kit-main-min-16kb:6.1.4")
    implementation("com.google.android.gms:play-services-cast-framework:22.3.1")
    implementation("androidx.appcompat:appcompat:1.7.1")
    implementation("androidx.media:media:1.7.0")
}
