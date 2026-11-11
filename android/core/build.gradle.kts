// Pure Kotlin: the storage format and encryption, testable on the JVM in seconds. No Android imports.
plugins {
    alias(libs.plugins.kotlin.jvm)
}

kotlin { jvmToolchain(17) }

dependencies {
    testImplementation(platform(libs.junit.bom))
    testImplementation(libs.junit.jupiter)
    testRuntimeOnly(libs.junit.launcher)
}

tasks.test {
    useJUnitPlatform()
    // The test vectors are the cross-platform contract; read them in place, never copy them.
    systemProperty("lelvo.vectors", rootProject.file("../docs/test-vectors").absolutePath)
}

dependencies { testImplementation(kotlin("test-junit5")) }
