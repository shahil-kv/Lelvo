import Testing
@testable import LelvoCore

@Suite struct LibraryNamesTests {
    @Test func suggestsTheNextFreeName() {
        #expect(LibraryNames.unused("Lelvo Library", taken: []) == "Lelvo Library")
        #expect(LibraryNames.unused("Lelvo Library", taken: ["Family"]) == "Lelvo Library")
        #expect(LibraryNames.unused("Lelvo Library", taken: ["Lelvo Library"]) == "Lelvo Library 2")
        #expect(LibraryNames.unused("Lelvo Library", taken: ["lelvo library ", "Lelvo Library 2"]) == "Lelvo Library 3")
        #expect(LibraryNames.unused("Lelvo Library", taken: ["Lelvo Library 2"]) == "Lelvo Library")
    }

    @Test func wrapsTheNameInTheWarning() {
        #expect(LibraryNames.channelTitle("Lelvo Library") == "🚨 Lelvo Library · Do not delete 🚨")
        #expect(LibraryNames.channelTitle("  Family ") == "🚨 Family · Do not delete 🚨")
        // Never wrapped twice.
        #expect(LibraryNames.channelTitle("🚨 Family · Do not delete 🚨") == "🚨 Family · Do not delete 🚨")
    }

    @Test func titleFitsTelegramsLimit() {
        let long = String(repeating: "a", count: 300)
        #expect(LibraryNames.channelTitle(long).utf16.count <= 128)
    }

    @Test func plainNameDropsTheWarning() {
        #expect(LibraryNames.plain("🚨 Lelvo Library 2 · Do not delete 🚨") == "Lelvo Library 2")
        #expect(LibraryNames.plain("Lelvo Library") == "Lelvo Library")
        #expect(LibraryNames.plain("🚨 Holidays") == "🚨 Holidays")
    }
}
