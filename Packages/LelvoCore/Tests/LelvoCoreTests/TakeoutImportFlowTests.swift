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
}
