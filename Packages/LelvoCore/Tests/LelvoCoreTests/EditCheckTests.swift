import Foundation
import Testing
import LelvoCore

@Suite struct EditCheckTests {
    let backup = Date(timeIntervalSince1970: 1_000_000)

    @Test func uploadsAnEditMadeAfterTheBackup() {
        #expect(EditCheck.needsUpload(phoneHasEdit: true, modified: backup.addingTimeInterval(3600), backedUpAt: backup))
        #expect(!EditCheck.needsUpload(phoneHasEdit: true, modified: backup, backedUpAt: backup))
        #expect(!EditCheck.needsUpload(phoneHasEdit: false, modified: backup.addingTimeInterval(3600), backedUpAt: backup))
    }

    /// The case that lost a crop: the date was gone, so the edit was never looked at.
    @Test func checksWhenTheBackupDateIsUnknown() {
        #expect(EditCheck.needsUpload(phoneHasEdit: true, modified: backup, backedUpAt: nil))
    }

    @Test func freeUpSpaceKeepsPhotosWhoseEditMayBeMissing() {
        #expect(EditCheck.mayLoseEdit(cloudHasEdit: false, phoneHasEdit: true, modified: nil, backedUpAt: backup))
        #expect(EditCheck.mayLoseEdit(cloudHasEdit: true, phoneHasEdit: true, modified: backup, backedUpAt: nil))
        #expect(EditCheck.mayLoseEdit(cloudHasEdit: true, phoneHasEdit: true, modified: backup.addingTimeInterval(3600), backedUpAt: backup))
        #expect(!EditCheck.mayLoseEdit(cloudHasEdit: true, phoneHasEdit: true, modified: backup.addingTimeInterval(30), backedUpAt: backup))
        #expect(!EditCheck.mayLoseEdit(cloudHasEdit: false, phoneHasEdit: false, modified: nil, backedUpAt: nil))
    }

    /// A scan rebuilds items from the channel; what only the device knows must survive it.
    @Test func scansKeepWhatOnlyThisDeviceKnows() {
        var local = MediaItem(localIdentifier: "PHONE/1", sha256: "h", filename: "a.jpg", kind: .photo, creationDate: nil, fileSize: 1, status: .backedUp)
        local.uploadedAt = backup
        local.assetModifiedAt = backup.addingTimeInterval(5)
        local.verifiedAt = backup
        local.extrasChecked = true
        var scanned = local
        scanned.localIdentifier = nil
        scanned.uploadedAt = nil
        scanned.assetModifiedAt = nil
        scanned.verifiedAt = nil
        scanned.extrasChecked = nil
        let merged = scanned.keepingLocalState(from: local)
        #expect(merged.localIdentifier == "PHONE/1")
        #expect(merged.uploadedAt == backup)
        #expect(merged.assetModifiedAt == backup.addingTimeInterval(5))
        #expect(merged.verifiedAt == backup)
        #expect(merged.extrasChecked == true)
    }
}

@Suite struct EditedDuplicateTests {
    func twin(edit: String?) -> MediaItem {
        var m = MediaItem(localIdentifier: "A", sha256: "orig", filename: "a.jpg", kind: .photo, creationDate: nil, fileSize: 1, status: .backedUp)
        if let edit { m.hasEdit = true; m.roleHashes = ["o": "orig", "e": edit] }
        return m
    }

    @Test func anUneditedCopyIsADuplicate() {
        #expect(Deduplicator.isSamePhoto(editHash: nil, as: twin(edit: nil)))
        #expect(Deduplicator.isSamePhoto(editHash: nil, as: twin(edit: "crop")))
    }

    /// The case that lost a crop: same original, but this copy is cropped and the cloud has no crop.
    @Test func anEditedCopyIsItsOwnPhotoUnlessTheCloudHasThatEdit() {
        #expect(!Deduplicator.isSamePhoto(editHash: "crop", as: twin(edit: nil)))
        #expect(!Deduplicator.isSamePhoto(editHash: "crop", as: twin(edit: "other crop")))
        #expect(Deduplicator.isSamePhoto(editHash: "crop", as: twin(edit: "crop")))
    }
}
