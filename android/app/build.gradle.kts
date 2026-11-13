import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "app.lelvo.android"
    compileSdk = 37

    defaultConfig {
        applicationId = "app.lelvo.android"
        minSdk = 29
        targetSdk = 36
        // The release workflow passes the build number and the beta suffix; local builds stay 1 / 0.1.0.
        versionCode = (findProperty("lelvo.versionCode") as String?)?.toInt() ?: 1
        versionName = (findProperty("lelvo.versionName") as String?) ?: "0.1.0"

        // Telegram app keys come from local.properties (ignored by git), never from the repository.
        val local = Properties().apply {
            rootProject.file("local.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) }
        }
        buildConfigField("int", "TELEGRAM_API_ID", local.getProperty("telegram.apiId", "0"))
        buildConfigField("String", "TELEGRAM_API_HASH", "\"${local.getProperty("telegram.apiHash", "")}\"")
    }

    // The release key never lives in the repository: the release workflow decodes it from GitHub secrets into a
    // temporary file and passes its path and passwords in these variables. Without them a release build is unsigned.
    val keystore = System.getenv("LELVO_KEYSTORE")?.let(::file)?.takeIf { it.exists() }
    signingConfigs {
        if (keystore != null) create("release") {
            storeFile = keystore
            storePassword = System.getenv("LELVO_KEYSTORE_PASSWORD")
            keyAlias = System.getenv("LELVO_KEY_ALIAS")
            keyPassword = System.getenv("LELVO_KEY_PASSWORD")
        }
    }

    buildTypes {
        debug {
            // Debug builds sign in to Telegram's test servers unless local.properties says otherwise, so testing
            // never touches a real library.
            val local = Properties().apply {
                rootProject.file("local.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) }
            }
            buildConfigField("boolean", "TELEGRAM_TEST_DC", local.getProperty("telegram.testDc", "true"))
            // TDLib's two builds: arm64 and x86_64 (emulators on Intel machines).
            ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
        }
        release {
            buildConfigField("boolean", "TELEGRAM_TEST_DC", "false")
            if (keystore != null) signingConfig = signingConfigs.getByName("release")
            // Only where TDLib is built (Scripts/build-tdlib.sh): MapLibre and ML Kit also ship 32-bit ARM and x86, and
            // on such a phone the app would install and then have no TDLib. Phones and Apple Silicon emulators are
            // arm64; one copy of the native code halves the APK.
            ndk { abiFilters += "arm64-v8a" }
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    // The review demo's sample files, shared with the iPhone app: one copy in the repository.
    sourceSets.getByName("main").assets.directories.add("../../iOS/DemoLibrary")
    buildFeatures {
        compose = true
        buildConfig = true
    }
}

dependencies {
    implementation(project(":core"))
    implementation(project(":telegram"))
    implementation(project(":data"))

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.material3)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.coil.compose)
    implementation(libs.coil.video)
    implementation(libs.media3.exoplayer)
    implementation(libs.media3.ui)
    implementation(libs.telephoto.coil3)
    implementation(libs.maplibre)
    implementation(libs.work.runtime)
    debugImplementation(libs.compose.ui.tooling)
}
