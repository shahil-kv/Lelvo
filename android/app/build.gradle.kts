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
        versionCode = 1
        versionName = "0.1.0"

        // Telegram app keys come from local.properties (ignored by git), never from the repository.
        val local = Properties().apply {
            rootProject.file("local.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) }
        }
        buildConfigField("int", "TELEGRAM_API_ID", local.getProperty("telegram.apiId", "0"))
        buildConfigField("String", "TELEGRAM_API_HASH", "\"${local.getProperty("telegram.apiHash", "")}\"")
    }

    buildTypes {
        debug {
            // Debug builds sign in to Telegram's test servers unless local.properties says otherwise, so testing
            // never touches a real library.
            val local = Properties().apply {
                rootProject.file("local.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) }
            }
            buildConfigField("boolean", "TELEGRAM_TEST_DC", local.getProperty("telegram.testDc", "true"))
        }
        release {
            buildConfigField("boolean", "TELEGRAM_TEST_DC", "false")
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
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
    debugImplementation(libs.compose.ui.tooling)
}
