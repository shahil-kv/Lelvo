package app.lelvo.core.backup

import app.lelvo.core.crypto.FileCrypto
import app.lelvo.core.format.PartLayout
import app.lelvo.core.index.ItemExtras
import app.lelvo.core.index.ItemKind
import app.lelvo.core.index.ItemStatus
import app.lelvo.core.index.LibraryItem
import app.lelvo.core.index.RemoteFile
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

private fun item(
    local: String? = "A", status: ItemStatus = ItemStatus.Queued, kind: ItemKind = ItemKind.Photo, name: String = "IMG.HEIC",
    day: Long? = null, chosen: Boolean = false, cloud: Boolean = false,
): LibraryItem {
    val base = LibraryItem(
        "id-$name-$local", local, "h", name, kind, day?.let { it * 86_400_000 }, fileSize = 10, status = status, chosen = chosen,
    )
    return if (cloud) base.withParts("o", listOf(RemoteFile(1, "f", "u", 10)), expected = 2) else base
}

/** iOS `JobMachineTests`. */
class JobMachineTest {
    private val now = 1_000_000L

    @Test fun happyPath() {
        var j = JobMachine.reduce(JobStatus(), JobEvent.Start, now)
        assertEquals(JobState.Uploading, j.state)
        j = JobMachine.reduce(j, JobEvent.Sent(true), now)
        assertEquals(JobState.Verified, j.state)
        assertEquals(JobState.Verified, JobMachine.reduce(j, JobEvent.Retry, now).state)
    }

    @Test fun floodWaitDoesNotCountAsAttempt() {
        var j = JobMachine.reduce(JobStatus(), JobEvent.Start, now)
        j = JobMachine.reduce(j, JobEvent.FloodWait(42), now)
        assertEquals(JobState.Pending, j.state)
        assertEquals(0, j.attempts)
        assertEquals(now + 42_000, j.notBefore)
        assertFalse(j.isRunnable(now))
        assertTrue(j.isRunnable(now + 42_000))
    }

    @Test fun transientErrorsBackOffThenFail() {
        var j = JobStatus()
        for (attempt in 1..JobMachine.MAX_ATTEMPTS) {
            j = JobMachine.reduce(j, JobEvent.Start, now)
            j = JobMachine.reduce(j, JobEvent.Error("network", transient = true), now)
            assertEquals(attempt, j.attempts)
            if (attempt < JobMachine.MAX_ATTEMPTS) {
                assertEquals(JobState.Pending, j.state)
                assertTrue(j.notBefore!! > now)
                j = j.copy(notBefore = null)
            }
        }
        assertEquals(JobState.Failed, j.state)
        assertEquals(JobStatus(), JobMachine.reduce(j, JobEvent.Retry, now))
    }

    @Test fun sizeMismatchAndPermanentErrorsFail() {
        val up = JobMachine.reduce(JobStatus(), JobEvent.Start, now)
        assertEquals(JobState.Failed, JobMachine.reduce(up, JobEvent.Sent(false), now).state)
        val perm = JobMachine.reduce(up, JobEvent.Error("FILE_REFERENCE_EXPIRED", transient = false), now)
        assertEquals(JobState.Failed, perm.state)
        assertEquals("FILE_REFERENCE_EXPIRED", perm.lastError)
        assertEquals(JobState.Pending, JobMachine.reduce(up, JobEvent.Interrupted, now).state)
    }

    @Test fun errorClassification() {
        val c = TelegramErrorClassifier
        assertEquals(TelegramErrorKind.FloodWait(17), c.classify(429, "Too Many Requests: retry after 17"))
        assertEquals(TelegramErrorKind.FloodWait(300), c.classify(420, "FLOOD_WAIT_300"))
        assertEquals(TelegramErrorKind.FloodWait(8), c.classify(420, "FLOOD_PREMIUM_WAIT_8"))
        assertEquals(TelegramErrorKind.Auth, c.classify(401, "Unauthorized"))
        assertEquals(TelegramErrorKind.Transient, c.classify(500, "Internal"))
        assertEquals(TelegramErrorKind.Transient, c.classify(400, "Network error"))
        assertEquals(TelegramErrorKind.Permanent, c.classify(400, "CHAT_WRITE_FORBIDDEN"))
    }

    @Test fun itemStatusFollowsTheJob() {
        val queued = item()
        val up = queued.reduced(JobEvent.Start, now)
        assertEquals(ItemStatus.Uploading, up.status)
        val waiting = up.reduced(JobEvent.FloodWait(10), now)
        assertEquals(ItemStatus.Queued, waiting.status)
        assertEquals(now + 10_000, waiting.notBefore)
        assertEquals(ItemStatus.BackedUp, up.reduced(JobEvent.Sent(true), now).status)
        // A trashed item is verified for the machine: nothing moves it.
        val trashed = item(status = ItemStatus.Trashed)
        assertEquals(JobState.Verified, trashed.job.state)
        assertEquals(ItemStatus.Trashed, trashed.reduced(JobEvent.Start, now).status)
    }
}

class UploadSlotsTest {
    @Test fun twoAtOnceAndAWaitingNoteGoesNext() {
        val s = UploadSlots(2)
        assertTrue(s.acquireForLane())
        assertTrue(s.acquireForLane())
        assertFalse(s.acquireForLane())
        assertFalse(s.acquireForNote())
        s.release()
        // The note is waiting: the lane can't take the freed slot.
        assertFalse(s.acquireForLane())
        assertTrue(s.acquireForNote())
        s.release()
        assertTrue(s.acquireForLane())
    }

    @Test fun aNoteThatGivesUpUnblocksTheLanes() {
        val s = UploadSlots(1)
        assertTrue(s.acquireForLane())
        assertFalse(s.acquireForNote())
        s.release()
        s.stopWaitingForNote()
        assertTrue(s.acquireForLane())
    }
}

/** iOS `UploadOrderTests`. */
class UploadOrderTest {
    @Test fun halfDoneFirstThenPhotosThenVideosNewestFirst() {
        val halfDone = item(name = "halfDone", kind = ItemKind.Video, day = 1, cloud = true)
        val items = listOf(
            item(name = "oldVideo", kind = ItemKind.Video, day = 2), item(name = "newVideo", kind = ItemKind.Video, day = 8),
            item(name = "oldPhoto", day = 3), item(name = "live", kind = ItemKind.LivePhoto, day = 7), halfDone,
        )
        assertEquals(listOf("halfDone", "live", "oldPhoto", "newVideo", "oldVideo"), UploadOrder.sorted(items).map { it.filename })
    }
}

/** iOS `UploadStallTests`. */
class UploadStallTest {
    private val start = 1_800_000_000_000L

    @Test fun aSlowUploadThatMovesIsNotStuck() {
        val stall = UploadStall(start, 180_000)
        for (minute in 1..10) stall.record(minute.toLong() shl 20, start + minute * 60_000L)
        assertFalse(stall.isStalled(start + 10 * 60_000 + 179_000))
        assertTrue(stall.isStalled(start + 10 * 60_000 + 180_000))
    }

    @Test fun repeatedReportsOfTheSameBytesDontCountAsMoving() {
        val stall = UploadStall(start, 180_000)
        stall.record(25L shl 20, start + 10_000)
        stall.record(25L shl 20, start + 150_000)
        assertTrue(stall.isStalled(start + 190_000))
        assertEquals(25L shl 20, stall.sent)
    }

    @Test fun timeTheProcessWasFrozenDoesntCount() {
        val stall = UploadStall(start, 180_000)
        val looks = mutableListOf<Boolean>()
        fun look(s: Long) { looks += stall.check(start + s * 1000) }
        look(10)
        look(610)
        for (t in 620L..780L step 10) look(t)
        assertFalse(true in looks)
        look(790)
        assertTrue(looks.last())
    }

    @Test fun restartGivesAnotherFullTimeout() {
        val stall = UploadStall(start, 180_000)
        assertTrue(stall.isStalled(start + 200_000))
        stall.restart(start + 200_000)
        assertFalse(stall.isStalled(start + 379_000))
        assertTrue(stall.isStalled(start + 380_000))
    }

    @Test fun anUploadThatNeverStartsIsStuckAfterTheTimeout() {
        val stall = UploadStall(start, 180_000)
        assertFalse(stall.isStalled(start + 179_000))
        assertTrue(stall.isStalled(start + 180_000))
    }
}

/** iOS `TransferRateTests`. */
class TransferRateTest {
    private val start = 1_800_000_000_000L

    @Test fun estimatesFromTheRecentSpeed() {
        val rate = TransferRate()
        rate.record(0, start)
        assertNull(rate.secondsLeft(100L shl 20))
        for (s in 1..10) rate.record(s.toLong() shl 20, start + s * 1000L)
        assertEquals(90, rate.secondsLeft(100L shl 20))
        for (s in 1..20) rate.record((10L shl 20) + s * 102_400L, start + 10_000 + s * 1000L)
        val left = rate.secondsLeft(100L shl 20)!!
        assertTrue(left in 851..949, "left $left")
    }

    @Test fun startsOverForANewFile() {
        val rate = TransferRate()
        rate.record(50L shl 20, start)
        rate.record(60L shl 20, start + 10_000)
        rate.record(1L shl 20, start + 11_000)
        assertNull(rate.bytesPerSecond)
    }

    @Test fun noEstimateWhenNothingMoves() {
        val rate = TransferRate()
        rate.record(25L shl 20, start)
        rate.record(25L shl 20, start + 10_000)
        assertNull(rate.secondsLeft(80L shl 20))
    }
}

/** iOS `BackupCountsTests`. */
class BackupCountsTest {
    private fun compute(
        queued: List<LibraryItem> = emptyList(), failed: List<LibraryItem> = emptyList(), candidates: List<String> = emptyList(),
        known: Set<String> = emptySet(), offBackup: Set<String> = emptySet(), auto: Boolean = false,
    ) = BackupCounts.compute(queued, failed, candidates, known, offBackup, auto)

    @Test fun nothingIsCountedTwiceWithAutomaticBackupOn() {
        val c = compute(queued = listOf(item()), candidates = listOf("B", "C"), auto = true)
        assertEquals(1, c.activeQueue); assertEquals(2, c.notQueued); assertEquals(3, c.left); assertEquals(3, c.pending(true))
    }

    @Test fun withoutAutomaticBackupOnlyPickedItemsAreActive() {
        val c = compute(queued = listOf(item(chosen = true), item()), candidates = listOf("B"))
        assertEquals(1, c.activeQueue); assertEquals(2, c.notQueued); assertEquals(3, c.left); assertEquals(1, c.pending(false))
    }

    @Test fun photosDeletedFromTheBackupAreNotLeftToDo() {
        assertEquals(1, compute(candidates = listOf("A", "B"), offBackup = setOf("A"), auto = true).left)
    }

    @Test fun photosAlreadyKnownAreNotLeftToDo() {
        assertEquals(0, compute(candidates = listOf("A", "B"), known = setOf("A", "B")).left)
    }

    @Test fun incompleteItemsWithNoPhotoHereCountAsFailedNotAsLeftToDo() {
        val stuck = item(local = null, chosen = true, cloud = true)
        val c = compute(queued = listOf(stuck, stuck, stuck))
        assertEquals(0, c.left); assertEquals(3, c.failed); assertEquals(0, c.retryable)
    }

    private fun removed(trashed: List<LibraryItem> = emptyList(), offBackup: Set<String> = emptySet(), known: Set<String> = emptySet(), present: Set<String>) =
        BackupCounts.removedFromBackup(trashed, offBackup, known, present)

    @Test fun removedFromBackup() {
        assertEquals(listOf("A"), removed(trashed = listOf(item(status = ItemStatus.Trashed)), known = setOf("A"), present = setOf("A")))
        assertEquals(listOf("A"), removed(offBackup = setOf("A"), present = setOf("A")))
        assertTrue(removed(trashed = listOf(item(status = ItemStatus.Trashed)), offBackup = setOf("B"), known = setOf("A"), present = emptySet()).isEmpty())
        // Recovered on another device: back in the index, so an old mark doesn't list it.
        assertTrue(removed(offBackup = setOf("A"), known = setOf("A"), present = setOf("A")).isEmpty())
        assertEquals(listOf("A"), removed(trashed = listOf(item(status = ItemStatus.Trashed)), offBackup = setOf("A"), known = setOf("A"), present = setOf("A")))
        assertTrue(removed(trashed = listOf(item(local = null, status = ItemStatus.Trashed)), present = setOf("A")).isEmpty())
    }
}

/** iOS `HashReuseTests` and `PhotoChangeScanTests.queuedButDeleted`. */
class HashReuseAndDeletedTest {
    private val date = 1_790_000_000_000L
    private fun tried() = item(kind = ItemKind.Video).copy(fileSize = 3_000, assetModifiedAt = date, roleHashes = mapOf("o" to "h"))

    @Test fun unchangedFileReusesItsHash() {
        assertTrue(Dedupe.canReuseHashes(tried(), date, 3_000, null))
    }

    @Test fun anyChangeHashesAgain() {
        assertFalse(Dedupe.canReuseHashes(tried(), date + 1, 3_000, null))
        assertFalse(Dedupe.canReuseHashes(tried(), null, 3_000, null))
        assertFalse(Dedupe.canReuseHashes(tried(), date, 3_001, null))
        assertFalse(Dedupe.canReuseHashes(tried().copy(sha256 = ""), date, 3_000, null))
        assertFalse(Dedupe.canReuseHashes(tried().copy(assetModifiedAt = null), null, 3_000, null))
        // A paired video appeared that has no stored hash.
        assertFalse(Dedupe.canReuseHashes(tried().copy(pairedVideoSize = 5), date, 3_000, 5))
    }

    @Test fun dropsQueuedPhotosDeletedFromThePhone() {
        val items = listOf(item("kept"), item("deleted"), item("uploading", ItemStatus.Uploading), item("backedUp", ItemStatus.BackedUp), item(null))
        assertEquals(listOf("deleted"), PhotoChangeScan.queuedButDeleted(items, setOf("kept"), false).map { it.localId })
    }

    @Test fun keepsItemsWithPartsInTheChannel() {
        assertTrue(PhotoChangeScan.queuedButDeleted(listOf(item("halfDone", cloud = true)), setOf("other"), false).isEmpty())
    }

    @Test fun keepsTheQueueWhenMediaStoreFindsNothing() {
        val items = listOf(item("a"), item("b"))
        assertTrue(PhotoChangeScan.queuedButDeleted(items, emptySet(), false).isEmpty())
        assertEquals(2, PhotoChangeScan.queuedButDeleted(items, emptySet(), true).size)
    }
}

class UploadPolicyTest {
    @Test fun screenCopyOnlyForBigOrRawPhotos() {
        assertFalse(ScreenCopyPolicy.shouldMake(item().copy(fileSize = 2L shl 20)))
        assertTrue(ScreenCopyPolicy.shouldMake(item().copy(fileSize = 3L shl 20)))
        assertTrue(ScreenCopyPolicy.shouldMake(item(name = "a.DNG").copy(fileSize = 100)))
        assertFalse(ScreenCopyPolicy.shouldMake(item(kind = ItemKind.Video).copy(fileSize = 30L shl 20)))
        assertFalse(ScreenCopyPolicy.shouldMake(item().copy(fileSize = 30L shl 20, screenCopySkipped = true)))
        val withCopy = item().copy(fileSize = 30L shl 20).withParts("d", listOf(RemoteFile(2, "f", "u", 5)), 1)
        assertFalse(ScreenCopyPolicy.shouldMake(withCopy))
        assertTrue(ScreenCopyPolicy.isWorthKeeping(50, 100))
        assertFalse(ScreenCopyPolicy.isWorthKeeping(51, 100))
        assertFalse(ScreenCopyPolicy.isWorthKeeping(0, 0))
    }

    @Test fun encryptedPartNamesFollowTheFormat() {
        assertEquals("abc.o.cge", UploadNames.encrypted("abc", "o", null))
        assertEquals("abc.pv.p002.cge", UploadNames.encrypted("abc", "pv", 1))
    }

    @Test fun spaceForTheLargestPart() {
        val limit = PartLayout.STANDARD_LIMIT
        assertEquals(FileCrypto.encryptedSize(10), UploadNames.spaceNeeded(listOf(10, 5), limit))
        // A 3 GB video needs one 1,999 MiB part on disk, not the whole file.
        assertEquals(PartLayout.partSize(limit), UploadNames.spaceNeeded(listOf(3_000L shl 20), limit))
    }

    @Test fun resumeKeptOnlyWhileIncomplete() {
        val point = FileCrypto.ResumePoint(100, 1 shl 20, ByteArray(16) { 1 }, ByteArray(12) { 2 }, "hash")
        val half = item().withParts("o", listOf(RemoteFile(1, "f", "u", 100)), 2, point)
        assertEquals(point, half.uploadResume["o"])
        val done = half.withParts("o", listOf(RemoteFile(1, "f", "u", 100), RemoteFile(2, "g", "v", 50)), 2, point)
        assertTrue(done.uploadResume.isEmpty())
    }

    @Test fun jobFieldsSurviveTheIndex() {
        val point = FileCrypto.ResumePoint(100, 1 shl 20, ByteArray(16) { 1 }, null, "hash")
        val original = item(chosen = true).copy(attempts = 2, notBefore = 5, assetModifiedAt = 7, screenCopySkipped = true, streamingCopySkipped = true)
            .withParts("o", listOf(RemoteFile(1, "f", "u", 100)), 3, point)
        val back = ItemExtras.apply(original.copy(chosen = false, attempts = 0, uploadResume = emptyMap()), ItemExtras.decode(ItemExtras.encode(original)))
        assertEquals(original, back)
    }
}

class FreeUpSpaceTest {
    private val day = 86_400_000L
    private fun done() = item(status = ItemStatus.BackedUp).withParts("o", listOf(RemoteFile(1, "f", "u", 10)), 1)
        .withParts("t", listOf(RemoteFile(2, "g", "v", 5)), 1).copy(encrypted = true, assetModifiedAt = 1_000_000)

    @Test fun onlyCompleteLinkedItemsAreOffered() {
        assertTrue(FreeUpSpace.isCandidate(done()))
        assertFalse(FreeUpSpace.isCandidate(done().copy(localId = null)))
        assertFalse(FreeUpSpace.isCandidate(done().copy(status = ItemStatus.Trashed)))
        // Encrypted with no thumbnail in the cloud: not complete.
        assertFalse(FreeUpSpace.isCandidate(done().copy(parts = done().parts - "t")))
    }

    @Test fun aChangedPhotoIsKept() {
        assertFalse(FreeUpSpace.mayHaveChanged(done(), 10, 1_000_000))
        assertFalse(FreeUpSpace.mayHaveChanged(done(), 10, 1_060_000))
        assertTrue(FreeUpSpace.mayHaveChanged(done(), 10, 1_060_001))
        assertTrue(FreeUpSpace.mayHaveChanged(done(), 11, 1_000_000))
        // Linked after a reinstall (no date): the same size is the same file.
        assertFalse(FreeUpSpace.mayHaveChanged(done().copy(assetModifiedAt = null), 10, 9_999_999))
    }

    @Test fun aCheckLastsADay() {
        val checked = done().copy(verifiedAt = 5 * day)
        assertTrue(FreeUpSpace.isFreshlyVerified(checked, 5 * day + 1))
        assertFalse(FreeUpSpace.isFreshlyVerified(checked, 6 * day))
        assertFalse(FreeUpSpace.isFreshlyVerified(checked, 4 * day))
        assertFalse(FreeUpSpace.isFreshlyVerified(done(), 5 * day))
    }
}

class CloudDuplicateTest {
    private fun up(id: String, sha: String, local: String?, uploaded: Long?) =
        LibraryItem(id, local, sha, "$id.jpg", ItemKind.Photo, 1, fileSize = 10, status = ItemStatus.BackedUp, uploadedAt = uploaded)

    @Test fun keepsThePhoneLinkedOneElseTheOldest() {
        val groups = CloudDuplicateGroup.find(
            listOf(up("a", "h", null, 1), up("b", "h", "P", 5), up("c", "h", null, 3), up("d", "x", null, 1), up("e", "", null, 1), up("f", "", null, 2)),
            onPhone = setOf("P"),
        )
        assertEquals(1, groups.size)
        assertEquals("b", groups[0].keep.id)
        assertEquals(listOf("a", "c"), groups[0].extras.map { it.id })
        assertEquals(20, groups[0].wastedBytes)
        assertEquals("a", CloudDuplicateGroup.find(listOf(up("c", "h", null, 3), up("a", "h", "Q", 1)), emptySet())[0].keep.id)
    }
}
