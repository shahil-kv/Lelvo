package app.lelvo.core.sync

import app.lelvo.core.format.MetaLog
import app.lelvo.core.format.TrashLog
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * A library's choices that only this phone knows (iOS `LibrarySnapshots.Choices`): the off-backup keys, and the
 * Recently Deleted and favorites and albums changes not sent yet. Local file only, not the storage format.
 */
data class KeptChoices(
    val offBackup: List<String> = emptyList(),
    val waiting: Map<TrashLog.Op, List<String>> = emptyMap(),
    val meta: Map<String, Map<MetaLog.Key, Boolean>> = emptyMap(),
) {
    val isEmpty: Boolean get() = offBackup.isEmpty() && waiting.values.all { it.isEmpty() } && meta.values.all { it.isEmpty() }

    fun encode(): String = JsonObject(
        mapOf(
            "offBackup" to JsonArray(offBackup.map(::JsonPrimitive)),
            "waiting" to JsonObject(waiting.entries.associate { (op, ids) -> op.wire to JsonArray(ids.map(::JsonPrimitive)) }),
            "meta" to JsonObject(meta.entries.associate { (id, keys) -> id to JsonObject(keys.entries.associate { (k, v) -> k.stored to JsonPrimitive(v) }) }),
        ),
    ).toString()

    companion object {
        /** Null when the file can't be read; unknown actions and keys are left out (`gone` is never sent again). */
        fun decode(text: String): KeptChoices? = runCatching {
            val obj = Json.parseToJsonElement(text).jsonObject
            KeptChoices(
                offBackup = obj["offBackup"]?.jsonArray?.map { it.jsonPrimitive.content }.orEmpty(),
                waiting = obj["waiting"]?.jsonObject?.mapNotNull { (op, ids) ->
                    TrashLog.Op.of(op)?.takeIf { it != TrashLog.Op.GONE }?.let { it to ids.jsonArray.map { id -> id.jsonPrimitive.content } }
                }?.toMap().orEmpty().filterValues { it.isNotEmpty() },
                meta = obj["meta"]?.jsonObject?.mapValues { (_, keys) ->
                    keys.jsonObject.mapNotNull { (k, v) ->
                        val key = MetaLog.Key.ofStored(k) ?: return@mapNotNull null
                        val value = v.jsonPrimitive.booleanOrNull ?: return@mapNotNull null
                        key to value
                    }.toMap()
                }.orEmpty().filterValues { it.isNotEmpty() },
            )
        }.getOrNull()
    }
}
