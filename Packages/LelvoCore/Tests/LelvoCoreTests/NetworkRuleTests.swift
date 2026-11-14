import Testing
@testable import LelvoCore

@Suite struct NetworkRuleTests {
    private func rule(wifiOnly: Bool = true, photos: Bool = true, expensive: Bool = false, lowData: Bool = false) -> NetworkRule.Allowance {
        NetworkRule.allowance(wifiOnly: wifiOnly, photosOnMobile: photos, expensive: expensive, lowDataMode: lowData)
    }

    @Test func wifiOnlyOffSendsEverythingAnywhere() {
        #expect(rule(wifiOnly: false, expensive: true) == .everything)
        #expect(rule(wifiOnly: false, photos: false, expensive: true, lowData: true) == .everything)
    }

    @Test func wifiSendsEverything() {
        #expect(rule() == .everything)
    }

    @Test func mobileDataSendsPhotosOnlyWhenAllowed() {
        #expect(rule(expensive: true) == .photosOnly)
        #expect(rule(photos: false, expensive: true) == .nothing)
    }

    @Test func lowDataModeWaits() {
        #expect(rule(lowData: true) == .nothing)
        #expect(rule(expensive: true, lowData: true) == .nothing)
    }
}
