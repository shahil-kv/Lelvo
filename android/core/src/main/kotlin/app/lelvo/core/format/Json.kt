package app.lelvo.core.format

import app.lelvo.core.crypto.nfc
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.math.BigDecimal
import java.util.TreeMap

/** A field with the wrong type, or a required one missing. */
internal class FieldException(key: String) : Exception("Unreadable field $key")

/**
 * Compact JSON with sorted keys, as every Lelvo writer produces it, and strict reading of the fields the format
 * defines. Unknown fields are never looked at, so a newer writer's additions pass through unharmed.
 */
internal object JsonIO {
    fun parseObject(text: String): JsonObject? = try {
        Json.parseToJsonElement(text) as? JsonObject
    } catch (_: IllegalArgumentException) {
        null
    }

    fun parseObject(utf8: ByteArray): JsonObject? = parseObject(String(utf8, Charsets.UTF_8))

    /** Null values are left out; keys are sorted. */
    fun obj(vararg fields: Pair<String, JsonElement?>): JsonObject {
        val sorted = TreeMap<String, JsonElement>()
        for ((key, value) in fields) if (value != null) sorted[key] = value
        return JsonObject(LinkedHashMap(sorted))
    }

    fun str(value: String?): JsonElement? = value?.let { JsonPrimitive(it.nfc()) }
    fun num(value: Long?): JsonElement? = value?.let { JsonPrimitive(it) }
    fun num(value: Int?): JsonElement? = value?.let { JsonPrimitive(it) }

    /** Whole numbers without ".0", as the iPhone writes them. */
    fun num(value: Double?): JsonElement? = value?.let {
        require(it.isFinite()) { "Not a JSON number" }
        if (it == Math.rint(it) && Math.abs(it) < 1e15) JsonPrimitive(it.toLong()) else JsonPrimitive(it)
    }

    fun strings(values: List<String>?): JsonElement? = values?.let { JsonArray(it.map { s -> JsonPrimitive(s.nfc()) }) }
    fun longs(values: List<Long>?): JsonElement? = values?.let { JsonArray(it.map { n -> JsonPrimitive(n) }) }
    fun ints(values: List<Int>?): JsonElement? = values?.let { JsonArray(it.map { n -> JsonPrimitive(n) }) }
    fun doubles(values: List<Double>?): JsonElement? = values?.let { JsonArray(it.map { n -> num(n)!! }) }

    fun utf8(obj: JsonObject): ByteArray = obj.toString().toByteArray(Charsets.UTF_8)
}

/** Typed reads of one JSON object. `null` in the JSON is the same as the key not being there. */
internal class JsonFields(private val obj: JsonObject) {
    private fun element(key: String): JsonElement? = obj[key]?.takeUnless { it is JsonNull }

    fun stringOrNull(key: String): String? = element(key)?.let { string(it, key) }
    fun string(key: String): String = stringOrNull(key) ?: throw FieldException(key)
    fun longOrNull(key: String): Long? = element(key)?.let { long(it, key) }
    fun long(key: String): Long = longOrNull(key) ?: throw FieldException(key)
    fun intOrNull(key: String): Int? = element(key)?.let { int(it, key) }
    fun int(key: String): Int = intOrNull(key) ?: throw FieldException(key)
    fun doubleOrNull(key: String): Double? = element(key)?.let { double(it, key) }
    fun boolOrNull(key: String): Boolean? =
        element(key)?.let { (it as? JsonPrimitive)?.takeIf { p -> !p.isString }?.content?.toBooleanStrictOrNull() ?: throw FieldException(key) }
    fun stringsOrNull(key: String): List<String>? = arrayOrNull(key)?.map { string(it, key) }
    fun strings(key: String): List<String> = stringsOrNull(key) ?: throw FieldException(key)
    fun longsOrNull(key: String): List<Long>? = arrayOrNull(key)?.map { long(it, key) }
    fun intsOrNull(key: String): List<Int>? = arrayOrNull(key)?.map { int(it, key) }
    fun doublesOrNull(key: String): List<Double>? = arrayOrNull(key)?.map { double(it, key) }
    fun objects(key: String): List<JsonObject> =
        (arrayOrNull(key) ?: throw FieldException(key)).map { it as? JsonObject ?: throw FieldException(key) }
    fun obj(key: String): JsonObject = element(key) as? JsonObject ?: throw FieldException(key)
    fun objOrNull(key: String): JsonObject? = element(key)?.let { it as? JsonObject ?: throw FieldException(key) }

    private fun arrayOrNull(key: String): JsonArray? = element(key)?.let { it as? JsonArray ?: throw FieldException(key) }

    private fun string(e: JsonElement, key: String): String =
        (e as? JsonPrimitive)?.takeIf { it.isString }?.content ?: throw FieldException(key)

    private fun number(e: JsonElement, key: String): String =
        (e as? JsonPrimitive)?.takeIf { !it.isString && it !is JsonNull }?.content ?: throw FieldException(key)

    private fun long(e: JsonElement, key: String): Long {
        val text = number(e, key)
        // "1.0" and "1e3" are whole numbers too; "1.5" and "true" are not.
        return text.toLongOrNull() ?: try {
            BigDecimal(text).longValueExact()
        } catch (_: ArithmeticException) {
            throw FieldException(key)
        } catch (_: NumberFormatException) {
            throw FieldException(key)
        }
    }

    private fun int(e: JsonElement, key: String): Int {
        val value = long(e, key)
        if (value < Int.MIN_VALUE || value > Int.MAX_VALUE) throw FieldException(key)
        return value.toInt()
    }

    private fun double(e: JsonElement, key: String): Double {
        val text = number(e, key)
        // toDouble() also reads "NaN" and "Infinity", which aren't JSON.
        if (text.isEmpty() || !(text[0] == '-' || text[0].isDigit())) throw FieldException(key)
        return text.toDoubleOrNull()?.takeIf { it.isFinite() } ?: throw FieldException(key)
    }
}
