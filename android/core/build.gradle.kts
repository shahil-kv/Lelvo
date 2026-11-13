// Pure Kotlin: the storage format and encryption, testable on the JVM in seconds. No Android imports.
plugins {
    alias(libs.plugins.kotlin.jvm)
}

kotlin { jvmToolchain(17) }

dependencies {
    // Only the JSON tree (JsonElement) is used, so the serialization compiler plugin isn't needed.
    implementation(libs.kotlinx.serialization.json)

    testImplementation(platform(libs.junit.bom))
    testImplementation(libs.junit.jupiter)
    testRuntimeOnly(libs.junit.launcher)
    testImplementation(kotlin("test-junit5"))
    // Argon2id for the format 2 header vectors. Tests only: the app plugs argon2kt into `Argon2id`.
    testImplementation(libs.bouncycastle.provider)
}

tasks.test {
    useJUnitPlatform()
    // The test vectors are the cross-platform contract; read them in place, never copy them.
    systemProperty("lelvo.vectors", rootProject.file("../docs/test-vectors").absolutePath)
    // The demo library is shared with the iPhone app (App Review needs the same one).
    systemProperty("lelvo.demo", rootProject.file("../iOS/DemoLibrary").absolutePath)
}
