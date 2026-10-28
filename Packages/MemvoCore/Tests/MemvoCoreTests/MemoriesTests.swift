import Foundation
import Testing
import MemvoCore

@Suite struct MemoriesTests {
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12, minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: hour, minute: minute))!
    }

    let home = (9.93, 76.26)      // Kochi
    let work = (10.02, 76.31)     // ~12 km away: a second base
    let away = (15.49, 73.82)     // Goa, ~600 km

    func at(_ id: String, _ date: Date, _ place: (Double, Double)?) -> Memories.Photo {
        Memories.Photo(id: id, date: date, latitude: place?.0, longitude: place?.1)
    }

    /// Four months of everyday photos at home and at work (January to April 2025): both are bases.
    var everyday: [Memories.Photo] {
        (0..<120).flatMap { d -> [Memories.Photo] in
            let date = day(2025, 1, 1).addingTimeInterval(Double(d) * 86400)
            return [at("h\(d)", date, home), at("w\(d)", date.addingTimeInterval(3600), work)]
        }
    }

    @Test func onThisDayGroupsEarlierYearsMostRecentFirst() {
        let photos = [
            Memories.Photo(id: "a", date: day(2023, 10, 28)), Memories.Photo(id: "b", date: day(2023, 10, 28, hour: 18)),
            Memories.Photo(id: "b2", date: day(2023, 10, 28, hour: 20)),
            Memories.Photo(id: "c", date: day(2021, 10, 28)), Memories.Photo(id: "d", date: day(2021, 10, 28, hour: 9)),
            Memories.Photo(id: "d2", date: day(2021, 10, 28, hour: 7)),
            Memories.Photo(id: "e", date: day(2022, 10, 28)),          // only one: not enough
            Memories.Photo(id: "f", date: day(2026, 10, 28)), Memories.Photo(id: "g", date: day(2026, 10, 28)), // this year
        ]
        let found = Memories.onThisDay(photos, today: day(2026, 10, 28), calendar: cal)
        #expect(found.map(\.kind) == [.onThisDay(yearsAgo: 3), .onThisDay(yearsAgo: 5)])
        #expect(found[0].allIds == ["a", "b", "b2"])
        #expect(found[1].allIds == ["d2", "d", "c"])
    }

    @Test func homeAndWorkAreBothBases() {
        #expect(Memories.bases(everyday, calendar: cal).count == 2)
        // A week somewhere isn't a base, however many photos.
        let week = (0..<200).map { at("x\($0)", day(2025, 5, 1).addingTimeInterval(Double($0) * 3000), away) }
        #expect(Memories.bases(everyday + week, calendar: cal).count == 2)
    }

    @Test func aFewDaysFarFromEveryBaseIsATrip() {
        var photos = everyday
        let trip = (0..<30).map { at("t\($0)", day(2025, 6, 10).addingTimeInterval(Double($0) * 4 * 3600), away) }
        photos += trip
        photos.append(at("noloc", day(2025, 6, 11, hour: 1), nil))
        photos.append(at("back", day(2025, 6, 16), home))
        let trips = Memories.trips(photos, calendar: cal)
        #expect(trips.count == 1)
        #expect(trips.first?.allIds.count == 31)
        #expect(trips.first?.allIds.contains("noloc") == true)
        #expect(trips.first?.ids.count == Memories.storyLength)
        #expect(trips.first?.placeCell == SearchMatcher.placeCell(latitude: away.0, longitude: away.1))
    }

    @Test func goingToWorkOrADayOutIsNotATrip() {
        var photos = everyday
        // A busy day out: many photos, one day only.
        photos += (0..<40).map { at("o\($0)", day(2025, 2, 20, hour: 8, minute: $0 * 10), away) }
        // Too few photos over several days.
        photos += (0..<10).map { at("s\($0)", day(2025, 4, 1).addingTimeInterval(Double($0) * 86400 / 3), away) }
        #expect(Memories.trips(photos, calendar: cal).isEmpty)
    }

    @Test func noBasesMeansNoTrips() {
        let photos = (0..<40).map { at("t\($0)", day(2025, 3, 10).addingTimeInterval(Double($0) * 3600), away) }
        #expect(Memories.trips(photos, calendar: cal).isEmpty)
    }

    @Test func selectionIsSpreadOutAndSkipsBursts() {
        let burst = (0..<100).map { Memories.Photo(id: "b\($0)", date: day(2025, 1, 1).addingTimeInterval(Double($0))) }
        let spread = (0..<100).map { Memories.Photo(id: "s\($0)", date: day(2025, 1, 2).addingTimeInterval(Double($0) * 3600)) }
        #expect(Memories.select(burst).count == 1)
        let picked = Memories.select(spread)
        #expect(picked.count == Memories.storyLength)
        #expect(picked.first?.id == "s0")
        #expect(Memories.select(Array(spread.prefix(5))).count == 5)
    }

    @Test func themesNeedEnoughPhotosOnEnoughDays() {
        let dogs = (0..<15).map { Memories.Photo(id: "d\($0)", date: day(2025, 6, 1 + $0 % 5, hour: 9 + $0), things: ["dog", "grass"]) }
        let snowOneDay = (0..<20).map { Memories.Photo(id: "s\($0)", date: day(2025, 1, 5, hour: 8, minute: $0), things: ["snow"]) }
        let themes = Memories.themes(dogs + snowOneDay, calendar: cal)
        #expect(themes.map(\.kind) == [.theme(.dogs)])
        #expect(themes[0].allIds.count == 15)
    }

    @Test func recentHighlightsAreTheLastMonth() {
        let today = day(2026, 10, 28)
        let recent = (0..<14).map { Memories.Photo(id: "r\($0)", date: today.addingTimeInterval(-Double($0) * 86400)) }
        let old = (0..<30).map { Memories.Photo(id: "o\($0)", date: day(2025, 1, 1).addingTimeInterval(Double($0) * 86400)) }
        #expect(Memories.recent(recent + old, today: today, calendar: cal)?.allIds.count == 14)
        #expect(Memories.recent(old, today: today, calendar: cal) == nil)
    }

    @Test func bestLookingPhotosArePickedAndCoverIt() {
        // 40 photos an hour apart: each bucket of two holds a better one.
        let photos = (0..<40).map { i in
            Memories.Photo(id: "p\(i)", date: day(2025, 1, 1).addingTimeInterval(Double(i) * 3600), score: i % 2 == 1 ? 0.5 : -0.5)
        }
        let picked = Memories.select(photos)
        #expect(picked.count == 20)
        #expect(picked.allSatisfy { $0.score == 0.5 })
        let best = Memories.Photo(id: "best", date: day(2025, 3, 1), score: 0.9)
        let m = Memories.recent(Array(photos.prefix(12)) + [best], today: day(2025, 3, 2), calendar: cal)
        #expect(m == nil) // the 12 are more than 30 days before
        let all = Memories.all(photos.map { Memories.Photo(id: $0.id, date: day(2025, 2, 20).addingTimeInterval(Double($0.id.dropFirst())! * 3600), score: $0.score) } + [best],
                               today: day(2025, 3, 2), calendar: cal)
        #expect(all.first?.kind == .recent)
        #expect(all.first?.cover == "best")
    }

    @Test func screenshotsAndDocumentsNeverMakeAMemory() {
        let today = day(2026, 10, 28)
        let docs = (0..<20).map { Memories.Photo(id: "x\($0)", date: today.addingTimeInterval(-Double($0) * 86400), isUtility: true) }
        #expect(Memories.all(docs, today: today, calendar: cal).isEmpty)
    }

    /// Seven weeks abroad with photos on ten scattered days (gaps up to 17 days): one long stay, not a second home and
    /// not nothing. The everyday photos span three months so home is a base.
    @Test func aLongStayAbroadIsOneMemory() {
        let dubai = (25.2, 55.27)
        var photos = (0..<100).flatMap { d -> [Memories.Photo] in
            let date = day(2024, 2, 1).addingTimeInterval(Double(d) * 86400)
            return d >= 99 ? [] : [at("h\(d)", date, home)]
        }
        photos = photos.filter { $0.date < day(2024, 5, 9) } + photos.filter { $0.date > day(2024, 6, 29) }
        photos += (100..<220).map { d in at("h\(d)", day(2024, 2, 1).addingTimeInterval(Double(d) * 86400), home) }.filter { $0.date > day(2024, 6, 29) }
        let days: [(Int, Int, Int)] = [(5, 10, 3), (5, 15, 1), (5, 17, 6), (5, 19, 5), (5, 23, 11), (6, 9, 4), (6, 15, 2), (6, 16, 13), (6, 19, 2), (6, 27, 1)]
        for (m, d, n) in days {
            photos += (0..<n).map { i in at("d\(m)-\(d)-\(i)", day(2024, m, d, hour: 9 + i % 12, minute: i), dubai) }
        }
        #expect(Memories.bases(photos, calendar: cal).count == 1)
        let trips = Memories.trips(photos, calendar: cal)
        #expect(trips.count == 1)
        #expect(trips.first?.allIds.count == 48)
        #expect(trips.first?.placeCell?.hasPrefix("25.") == true)
    }

    /// A day out 40 km from home and a trip nearby two weeks later, with no photos at home between: two outings, and
    /// the day out is too small to be a memory.
    @Test func nearbyOutingsWeeksApartAreSeparate() {
        let dayOut = (home.0 + 0.3, home.1 + 0.2)
        let hills = (home.0 + 1.5, home.1 + 0.4)
        var photos = everyday
        photos += (0..<9).map { at("o\($0)", day(2025, 6, 10, hour: 9 + $0), dayOut) }
        photos += (0..<30).map { at("t\($0)", day(2025, 6, 23).addingTimeInterval(Double($0) * 3 * 3600), hills) }
        let trips = Memories.trips(photos, calendar: cal)
        #expect(trips.count == 1)
        #expect(trips.first?.allIds.allSatisfy { $0.hasPrefix("t") } == true)
    }

    /// Photos every few hours while driving through towns 100–200 km apart: one trip, however many places.
    @Test func aRoadTripThroughSeveralTownsIsOneTrip() {
        var photos = everyday
        let towns = [(12.97, 77.59), (12.30, 76.64), (11.41, 76.70), (10.09, 77.06)] // ~150 km apart each
        for (t, town) in towns.enumerated() {
            photos += (0..<8).map { i in at("r\(t)-\(i)", day(2025, 6, 10 + t, hour: 8 + i), town) }
        }
        let trips = Memories.trips(photos, calendar: cal)
        #expect(trips.count == 1)
        #expect(trips.first?.allIds.count == 32)
    }

    /// Two holidays in different far-away places three weeks apart, with no photos at home in between: two trips.
    @Test func differentPlacesWeeksApartAreTwoTrips() {
        var photos = everyday
        photos += (0..<25).map { at("a\($0)", day(2025, 6, 10).addingTimeInterval(Double($0) * 4 * 3600), (15.49, 73.82)) }
        photos += (0..<25).map { at("b\($0)", day(2025, 7, 1).addingTimeInterval(Double($0) * 4 * 3600), (13.75, 100.50)) }
        let trips = Memories.trips(photos, calendar: cal)
        #expect(trips.count == 2)
        #expect(Set(trips.compactMap { $0.allIds.first?.prefix(1) }) == ["a", "b"])
    }

    /// Two months of holiday photos every day in one city: a long stay, never a second home (too few months).
    @Test func aLongHolidayIsNotAHome() {
        let away = (41.39, 2.17)
        let holiday = (0..<60).map { d in at("x\(d)", day(2025, 8, 1).addingTimeInterval(Double(d) * 86400), away) }
        #expect(Memories.bases(everyday + holiday, calendar: cal).count == 2)
        let trips = Memories.trips(everyday + holiday, calendar: cal)
        #expect(trips.count == 1)
        #expect(trips.first?.allIds.count == 60)
    }
}
