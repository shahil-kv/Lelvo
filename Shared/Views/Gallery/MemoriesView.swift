import SwiftUI
import LelvoCore

/// Memories built on the device from the timeline (`Memories`): on this day in earlier years, and trips.
@MainActor
final class MemoriesModel: ObservableObject {
    struct Card: Identifiable, Hashable {
        let memory: Memories.Memory
        let title: String
        let subtitle: String
        var id: String { memory.id }

        static func == (a: Card, b: Card) -> Bool { a.id == b.id && a.memory.allIds == b.memory.allIds }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    @Published private(set) var cards: [Card] = []
    @Published private(set) var loaded = false
    /// Timeline entries by id, built once per library change (looking them up while drawing froze the screen).
    private(set) var entries: [String: GalleryEntry] = [:]
    private var revision = -1
    /// Bumped by every refresh; only the latest one's result is kept (an older one can finish after it).
    private var generation = 0
    private var lastEntries: [GalleryEntry] = []
    private var observers: [NSObjectProtocol] = []

    init() {
        // Place names, labels and scores arrive while photos are read for search, and memory types can be turned off:
        // make the memories again then.
        for name in [SearchService.didIndex, MemoriesSettingsView.didChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.loaded else { return }
                    await self.refresh(entries: self.lastEntries, revision: self.wanted, force: true)
                }
            })
        }
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    /// The newest timeline asked for. One build at a time; a newer one runs when the current one ends.
    private var wanted = -1
    private var building = false
    /// Place names or memory settings changed during a build: build again as soon as it ends.
    private var forceAgain = false
    /// Photos the last build was made from. Upload status is not in here, so a backup doesn't rebuild memories.
    private var lastInputs: [Memories.Photo]?

    /// `force`: the photos are unchanged but place names, things in them, or the memory settings changed.
    func refresh(entries: [GalleryEntry], revision: Int, force: Bool = false) async {
        guard force || revision != self.revision else { return }
        lastEntries = entries
        wanted = revision
        if force { forceAgain = true }
        guard !building else { return }
        building = true
        defer { building = false }
        while true {
            let revision = wanted
            let entries = lastEntries
            let force = forceAgain
            forceAgain = false
            // Reading places for the comparison is the same work as a build's first step, and it stays off the main
            // thread: a backup asks this every second or two.
            let inputs = await Task.detached(priority: .utility) { Self.memoryInputs(entries) }.value
            if Memories.needsRebuild(previous: lastInputs, next: inputs, forced: force) {
                await build(entries: entries, revision: revision, inputs: inputs)
            } else {
                self.revision = revision
            }
            guard forceAgain || wanted != revision else { return }
        }
    }

    private func build(entries: [GalleryEntry], revision: Int, inputs: [Memories.Photo]) async {
        self.revision = revision
        generation += 1
        let mine = generation
        let search = AppEnvironment.shared.search!
        let store = AppEnvironment.shared.store
        var kinds = MemoriesSettingsView.enabled
        // Theme memories are Lelvo Pro (#16E); On This Day / recent / trips stay free.
        let isPro = await MainActor.run { ProStore.shared.isPro }
        if !isPro { kinds.remove(.themes) }
        let started = Date()
        let (cards, byId) = await Task.detached(priority: .utility) {
            (Self.cards(entries, facts: (try? store.photoFacts()) ?? [:], kinds: kinds, search: search),
             Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
        }.value
        guard mine == generation else { return }
        self.entries = byId
        self.cards = cards
        self.lastInputs = inputs
        loaded = true
        appLog(String(format: "Memories: %d (%@) from %d items in %.2f s", cards.count,
                      cards.map(\.title).joined(separator: ", "), entries.count, Date().timeIntervalSince(started)))
    }

    /// Photos only, without the things and scores search fills in later. Those arrive with `SearchService.didIndex`,
    /// which rebuilds with `force`.
    nonisolated private static func memoryInputs(_ entries: [GalleryEntry]) -> [Memories.Photo] {
        entries.compactMap { e in
            guard let date = e.date, !e.isVideo else { return nil }
            let loc = e.asset?.location?.coordinate
            let screenshot = e.asset?.mediaSubtypes.contains(.photoScreenshot) == true
            return Memories.Photo(id: e.id, date: date, latitude: loc?.latitude ?? e.item?.latitude,
                                  longitude: loc?.longitude ?? e.item?.longitude, isUtility: screenshot)
        }
    }

    nonisolated private static func cards(_ entries: [GalleryEntry], facts: [String: LibraryStore.PhotoFacts],
                                          kinds: Set<Memories.KindFilter>, search: SearchService) -> [Card] {
        let photos = entries.compactMap { e -> Memories.Photo? in
            guard let date = e.date, !e.isVideo else { return nil }
            let loc = e.asset?.location?.coordinate
            let f = facts[e.id]
            let screenshot = e.asset?.mediaSubtypes.contains(.photoScreenshot) == true
            return Memories.Photo(id: e.id, date: date, latitude: loc?.latitude ?? e.item?.latitude, longitude: loc?.longitude ?? e.item?.longitude,
                                  things: f?.things ?? [], score: f?.score, isUtility: (f?.utility ?? false) || screenshot)
        }
        let month = DateFormatter()
        month.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        let dayMonth = DateFormatter()
        dayMonth.setLocalizedDateFormatFromTemplate("dMMMMyyyy")
        let calendar = Calendar.current
        func place(_ m: Memories.Memory) -> String? { m.placeCell.flatMap { search.placeName(cell: $0) } }
        func span(_ m: Memories.Memory) -> String {
            let a = month.string(from: m.start), b = month.string(from: m.end)
            return a == b ? a : "\(a) – \(b)"
        }
        // Titles like Apple's and Google's: what and when, and where when one place stands out.
        return Memories.all(photos, today: Date(), calendar: calendar, kinds: kinds).map { m in
            switch m.kind {
            case .onThisDay(let years):
                return Card(memory: m, title: years == 1 ? "One Year Ago" : "\(years) Years Ago",
                            subtitle: ([dayMonth.string(from: m.start)] + (place(m).map { [$0] } ?? [])).joined(separator: " · "))
            case .recent:
                return Card(memory: m, title: "Recent Highlights", subtitle: span(m))
            case .trip:
                let days = (calendar.dateComponents([.day], from: calendar.startOfDay(for: m.start), to: calendar.startOfDay(for: m.end)).day ?? 0) + 1
                // A long stay reads like Photos': "Time in Dubai", from the first month to the last.
                let long = days > Memories.longStayDays
                let title = place(m).map { long ? "Time in \($0)" : "Trip to \($0)" } ?? (long ? "Away, \(span(m))" : "Trip in \(month.string(from: m.start))")
                return Card(memory: m, title: title, subtitle: long ? "\(span(m)) · \(days) days" : "\(month.string(from: m.start)) · \(days) days")
            case .theme(let theme):
                return Card(memory: m, title: theme.title, subtitle: "\(m.allIds.count) photos · \(span(m))")
            }
        }
    }
}

/// The list of memories, each a large cover; tapping one plays it as a story.
struct MemoriesView<Destination: View>: View {
    @EnvironmentObject private var gallery: GalleryModel
    @ObservedObject var model: MemoriesModel
    let destination: (GalleryFilter) -> Destination
    @State private var playing: MemoriesModel.Card?
    @State private var showingAll: MemoriesModel.Card?

    var body: some View {
        ScrollView {
            #if os(macOS)
            // A window is far wider than a phone: one full-width card would fill the screen with a single cover.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 460), spacing: 16)], spacing: 16) { cards }
                .padding(16)
            #else
            LazyVStack(spacing: 16) { cards }
                .padding(16)
            #endif
        }
        .overlay {
            if model.loaded && model.cards.isEmpty {
                EmptyStateView(systemImage: "sparkles", title: "No Memories Yet",
                               message: "Photos from this day in earlier years and your trips show here.")
            } else if !model.loaded {
                ProgressView()
            }
        }
        .navigationTitle("Memories")
        .task(id: gallery.revision) { await model.refresh(entries: gallery.entries, revision: gallery.revision) }
        .navigationDestination(item: $showingAll) { card in destination(.matching(title: card.title, ids: Set(card.memory.allIds))) }
        #if os(iOS)
        .fullScreenCover(item: $playing) { card in story(card) }
        #else
        .sheet(item: $playing) { card in story(card).frame(minWidth: 760, minHeight: 560) }
        #endif
    }

    private var cards: some View {
        ForEach(model.cards) { card in
            Button { playing = card } label: { MemoryCard(card: card, cover: model.entries[card.memory.cover]) }
                .buttonStyle(.plain)
                .contextMenu { Button { showingAll = card } label: { Label("Show All Photos", systemImage: "square.grid.2x2") } }
                .accessibilityLabel("\(card.title), \(card.subtitle)")
                .accessibilityHint("Plays the memory")
        }
    }

    private func story(_ card: MemoriesModel.Card) -> some View {
        // Clear `playing` ourselves: Environment dismiss often fails for a fullScreenCover inside NavigationStack,
        // so the only way out was to finish every photo (end of story calls close).
        MemoryStoryView(
            cards: model.cards,
            start: model.cards.firstIndex(of: card) ?? 0,
            entriesFor: { c in c.memory.ids.compactMap { model.entries[$0] } },
            onClose: { playing = nil },
            showAll: { current in
                playing = nil
                showingAll = current
            }
        )
    }
}

/// A memory's cover with its title, filling whatever frame it's given (Collections' row).
struct MemoryCover: View {
    let card: MemoriesModel.Card
    let cover: GalleryEntry?
    @State private var image: PlatformImage?

    var body: some View {
        Color.tileBackground
            .overlay { if let image { Image(platformImage: image).resizable().scaledToFill() } }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.title).font(.subheadline.bold()).lineLimit(2)
                    Text(card.subtitle).font(.caption2).lineLimit(1)
                }
                .foregroundStyle(.white)
                .shadow(radius: 3)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .task(id: cover?.id) {
                guard let cover else { return }
                for await img in ThumbnailPipeline.shared.images(for: cover, pixels: 450) { image = img }
            }
    }
}

private struct MemoryCard: View {
    let card: MemoriesModel.Card
    let cover: GalleryEntry?
    @State private var image: PlatformImage?

    var body: some View {
        Color.tileBackground
            .aspectRatio(4 / 3, contentMode: .fit)
            .overlay { if let image { Image(platformImage: image).resizable().scaledToFill() } }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title).font(.title2.bold())
                    Text(card.subtitle).font(.subheadline)
                }
                .foregroundStyle(.white)
                .shadow(radius: 4)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .task(id: cover?.id) {
                guard let cover else { return }
                for await img in ThumbnailPipeline.shared.images(for: cover, pixels: 768) { image = img }
            }
    }
}

/// A memory played like a story: the bar sits at the top, each photo plays for a few seconds, tap the sides to move
/// inside this memory, swipe sideways for the next or previous memory, swipe down or tap Close to leave.
struct MemoryStoryView: View {
    let cards: [MemoriesModel.Card]
    let start: Int
    let entriesFor: (MemoriesModel.Card) -> [GalleryEntry]
    /// Clears the fullScreenCover / sheet binding. Prefer this over Environment dismiss (unreliable in NavigationStack).
    let onClose: () -> Void
    let showAll: (MemoriesModel.Card) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cardIndex = 0
    @State private var index = 0
    /// Photos already decoded, keyed by memory and frame, so the neighbour is on screen before the swipe lands.
    @State private var images: [String: PlatformImage] = [:]
    /// Photos that wouldn't load (no connection, say). The story says so and moves on instead of spinning forever.
    @State private var failed: Set<String> = []
    @State private var elapsed: Double = 0
    @State private var holding = false
    @State private var paused = false
    @State private var dragX: CGFloat = 0
    @State private var dragY: CGFloat = 0
    @State private var pageWidth: CGFloat = 1
    /// Bumped when a new drag or settle starts, so a finger can cancel a settle that has not landed yet.
    @State private var settleID = 0
    @State private var settling = false
    @State private var closing = false
    private static let seconds: Double = 4
    private static let tick: Double = 1.0 / 30
    /// The black gap between two memories while one slides over the other.
    private static let gap: CGFloat = 10

    init(cards: [MemoriesModel.Card], start: Int, entriesFor: @escaping (MemoriesModel.Card) -> [GalleryEntry], onClose: @escaping () -> Void, showAll: @escaping (MemoriesModel.Card) -> Void) {
        self.cards = cards
        self.start = start
        self.entriesFor = entriesFor
        self.onClose = onClose
        self.showAll = showAll
        let first = cards.isEmpty ? 0 : min(max(0, start), cards.count - 1)
        _cardIndex = State(initialValue: first)
    }

    private var card: MemoriesModel.Card { cards[min(max(0, cardIndex), cards.count - 1)] }
    private var entries: [GalleryEntry] { cards.isEmpty ? [] : entriesFor(card) }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            // The pages move. The gesture stays on this reader, which does not, so a downward drag
            // cannot slide the touch off the view and freeze the card halfway.
            ZStack(alignment: .topLeading) {
                HStack(spacing: Self.gap) {
                    storyPage(cardIndex - 1, width: width)
                    storyPage(cardIndex, width: width)
                    storyPage(cardIndex + 1, width: width)
                }
                .offset(x: -(width + Self.gap) + dragX, y: max(0, dragY))
                .scaleEffect(reduceMotion ? 1 : 1 - min(0.08, max(0, dragY) / 1800), anchor: .center)
                .allowsHitTesting(false)
            }
            .frame(width: width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(storyDrag(width: width))
            .simultaneousGesture(SpatialTapGesture().onEnded { value in
                guard !closing, abs(dragX) < 1, abs(dragY) < 1 else { return }
                move(value.location.x < width / 3 ? -1 : 1)
            })
            .onChange(of: width, initial: true) { _, new in pageWidth = new }
        }
        .overlay(alignment: .top) {
            if cards.indices.contains(cardIndex) {
                chrome(card, photos: entries, active: true)
                    .offset(x: dragX, y: max(0, dragY))
                    .opacity(dragY > 12 ? max(0, 1 - Double(dragY / 220)) : 1)
            }
        }
        // The black behind the card fades with the finger. It used to stop at a dark veil, and the
        // cover then slid that veil off on its own, so a second black sheet followed the photo.
        .background(Color.black.opacity(veil).ignoresSafeArea())
        .presentationBackground { Color.black.opacity(veil) }
        .task(id: "\(card.id)-\(index)-\(cardIndex)") { await preload() }
        .task { await play() }
        .onChange(of: index) { _, _ in
            elapsed = 0
            holding = false
        }
    }

    /// One memory in the pager. Only the memory under the finger has the controls; the others are what slides in.
    @ViewBuilder private func storyPage(_ slot: Int, width: CGFloat) -> some View {
        let active = slot == cardIndex
        ZStack {
            Color.black
            if cards.indices.contains(slot) {
                let item = cards[slot]
                let photos = entriesFor(item)
                let photo = active ? index : 0
                if photos.isEmpty {
                    Text("No photos in this memory").font(.subheadline).foregroundStyle(.white)
                } else if let image = images[cacheKey(item, photo)] {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(active && dragX == 0 && dragY == 0 && !reduceMotion ? 1 + 0.06 * elapsed / Self.seconds : 1)
                } else if failed.contains(cacheKey(item, photo)) {
                    Label("This photo couldn't load", systemImage: "exclamationmark.icloud")
                        .font(.subheadline).foregroundStyle(.white)
                } else {
                    ProgressView().tint(.white)
                }
            }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .top) {
            // The open card's controls live in the safe area above. Neighbours carry their own so a swipe shows a header.
            if !active, cards.indices.contains(slot) {
                chrome(cards[slot], photos: entriesFor(cards[slot]), active: false)
            }
        }
        .accessibilityHidden(!active)
    }

    /// The open memory, in the shape of a highlight: one thin segment per photo, the cover, the title and the date.
    private func chrome(_ item: MemoriesModel.Card, photos: [GalleryEntry], active: Bool) -> some View {
        let shown = active ? index : 0
        let cover = images[cacheKey(item, shown)]
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 3) {
                ForEach(0..<max(photos.count, 1), id: \.self) { i in
                    Capsule().fill(.white.opacity(0.35))
                        .overlay(alignment: .leading) {
                            Capsule().fill(.white)
                                .scaleEffect(x: segmentFill(i, count: photos.count, active: active), y: 1, anchor: .leading)
                        }
                        .frame(height: 2.5)
                }
            }
            .accessibilityHidden(true)
            HStack(alignment: .center, spacing: 8) {
                Group {
                    if let cover {
                        Image(platformImage: cover).resizable().scaledToFill()
                    } else {
                        Color.white.opacity(0.2)
                    }
                }
                .frame(width: 32, height: 32)
                .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(item.subtitle).font(.caption).lineLimit(1)
                    }
                    if active {
                        Button("Show All") { showAll(item) }
                            .font(.subheadline.weight(.semibold))
                    }
                }
                Spacer(minLength: 8)
                if active {
                    Button { paused.toggle() } label: {
                        Image(systemName: paused ? "play.fill" : "pause.fill")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(paused ? "Play" : "Pause")
                    Button { close(animated: true) } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .frame(width: 32, height: 32)
                            .background(.white.opacity(0.22), in: Circle())
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Close")
                    .keyboardShortcut(.cancelAction)
                }
            }
            .foregroundStyle(.white)
            .buttonStyle(.plain)
            .shadow(radius: 3)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(alignment: .top) {
            LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 160)
                .allowsHitTesting(false)
        }
    }

    private func segmentFill(_ i: Int, count: Int, active: Bool) -> CGFloat {
        guard active, count > 0 else { return 0 }
        if i < index { return 1 }
        if i > index { return 0 }
        return CGFloat(min(1, elapsed / Self.seconds))
    }

    /// The card follows the finger. Sideways reveals the next memory; down leaves. A short drag springs back.
    private func storyDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { v in
                guard !closing else { return }
                holding = true
                settling = false
                if abs(v.translation.width) + abs(v.translation.height) < 20 { settleID += 1 }
                let dx = v.translation.width
                let dy = v.translation.height
                if dy > 0, dy > abs(dx) {
                    dragX = 0
                    dragY = dy
                } else if abs(dx) > abs(dy) {
                    dragY = 0
                    let dest = cardIndex + (dx < 0 ? 1 : -1)
                    dragX = cards.indices.contains(dest) ? dx : dx * 0.28
                }
            }
            .onEnded { v in
                guard !closing else { return }
                holding = false
                let dx = v.translation.width
                let dy = v.translation.height
                let horizontal = abs(dx) > abs(dy)
                let flickAcross = abs(v.predictedEndTranslation.width) > width * 0.55
                    && abs(v.predictedEndTranslation.width) > abs(v.predictedEndTranslation.height)
                let flickDown = v.predictedEndTranslation.height > 280
                    && v.predictedEndTranslation.height > abs(v.predictedEndTranslation.width)
                if dy > 0, !horizontal, dy > 110 || flickDown {
                    close(animated: true)
                    return
                }
                if horizontal, abs(dx) > width * 0.22 || flickAcross {
                    beginShift(dx < 0 ? 1 : -1)
                    return
                }
                springBack()
            }
    }

    /// Slide the rest of the way onto the next memory, then park there without moving the picture.
    private func beginShift(_ delta: Int) {
        let next = cardIndex + delta
        guard cards.indices.contains(next), !closing else { springBack(); return }
        let target = CGFloat(-delta) * (max(pageWidth, 1) + Self.gap)
        if reduceMotion {
            cardIndex = next
            index = 0
            elapsed = 0
            dragX = 0
            dragY = 0
            return
        }
        settleID += 1
        let id = settleID
        settling = true
        Haptics.selection()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            dragX = target
            dragY = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) {
            guard id == settleID, !closing else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                cardIndex = next
                index = 0
                elapsed = 0
                dragX = 0
                dragY = 0
                settling = false
            }
        }
    }

    private func springBack() {
        settleID += 1
        if reduceMotion {
            dragX = 0
            dragY = 0
            return
        }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            dragX = 0
            dragY = 0
        }
    }

    /// How much of the black behind the card is still there. A short pull keeps it; a close takes it to nothing.
    private var veil: Double { 1 - min(1, Double(max(0, dragY) / 320)) }

    private func close(animated: Bool = false) {
        guard !closing else { return }
        settleID += 1
        closing = true
        // The card has already left. Clearing the cover with the system animation would slide a
        // second black sheet down after it.
        let finish = {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { onClose() }
        }
        if animated && !reduceMotion {
            withAnimation(.easeOut(duration: 0.28)) { dragY = max(900, pageWidth * 1.8) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { finish() }
        } else {
            finish()
        }
    }

    /// One clock for the whole story: it stops while paused, held, or waiting for a photo that hasn't loaded yet.
    private func play() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(Self.tick * 1_000_000_000))
            guard !paused, !holding, !settling, images[cacheKey(card, index)] != nil || failed.contains(cacheKey(card, index)) else { continue }
            elapsed += Self.tick
            if elapsed >= Self.seconds { move(1) }
        }
    }

    private func move(_ delta: Int) {
        let next = index + delta
        if next >= entries.count {
            if cardIndex < cards.count - 1 { beginShift(1) } else { close(animated: true) }
            return
        }
        if next < 0 {
            if cardIndex > 0 { beginShift(-1) } else { elapsed = 0; index = 0 }
            return
        }
        elapsed = 0
        index = next
    }

    private func cacheKey(_ item: MemoriesModel.Card, _ photo: Int) -> String { "\(item.id)#\(photo)" }

    /// This photo, the next two, and the first frame of each neighbour, so a swipe never waits on a blank page.
    private func preload() async {
        var jobs: [(MemoriesModel.Card, Int)] = []
        for i in [index, index + 1, index + 2] where entries.indices.contains(i) { jobs.append((card, i)) }
        if cards.indices.contains(cardIndex - 1) { jobs.append((cards[cardIndex - 1], 0)) }
        if cards.indices.contains(cardIndex + 1) { jobs.append((cards[cardIndex + 1], 0)) }
        for (item, i) in jobs {
            let photos = entriesFor(item)
            guard photos.indices.contains(i) else { continue }
            let key = cacheKey(item, i)
            if images[key] != nil || failed.contains(key) { continue }
            if let image = await Self.image(for: photos[i]) { images[key] = image } else { failed.insert(key) }
        }
    }

    /// Screen-sized from the photo on this device; a cloud photo uses its screen copy when it has one (no big download).
    private static func image(for entry: GalleryEntry) async -> PlatformImage? {
        let env = AppEnvironment.shared
        if let asset = entry.asset {
            return await env.photos.image(for: asset, targetSize: CGSize(width: 1600, height: 1600))
        }
        guard let item = entry.item else { return nil }
        if item.hasScreenCopy, let first = try? await env.media.shownFirst(for: item),
           let img = await Task.detached(priority: .userInitiated, operation: { CloudMediaService.downsampled(first.url, maxPixel: 1600) }).value {
            return img
        }
        return try? await env.media.thumbnail(for: item)
    }
}
