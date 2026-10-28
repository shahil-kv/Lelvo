import Foundation

/// On-device Memories (#12), the kinds Apple and Google Photos make without people: "N years ago" on this day, recent
/// highlights, trips, and themes (pets, beaches, snow, celebrations…). The trip rules follow Ente's open-source trip
/// calculator: a trip is a run of photos far from every place you often are (home, work, family: "bases"), over two
/// days or more. Only what's already on the device is used: dates, locations, and the things and quality score
/// Vision found while reading photos for search.
public enum Memories {
    public struct Photo: Equatable, Sendable {
        public let id: String
        public let date: Date
        public let latitude: Double?
        public let longitude: Double?
        /// Vision's labels for the photo (`VNClassifyImageRequest` identifiers).
        public let things: [String]
        /// Vision's aesthetics score (-1…1), when known.
        public let score: Double?
        /// A screenshot, receipt or document (Vision's "utility" photos): never part of a memory.
        public let isUtility: Bool

        public init(id: String, date: Date, latitude: Double? = nil, longitude: Double? = nil,
                    things: [String] = [], score: Double? = nil, isUtility: Bool = false) {
            self.id = id
            self.date = date
            self.latitude = latitude
            self.longitude = longitude
            self.things = things
            self.score = score
            self.isUtility = isUtility
        }

        var location: (Double, Double)? {
            guard let latitude, let longitude, !(latitude == 0 && longitude == 0) else { return nil }
            return (latitude, longitude)
        }
    }

    public enum Kind: Equatable, Sendable {
        case onThisDay(yearsAgo: Int)
        case trip
        case recent
        case theme(Theme)
    }

    /// Themes like Google Photos' themed memories, from Vision's labels.
    public enum Theme: String, CaseIterable, Sendable {
        case dogs, cats, beach, snow, food, celebrations, mountains, sunsets, flowers

        public var title: String {
            switch self {
            case .dogs: return "Dogs"
            case .cats: return "Cats"
            case .beach: return "At the Beach"
            case .snow: return "Snow Days"
            case .food: return "Good Food"
            case .celebrations: return "Celebrations"
            case .mountains: return "Mountains"
            case .sunsets: return "Sunsets"
            case .flowers: return "Flowers"
            }
        }

        public var labels: Set<String> {
            switch self {
            case .dogs: return ["dog", "canine", "bulldog", "sheepdog"]
            case .cats: return ["cat", "feline", "adult_cat"]
            case .beach: return ["beach", "shore", "ocean"]
            case .snow: return ["snow", "snowman", "skiing", "snowboarding"]
            case .food: return ["food", "dessert", "seafood"]
            case .celebrations: return ["birthday_cake", "celebration", "fireworks", "wedding", "christmas_tree", "christmas_decoration"]
            case .mountains: return ["mountain", "hiking"]
            case .sunsets: return ["sunset_sunrise"]
            case .flowers: return ["flower", "flower_arrangement"]
            }
        }
    }

    public struct Memory: Equatable, Sendable, Identifiable {
        public let kind: Kind
        /// The photos the memory plays, oldest first: a few, spread over it (`select`).
        public let ids: [String]
        /// Every photo of the memory, oldest first (Show All).
        public let allIds: [String]
        public let start: Date
        public let end: Date
        /// The photo to show for it: the best-looking one, else the middle one.
        public let cover: String
        /// The `SearchMatcher.placeCell` most of its photos were taken in, for naming a trip.
        public let placeCell: String?
        public var id: String { "\(kind)-\(allIds.first ?? "")" }
    }

    // How trips are found. The values are Ente's (smart_memories_trip_calculator_v2.dart) unless noted.
    //
    // 1. Home places ("bases"): places you keep coming back to. A ~1 km area counts when it has photos on 10+ days,
    //    in 6+ different weeks and 2+ months, with 12 of those days inside some 120-day window, spread over more than
    //    90 days. Ente asks for 45 days, which made two months of holiday photos a "home"; ours matches the longest
    //    trip, so a place you stayed less than three months and left is a trip, never a home.
    // 2. Away: photos more than 10 km from every home place, in time order. Coming home ends a trip.
    // 3. A quiet stretch ends a trip only if the next photo is somewhere else (more than 25 km, Ente's trip radius,
    //    from the middle of the trip so far): two outings to different places weeks apart stay two, while a long stay
    //    with quiet weeks stays one. Ente ends a trip after 15 quiet days wherever you are, which split long stays
    //    abroad. (Ours.)
    // 4. Moving on keeps the trip while photos keep coming: up to 2 days between them and 800 km between places
    //    (a road trip through several towns).
    // 5. A trip has 20+ photos with a location over 2+ calendar days (Ente asks for 48 hours, which dropped
    //    weekend trips; ours) and at most 90 days (Ente: 30; ours, for long stays).
    public static let baseRadiusKilometres = 10.0
    public static let baseMinimumDays = 10
    public static let baseMinimumWeeks = 6
    public static let baseMinimumMonths = 2
    public static let baseMinimumSpanDays = 91
    public static let baseDenseDays = 12
    public static let baseDenseWindowDays = 120
    public static let sameAreaKilometres = 25.0
    public static let movingGapDays = 2.0
    public static let movingHopKilometres = 800.0
    public static let tripMinimumPhotos = 20
    public static let tripDays = 2...90
    /// Longer than this, a trip is titled as a stay ("Time in Lisbon").
    public static let longStayDays = 14
    /// A memory plays at most this many photos, at least `selectionGap` apart.
    public static let storyLength = 20
    public static let selectionGap: TimeInterval = 10 * 60
    /// A theme or recent highlights need this many photos, on at least `minimumDays` different days.
    public static let minimumPhotos = 12
    public static let minimumDays = 3
    public static let recentDays = 30

    /// Everything to show, in the order the Memories screen lists them: on this day, recent highlights, trips, themes.
    public static func all(_ photos: [Photo], today: Date, calendar: Calendar = .current, kinds: Set<KindFilter> = Set(KindFilter.allCases)) -> [Memory] {
        let usable = photos.filter { !$0.isUtility }
        var out: [Memory] = []
        if kinds.contains(.onThisDay) { out += onThisDay(usable, today: today, calendar: calendar) }
        if kinds.contains(.recent), let r = recent(usable, today: today, calendar: calendar) { out.append(r) }
        if kinds.contains(.trips) { out += trips(usable, calendar: calendar) }
        if kinds.contains(.themes) { out += themes(usable, calendar: calendar) }
        return out
    }

    /// The memory types a user can turn off, like Google Photos' settings.
    public enum KindFilter: String, CaseIterable, Sendable {
        case onThisDay, recent, trips, themes
    }

    /// The best of the last `recentDays` days.
    public static func recent(_ photos: [Photo], today: Date, calendar: Calendar = .current) -> Memory? {
        let since = today.addingTimeInterval(-Double(recentDays) * 86400)
        let list = photos.filter { $0.date >= since && $0.date <= today }
        guard list.count >= minimumPhotos, Set(list.map { calendar.startOfDay(for: $0.date) }).count >= minimumDays else { return nil }
        return memory(.recent, list)
    }

    /// One memory per theme with enough photos over enough days, the biggest first.
    public static func themes(_ photos: [Photo], calendar: Calendar = .current) -> [Memory] {
        Theme.allCases.compactMap { theme -> Memory? in
            let list = photos.filter { !Set($0.things).isDisjoint(with: theme.labels) }
            guard list.count >= minimumPhotos, Set(list.map { calendar.startOfDay(for: $0.date) }).count >= minimumDays else { return nil }
            return memory(.theme(theme), list)
        }
        .sorted { $0.allIds.count > $1.allIds.count }
    }

    /// Photos taken on today's month and day in earlier years, one memory per year, most recent year first.
    public static func onThisDay(_ photos: [Photo], today: Date, calendar: Calendar = .current, minimumPhotos: Int = 3) -> [Memory] {
        let now = calendar.dateComponents([.year, .month, .day], from: today)
        guard let thisYear = now.year else { return [] }
        var byYear: [Int: [Photo]] = [:]
        for p in photos {
            let c = calendar.dateComponents([.year, .month, .day], from: p.date)
            guard let year = c.year, year < thisYear, c.month == now.month, c.day == now.day else { continue }
            byYear[year, default: []].append(p)
        }
        return byYear.filter { $0.value.count >= minimumPhotos }.sorted { $0.key > $1.key }.map { year, list in
            memory(.onThisDay(yearsAgo: thisYear - year), list)
        }
    }

    /// The ~1 km areas of the places you keep coming back to (rule 1). Each place is judged with everything within
    /// `baseRadiusKilometres` of its busiest ~1 km area (your town, not one street): a small library has photos from
    /// home spread over many streets, each too few on its own.
    public static func bases(_ photos: [Photo], calendar: Calendar = .current) -> [(Double, Double)] {
        struct Area { var days = Set<Date>(); var lat = 0.0; var lon = 0.0; var n = 0.0 }
        var areas: [String: Area] = [:]
        for p in photos {
            guard let (lat, lon) = p.location else { continue }
            let key = SearchMatcher.placeCell(latitude: lat, longitude: lon)
            var a = areas[key] ?? Area()
            a.days.insert(calendar.startOfDay(for: p.date))
            a.lat += lat; a.lon += lon; a.n += 1
            areas[key] = a
        }
        var unassigned = areas.sorted { ($0.value.days.count, $1.key) > ($1.value.days.count, $0.key) }
            .map { (centre: ($0.value.lat / $0.value.n, $0.value.lon / $0.value.n), area: $0.value) }
        var bases: [(Double, Double)] = []
        while let seed = unassigned.first {
            let region = unassigned.filter { kilometres(seed.centre, $0.centre) < baseRadiusKilometres }
            unassigned.removeAll { kilometres(seed.centre, $0.centre) < baseRadiusKilometres }
            let days = region.reduce(into: Set<Date>()) { $0.formUnion($1.area.days) }
            // Every ~1 km area of a home place counts, so "near home" means near any of its streets, not its middle.
            if isHome(days.sorted(), calendar: calendar) { bases += region.map(\.centre) }
        }
        return bases
    }

    /// Ente's base test on the days an area has photos.
    static func isHome(_ days: [Date], calendar: Calendar) -> Bool {
        guard days.count >= baseMinimumDays, let first = days.first, let last = days.last,
              last.timeIntervalSince(first) >= Double(baseMinimumSpanDays) * 86400 else { return false }
        let weeks = Set(days.map { calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: $0) })
        let months = Set(days.map { calendar.dateComponents([.year, .month], from: $0) })
        guard weeks.count >= baseMinimumWeeks, months.count >= baseMinimumMonths else { return false }
        var start = 0
        for end in days.indices {
            while days[end].timeIntervalSince(days[start]) > Double(baseDenseWindowDays) * 86400 { start += 1 }
            if end - start + 1 >= baseDenseDays { return true }
        }
        return false
    }

    /// Trips (rules 2–5), newest first. No home places (too few photos with a location) means no trips.
    public static func trips(_ photos: [Photo], calendar: Calendar = .current) -> [Memory] {
        let bases = bases(photos, calendar: calendar)
        guard !bases.isEmpty else { return [] }
        var trips: [Memory] = []
        var run: [Photo] = []
        var area = (lat: 0.0, lon: 0.0, n: 0.0)
        // Photos without a location taken during a trip (sent by friends, location off) belong to it too.
        let unplaced = photos.filter { $0.location == nil }.sorted { $0.date < $1.date }
        func close() {
            defer { run = []; area = (0, 0, 0) }
            guard run.count >= tripMinimumPhotos, let first = run.first?.date, let last = run.last?.date else { return }
            let days = (calendar.dateComponents([.day], from: calendar.startOfDay(for: first), to: calendar.startOfDay(for: last)).day ?? 0) + 1
            guard tripDays.contains(days) else { return }
            let centre = (area.lat / area.n, area.lon / area.n)
            guard bases.allSatisfy({ kilometres($0, centre) >= baseRadiusKilometres }) else { return }
            trips.append(memory(.trip, run + unplaced.filter { $0.date >= first && $0.date <= last }))
        }
        for p in photos.sorted(by: { $0.date < $1.date }) {
            guard let location = p.location else { continue }
            if bases.contains(where: { kilometres($0, location) < baseRadiusKilometres }) {
                close()
                continue
            }
            if let last = run.last, let lastLocation = last.location {
                let gap = p.date.timeIntervalSince(last.date) / 86400
                let centre = (area.lat / area.n, area.lon / area.n)
                let moving = gap <= movingGapDays && kilometres(lastLocation, location) <= movingHopKilometres
                let stillThere = kilometres(centre, location) <= sameAreaKilometres
                let tooLong = p.date.timeIntervalSince(run[0].date) > Double(tripDays.upperBound) * 86400
                if tooLong || !(moving || stillThere) { close() }
            }
            run.append(p)
            area = (area.lat + location.0, area.lon + location.1, area.n + 1)
        }
        close()
        return trips.reversed()
    }

    /// Up to `storyLength` photos spread over the memory, like Ente's time buckets: the memory is cut into equal runs
    /// and the best-looking photo of each is taken (the first when no scores are known), at least `selectionGap` after
    /// the one before so a burst shows once.
    public static func select(_ photos: [Photo], limit: Int = storyLength, gap: TimeInterval = selectionGap) -> [Photo] {
        let ordered = photos.sorted { $0.date < $1.date }
        guard ordered.count > limit else { return ordered }
        var picked: [Photo] = []
        let step = Double(ordered.count) / Double(limit)
        for i in 0..<limit {
            let bucket = ordered[Int(Double(i) * step) ..< min(ordered.count, Int(Double(i + 1) * step))]
            let candidates = bucket.filter { p in picked.last.map { p.date.timeIntervalSince($0.date) >= gap } ?? true }
            guard let best = candidates.max(by: { ($0.score ?? -2, $1.date) < ($1.score ?? -2, $0.date) }) else { continue }
            picked.append(best)
        }
        return picked
    }

    private static func memory(_ kind: Kind, _ list: [Photo]) -> Memory {
        let ordered = list.sorted { $0.date < $1.date }
        var cells: [String: Int] = [:]
        for p in ordered { if let (lat, lon) = p.location { cells[SearchMatcher.placeCell(latitude: lat, longitude: lon), default: 0] += 1 } }
        let story = select(ordered)
        let cover = story.filter { $0.score != nil }.max { $0.score! < $1.score! } ?? story[story.count / 2]
        return Memory(kind: kind, ids: story.map(\.id), allIds: ordered.map(\.id), start: ordered.first!.date, end: ordered.last!.date,
                      cover: cover.id, placeCell: cells.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key)
    }

    static func kilometres(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
        let r = 6371.0, rad = Double.pi / 180
        let dLat = (b.0 - a.0) * rad, dLon = (b.1 - a.1) * rad
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.0 * rad) * cos(b.0 * rad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}
