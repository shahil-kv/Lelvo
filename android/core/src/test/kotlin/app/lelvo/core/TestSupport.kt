package app.lelvo.core

import app.lelvo.core.crypto.Argon2id
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.bouncycastle.crypto.generators.Argon2BytesGenerator
import org.bouncycastle.crypto.params.Argon2Parameters
import java.io.File

/** One file of docs/test-vectors, read in place. */
class Vector(name: String) {
    private val json: JsonObject = Json.parseToJsonElement(File(System.getProperty("lelvo.vectors"), name).readText()).jsonObject

    fun string(key: String): String = json.getValue(key).jsonPrimitive.content
    fun int(key: String): Int = string(key).toInt()
    fun bytes(key: String): ByteArray = unhex(string(key))
    fun strings(key: String): List<String> = json.getValue(key).jsonArray.map { it.jsonPrimitive.content }
    val keys: Set<String> get() = json.keys
}

fun unhex(hex: String): ByteArray = ByteArray(hex.length / 2) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }

/** The plaintext the format 1 file vector was made from. */
fun vectorPlaintext(n: Int): ByteArray = ByteArray(n) { (it % 251).toByte() }

fun pattern(n: Int, step: Int = 31): ByteArray = ByteArray(n) { (it * step).toByte() }

/** Argon2id for the JVM tests. The app uses argon2kt: Bouncy Castle's can run out of memory at 256 MiB on a phone. */
val testArgon2 = Argon2id { password, salt, iterations, memoryKiB, parallelism, length ->
    val parameters = Argon2Parameters.Builder(Argon2Parameters.ARGON2_id)
        .withVersion(Argon2Parameters.ARGON2_VERSION_13)
        .withIterations(iterations).withMemoryAsKB(memoryKiB).withParallelism(parallelism).withSalt(salt).build()
    ByteArray(length).also { out -> Argon2BytesGenerator().apply { init(parameters) }.generateBytes(password, out) }
}

/** The smallest cost readers accept, so the tests stay quick. */
val cheapArgon = app.lelvo.core.crypto.Argon2Parameters(iterations = 1, memoryKiB = 19 * 1024)
