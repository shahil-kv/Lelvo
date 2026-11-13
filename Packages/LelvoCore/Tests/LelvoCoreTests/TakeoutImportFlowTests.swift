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

    /// The original is already in the library. The edit and the Live Photo video in this same plan still have to
    /// be uploaded on their own. Marking the whole row duplicate would let the zip be deleted first.
    @Test func aDifferentEditOrLivePhotoIsUploadedWhenTheOriginalIsAlreadyBackedUp() {
        let twin = backedUpTwin(edit: nil, paired: nil)
        let edit = TakeoutDuplicateExtras.decide(editedHash: "crop", pairedHash: nil, twin: twin,
                                                backedUpOriginalHashes: ["primary"])
        #expect(edit.edit == .uploadOwnPhoto)
        #expect(edit.mayMarkDuplicate == false)

        let video = TakeoutDuplicateExtras.decide(editedHash: nil, pairedHash: "motion", twin: twin,
                                                 backedUpOriginalHashes: ["primary"])
        #expect(video.pairedVideo == .uploadOwnVideo)
        #expect(video.mayMarkDuplicate == false)

        let otherCrop = TakeoutDuplicateExtras.decide(editedHash: "crop", pairedHash: "motion",
                                                     twin: backedUpTwin(edit: "other", paired: nil),
                                                     backedUpOriginalHashes: ["primary"])
        #expect(otherCrop.edit == .uploadOwnPhoto)
        #expect(otherCrop.pairedVideo == .uploadOwnVideo)
        #expect(otherCrop.mayMarkDuplicate == false)
    }

    /// An attached edit stays one item until this import actually uploads it on its own. The delete dialog
    /// reads that list back after a relaunch.
    @Test func onlyFilesUploadedOnTheirOwnAreListedSeparately() {
        var item = plannedItem()
        let edited = TakeoutSourceEntry(sourceId: "A", entry: ZipEntry(
            path: "Takeout/Google Photos/Photos from 2019/IMG_1-edited.jpg",
            compressedSize: 10, size: 10, crc32: 2, method: 0, localHeaderOffset: 0, modified: nil))
        let movie = TakeoutSourceEntry(sourceId: "A", entry: ZipEntry(
            path: "Takeout/Google Photos/Photos from 2019/IMG_1.MOV",
            compressedSize: 10, size: 10, crc32: 3, method: 0, localHeaderOffset: 0, modified: nil))
        item.edited = edited
        item.pairedVideo = movie
        #expect(item.entriesUploadedSeparately().isEmpty)
        item.uploadedSeparately = ["IMG_1-edited.jpg"]
        #expect(item.entriesUploadedSeparately() == [edited])
    }

    /// The same bytes on the twin, or already backed up as their own item, are not uploaded again. With nothing
    /// left to send, the row may become a duplicate.
    @Test func anEditOrLivePhotoAlreadyInTheLibraryStaysADuplicate() {
        let twin = backedUpTwin(edit: "crop", paired: "motion")
        let same = TakeoutDuplicateExtras.decide(editedHash: "crop", pairedHash: "motion", twin: twin,
                                                backedUpOriginalHashes: ["primary"])
        #expect(same.edit == .alreadyInLibrary)
        #expect(same.pairedVideo == .alreadyInLibrary)
        #expect(same.mayMarkDuplicate)

        let bare = backedUpTwin(edit: nil, paired: nil)
        let own = TakeoutDuplicateExtras.decide(editedHash: "crop", pairedHash: "motion", twin: bare,
                                               backedUpOriginalHashes: ["primary", "crop", "motion"])
        #expect(own.edit == .alreadyInLibrary)
        #expect(own.pairedVideo == .alreadyInLibrary)
        #expect(own.mayMarkDuplicate)

        let none = TakeoutDuplicateExtras.decide(editedHash: nil, pairedHash: nil, twin: bare,
                                                backedUpOriginalHashes: ["primary"])
        #expect(none.edit == nil)
        #expect(none.pairedVideo == nil)
        #expect(none.mayMarkDuplicate)
    }

    /// The "Imported without a date from Google" list is only the zip entry's modified date. A date from the
    /// file, or from Google's JSON, is a capture date and stays off that list.
    @Test func zipModifiedDateIsTheOnlyUndatedImport() {
        let google = Date(timeIntervalSince1970: 1_500_000_000)
        let file = Date(timeIntervalSince1970: 1_600_000_000)
        let zip = Date(timeIntervalSince1970: 1_700_000_000)

        let fromGoogle = TakeoutDateChoice.choose(google: google, file: file, zipModified: zip,
                                                  allFilesAdded: true, alreadyUploading: false)
        #expect(fromGoogle?.source == .google)
        #expect(fromGoogle?.date == google)
        #expect(!TakeoutDateChoice.importedWithoutGoogleDate(fromGoogle?.source))

        let fromFile = TakeoutDateChoice.choose(google: nil, file: file, zipModified: zip,
                                                allFilesAdded: true, alreadyUploading: false)
        #expect(fromFile?.source == .file)
        #expect(fromFile?.date == file)
        #expect(!TakeoutDateChoice.importedWithoutGoogleDate(fromFile?.source))

        let fromZip = TakeoutDateChoice.choose(google: nil, file: nil, zipModified: zip,
                                               allFilesAdded: true, alreadyUploading: false)
        #expect(fromZip?.source == .zipModified)
        #expect(fromZip?.date == zip)
        #expect(TakeoutDateChoice.importedWithoutGoogleDate(fromZip?.source))

        let resumed = TakeoutDateChoice.choose(google: nil, file: nil, zipModified: zip,
                                               allFilesAdded: false, alreadyUploading: true)
        #expect(resumed?.source == .zipModified)

        let waiting = TakeoutDateChoice.choose(google: nil, file: nil, zipModified: zip,
                                               allFilesAdded: false, alreadyUploading: false)
        #expect(waiting == nil)
        #expect(!TakeoutDateChoice.importedWithoutGoogleDate(nil))
        #expect(!TakeoutDateChoice.importedWithoutGoogleDate(.file))
        #expect(!TakeoutDateChoice.importedWithoutGoogleDate(.google))
    }

    @Test func laterPlanKeepsTheDateThatWasWritten() {
        var item = plannedItem()
        #expect(item.keepingDateUsed(.file).dateUsed == .file)
        item.dateUsed = .zipModified
        #expect(item.keepingDateUsed(.file).dateUsed == .zipModified)
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

    /// The queued note has to be the additions from before the write. Diffing afterwards is empty, which is how a
    /// confirmed part loses a later zip: the caption already in the channel is the one a scan keeps.
    @Test func confirmedPartQueuesAdditionsFromBeforeTheItemIsUpdated() {
        var albums: [String]? = ["Home"]
        var favorite: Bool? = false
        let notes = TakeoutLateNotes.merge(albums: &albums, favorite: &favorite,
                                           plannedAlbums: ["Home", "Goa"], plannedFavorite: true,
                                           hasConfirmedPart: true)
        #expect(notes == [.album("Goa"): true, .favorite: true])
        #expect(albums == ["Goa", "Home"])
        #expect(favorite == true)
        let afterTheWrite = TakeoutLateNotes.additions(existingAlbums: albums ?? [], existingFavorite: favorite == true,
                                                       albums: ["Home", "Goa"], favorite: true)
        #expect(afterTheWrite.isEmpty)

        var keptAlbums: [String]? = ["Home", "Goa"]
        var keptFavorite: Bool? = true
        let nothingRemoved = TakeoutLateNotes.merge(albums: &keptAlbums, favorite: &keptFavorite,
                                                    plannedAlbums: ["Home"], plannedFavorite: false,
                                                    hasConfirmedPart: true)
        #expect(nothingRemoved.isEmpty)
        #expect(keptAlbums == ["Goa", "Home"])
        #expect(keptFavorite == true)
    }

    @Test func noConfirmedPartLeavesTheAlbumsForTheFirstCaption() {
        var albums: [String]? = nil
        var favorite: Bool? = nil
        let notes = TakeoutLateNotes.merge(albums: &albums, favorite: &favorite,
                                           plannedAlbums: ["Goa"], plannedFavorite: true,
                                           hasConfirmedPart: false)
        #expect(notes.isEmpty)
        #expect(albums == ["Goa"])
        #expect(favorite == true)
    }

    private func backedUpTwin(edit: String?, paired: String?) -> MediaItem {
        var item = MediaItem(localIdentifier: nil, sha256: "primary", filename: "IMG_1.jpg", kind: .photo,
                             creationDate: nil, fileSize: 10, status: .backedUp)
        var hashes = ["o": "primary"]
        if let edit { hashes["e"] = edit }
        if let paired { hashes["pv"] = paired }
        item.roleHashes = hashes
        return item
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
