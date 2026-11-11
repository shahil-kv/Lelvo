plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.ksp)
}

android {
    namespace = "app.lelvo.data"
    compileSdk = 37
    defaultConfig { minSdk = 29 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

ksp {
    // Schema history checked in, so a later change to the index gets a reviewed migration.
    arg("room.schemaLocation", "$projectDir/schemas")
}

dependencies {
    api(project(":telegram"))
    implementation(libs.argon2kt)
    implementation(libs.room.runtime)
    ksp(libs.room.compiler)
}
