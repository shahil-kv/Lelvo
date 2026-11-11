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
}
