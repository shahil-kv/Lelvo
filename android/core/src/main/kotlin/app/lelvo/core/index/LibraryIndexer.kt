package app.lelvo.core.index

import app.lelvo.core.format.CaptionMeta
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

    /**
     * The messages already known for [item] (minus [scanned]), as [build] needs them when a recent scan only sees an
     * item's newer messages (iOS `knownMessages`). Each role's caption comes from the item itself, never from whichever
     * message happened to be new: a fast version uploaded later must not become the original.
     */
    fun knownMessages(item: LibraryItem, scanned: Set<Long>): List<CloudMessage> {
        val kind = when (item.kind) { ItemKind.LivePhoto -> Kind.LIVE; ItemKind.Video -> Kind.VIDEO; ItemKind.Photo -> Kind.PHOTO }
        val out = ArrayList<CloudMessage>()
        for ((role, files) in item.parts) {
            val r = Role.of(role) ?: continue
            val (name, size) = when (role) {
                "o" -> item.filename to item.fileSize
                "pv" -> (item.pairedVideoName ?: item.filename) to (item.pairedVideoSize ?: 0L)
                "e" -> (item.editedName ?: item.filename) to (item.editedSize ?: 0L)
                else -> (item.roleNames[role] ?: item.filename) to files.sumOf { it.size }
            }
            val hash = item.roleHashes[role] ?: if (role == "o") item.sha256 else "0".repeat(64)
            val lat = item.latitude; val lon = item.longitude
            val meta = CaptionMeta(
                id = item.id, r = r, k = kind, h = hash, n = name, s = size, m = item.mimeType,
                t = item.createdAt?.let { it / 1000 }, tz = item.tzOffsetMinutes,
                g = if (lat != null && lon != null) listOf(lat, lon) else null,
                wh = if (item.width > 0) listOf(item.width, item.height) else null,
                d = item.duration, c = item.codec, hdr = item.hdr, a = item.albums.takeIf { it.isNotEmpty() },
                fav = if (item.favorite) 1 else null, hid = if (item.hidden) 1 else null, l = item.sourceLocalId,
                ed = if (role == "o" && item.hasEdit) 1 else null, e = if (item.encrypted) 1 else null,
            )
            val count = item.expectedParts[role] ?: files.size
            files.forEachIndexed { i, f ->
                if (f.messageId in scanned) return@forEachIndexed
                val m = meta.copy(p = if (count > 1) listOf(i.toLong(), count.toLong(), files.first().size) else null)
                out += CloudMessage(f.messageId, m, f.fileId, f.uniqueId, f.size)
            }
        }
        return out
    }

    sealed class DeleteOutcome {
        object Unchanged : DeleteOutcome()
        data class Update(val item: LibraryItem) : DeleteOutcome()
        object Remove : DeleteOutcome()
    }

    const val NOT_FOUND = "Not found in the Telegram channel any more. Tap Retry to upload it again."

    /**
     * What a full scan would make of [item] once the messages [deleted] are gone from the channel (another device
     * deleted them): rebuilt from the messages left, or handled like an item that vanished. Items linked to a photo on
     * this phone are never removed; they become "not found" so they upload again (iOS `afterDeleting`).
     */
    fun afterDeleting(deleted: Set<Long>, item: LibraryItem): DeleteOutcome {
        if (item.parts.values.none { files -> files.any { it.messageId in deleted } }) return DeleteOutcome.Unchanged
        // Being uploaded by this phone: the upload path owns its parts and checks them itself.
        if (item.status == ItemStatus.Uploading || item.status == ItemStatus.Queued) return DeleteOutcome.Unchanged
        build(knownMessages(item, deleted)).items.firstOrNull { it.id == item.id }?.let { found ->
            var rebuilt = found.keepingLocalState(item)
            // Incomplete ones too: part of the item going doesn't take it out of Recently Deleted.
            if (item.status == ItemStatus.Trashed) rebuilt = rebuilt.copy(status = ItemStatus.Trashed, trashedAt = item.trashedAt)
            return DeleteOutcome.Update(rebuilt)
        }
        return when {
            item.status == ItemStatus.Trashed -> DeleteOutcome.Remove
            item.status == ItemStatus.BackedUp && item.localId == null -> DeleteOutcome.Remove
            item.status == ItemStatus.BackedUp ->
                DeleteOutcome.Update(item.copy(status = ItemStatus.Failed, parts = emptyMap(), lastError = NOT_FOUND))
            else -> DeleteOutcome.Unchanged
        }
    }
}
