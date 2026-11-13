import Foundation
import Testing
@testable import LelvoCore

@Suite struct TakeoutImportFlowTests {
    @Test func pendingItemWithABackedUpTwinIsADuplicate() {
        let action = TakeoutImportStep.next(status: .pending, existingBackedUpTwin: true,
                                            sourceAvailable: true, freeBytes: 10_000, neededBytes: 1)
        #expect(action == .markDuplicate)
    }

    @Test func pendingItemWaitsWhenItsSourceIsGone() {
        let action = TakeoutImportStep.next(status: .pending, existingBackedUpTwin: false,
                                            sourceAvailable: false, freeBytes: 10_000, neededBytes: 1)
        #expect(action == .waitForSource)
    }

    @Test func pendingItemStopsWhenFreeSpaceIsShort() {
        let action = TakeoutImportStep.next(status: .pending, existingBackedUpTwin: false,
                                            sourceAvailable: true, freeBytes: 100, neededBytes: 500)
        #expect(action == .stopForSpace(needed: 400))
    }

    @Test func finishedItemIsSkipped() {
        let action = TakeoutImportStep.next(status: .done, existingBackedUpTwin: false,
                                            sourceAvailable: true, freeBytes: 10_000, neededBytes: 1)
        #expect(action == .skip)
    }

    @Test func uploadInProgressResumes() {
        let action = TakeoutImportStep.next(status: .uploading, existingBackedUpTwin: false,
                                            sourceAvailable: true, freeBytes: 10_000, neededBytes: 1)
        #expect(action == .upload)
    }

    @Test func laneCountLeavesASlotWhileBackupRuns() {
        #expect(TakeoutImportStep.laneCount(backupRunning: true) == 1)
        #expect(TakeoutImportStep.laneCount(backupRunning: false) == 2)
    }

    @Test func failedRowsKeepTheRunOpen() {
        #expect(TakeoutImportStep.openCount([.failed: 2, .done: 3]) == 2)
        #expect(TakeoutImportStep.openCount([.pending: 1, .uploading: 1, .waitingForDetails: 1, .failed: 1]) == 4)
        #expect(TakeoutImportStep.openCount([.done: 1, .duplicate: 4, .skipped: 2]) == 0)
    }

    @Test func lateDetailsAreAddedToAPlannedItem() {
        var item = plannedItem()
        item.albums = ["Home"]
        item.sidecar = TakeoutSidecar(title: "a.jpg", takenAt: Date(timeIntervalSince1970: 10), favorite: true)
        let merged = item.addingLateDetails(albums: ["Goa", "Home"], favorite: false)
        #expect(merged.albums == ["Goa", "Home"])
        #expect(merged.sidecar?.favorite == true)
        #expect(merged.sidecar?.title == "a.jpg")
        #expect(merged.sidecar?.takenAt == Date(timeIntervalSince1970: 10))
    }

    @Test func lateFavouriteIsRememberedWithoutADate() {
        let merged = plannedItem().addingLateDetails(albums: [], favorite: true)
        #expect(merged.sidecar?.favorite == true)
        #expect(merged.sidecar?.takenAt == nil)
        #expect(merged.albums.isEmpty)
    }

    @Test func notesForABackedUpItemOnlyAdd() {
        let notes = TakeoutLateNotes.additions(existingAlbums: ["Home"], existingFavorite: true,
                                               albums: ["Home", " Goa ", ""], favorite: false)
        #expect(notes == [.album("Goa"): true])
        #expect(notes[.favorite] == nil)
        let favourite = TakeoutLateNotes.additions(existingAlbums: [], existingFavorite: false, albums: [], favorite: true)
        #expect(favourite == [.favorite: true])
    }

    private func plannedItem() -> TakeoutPlannedItem {
        TakeoutPlannedItem(
            key: "k", kind: .photo,
            primary: TakeoutSourceEntry(sourceId: "A", entry: ZipEntry(
                path: "Takeout/Google Photos/Photos from 2019/a.jpg",
                compressedSize: 10, size: 10, crc32: 1, method: 0, localHeaderOffset: 0, modified: nil)),
            pairedVideo: nil, edited: nil, copies: [], albums: [], sidecar: nil, dateSource: .fileWillTell)
    }
}
