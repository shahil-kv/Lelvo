package app.lelvo.core.index

import app.lelvo.core.format.CloudMessage
import app.lelvo.core.format.Kind
import app.lelvo.core.format.Role

/** Rebuilds the item index from channel messages (docs/CLOUD_FORMAT.md §7), as iOS `LibraryIndexer.build`. */
object LibraryIndexer {
    data class Result(val items: List<LibraryItem>, /** Duplicates of an already-present (id, role, part); safe to delete. */ val orphanMessageIds: List<Long>)

    private val extraRoles = setOf("ad", "ad2", "ra", "epv", "md")

    fun build(messages: List<CloudMessage>): Result {
        val orphans = mutableListOf<Long>()
        // id → role → part index → message; the lowest message id wins (§7 step 3).
        val grouped = LinkedHashMap<String, MutableMap<String, MutableMap<Int, CloudMessage>>>()
        for (m in messages.sortedBy { it.messageId }) {
            val part = m.meta.part?.index ?: 0
            val roles = grouped.getOrPut(m.meta.id) { LinkedHashMap() }
            val parts = roles.getOrPut(m.meta.r.wire) { HashMap() }
            if (parts.containsKey(part)) { orphans += m.messageId; continue }
            parts[part] = m
        }

        val items = mutableListOf<LibraryItem>()
        for ((id, roles) in grouped) {
            val anyMeta = roles.values.firstOrNull()?.values?.firstOrNull()?.meta ?: continue
            // Only copies left and no original: an older version deleted the item and didn't know these roles.
            if ("o" !in roles && roles.keys.all { Role.of(it)?.isOptionalOnly == true }) {
                orphans += roles.values.flatMap { p -> p.values.map { it.messageId } }
                continue
            }
            val primary = roles["o"]?.values?.minByOrNull { it.messageId }?.meta ?: anyMeta
            val kind = when (primary.k) { Kind.LIVE -> ItemKind.LivePhoto; Kind.VIDEO -> ItemKind.Video; Kind.PHOTO -> ItemKind.Photo }
            val parts = HashMap<String, List<RemoteFile>>()
            val expected = HashMap<String, Int>()
            val hashes = HashMap<String, String>()
            val names = HashMap<String, String>()
            var pairedName: String? = null; var pairedSize: Long? = null
            var editedName: String? = null; var editedSize: Long? = null
            for ((role, byPart) in roles) {
                val ordered = byPart.toSortedMap().values.toList()
                val count = ordered.first().meta.part?.count ?: 1
                parts[role] = ordered.map { RemoteFile(it.messageId, it.fileId, it.uniqueId, it.size) }
                // Gaps in the part sequence mean an incomplete upload.
                val contiguous = byPart.keys.sorted() == (0 until byPart.size).toList()
                expected[role] = if (contiguous) count else count + 1
                hashes[role] = ordered.first().meta.h
                val m = ordered.first().meta
                when (role) {
                    "e" -> { editedName = m.n; editedSize = m.s }
                    "pv" -> { pairedName = m.n; pairedSize = m.s }
                    in extraRoles -> names[role] = m.n
                }
            }
            var item = LibraryItem(
                id = id, localId = null, sha256 = if ("o" in roles) primary.h else "", filename = primary.n, kind = kind,
                createdAt = primary.t?.let { it * 1000 }, latitude = primary.latitude, longitude = primary.longitude,
                width = primary.wh?.firstOrNull() ?: 0, height = primary.wh?.getOrNull(1) ?: 0, duration = primary.d,
                fileSize = primary.s, status = ItemStatus.BackedUp, favorite = primary.fav == 1, hidden = primary.hid == 1,
                albums = primary.a ?: emptyList(), parts = parts, expectedParts = expected, encrypted = primary.isEncrypted,
                mimeType = primary.m, codec = primary.c, hdr = primary.hdr, tzOffsetMinutes = primary.tz, sourceLocalId = primary.l,
                hasEdit = primary.ed == 1 || "e" in roles, roleHashes = hashes, roleNames = names,
                pairedVideoName = pairedName, pairedVideoSize = pairedSize, editedName = editedName, editedSize = editedSize,
            )
            if (!item.isCompleteInCloud) {
                item = item.copy(status = ItemStatus.Failed, lastError = "Incomplete in the cloud: a part is missing. Tap Retry to finish uploading it.")
            }
            items += item
        }
        items.sortByDescending { it.createdAt ?: Long.MIN_VALUE }
        return Result(items, orphans.sorted())
    }
}
