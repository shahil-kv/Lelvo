import Foundation
import Testing
import LelvoCore

@Suite struct RunHeartbeatTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    @Test func steadyBeatsWithoutProgressAreNotFrozen() {
        // Hashing a big video in the foreground: no bytes go out for minutes, but the app is never suspended.
        var h = RunHeartbeat(startedAt: t0)
        for s in stride(from: 5.0, through: 600, by: 5) { h.beat(at: at(s)) }
        #expect(!h.isFrozen(at: at(600)))
    }

    @Test func suspendedRunThatDoesNotMoveIsFrozen() {
        var h = RunHeartbeat(startedAt: t0)
        h.beat(at: at(5))
        // iOS suspended the app for 15 minutes, then a background refresh woke it.
        h.beat(at: at(905))
        #expect(h.wasSuspended)
        #expect(!h.isFrozen(at: at(906)), "Give a woken run a moment to move again")
        h.beat(at: at(910))
        #expect(h.isFrozen(at: at(918)))
    }

    @Test func runThatMovesAfterWakingIsNotFrozen() {
        var h = RunHeartbeat(startedAt: t0)
        h.beat(at: at(905))
        h.moved(at: at(908))
        h.beat(at: at(913))
        #expect(!h.isFrozen(at: at(960)))
    }

    @Test func freshRunIsNotFrozen() {
        let h = RunHeartbeat(startedAt: t0)
        #expect(!h.isFrozen(at: at(1)))
    }
}
