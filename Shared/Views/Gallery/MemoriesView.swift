import SwiftUI
import MemvoCore

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
                    let r = self.revision
                    self.revision = -1
                    await self.refresh(entries: self.lastEntries, revision: r)
                }
            })
        }
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    func refresh(entries: [GalleryEntry], revision: Int) async {
        guard revision != self.revision else { return }
        self.revision = revision
        lastEntries = entries
        generation += 1
        let mine = generation
        let search = AppEnvironment.shared.search!
        let store = AppEnvironment.shared.store
        let kinds = MemoriesSettingsView.enabled
        let started = Date()
        let (cards, byId) = await Task.detached(priority: .utility) {
            (Self.cards(entries, facts: (try? store.photoFacts()) ?? [:], kinds: kinds, search: search),
             Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
        }.value
        guard mine == generation else { return }
        self.entries = byId
        self.cards = cards
        loaded = true
        appLog(String(format: "Memories: %d (%@) from %d items in %.2f s", cards.count,
                      cards.map(\.title).joined(separator: ", "), entries.count, Date().timeIntervalSince(started)))
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
    /// Only these kinds (Collections → Trips → See All); nil for all.
    var kinds: Set<KindKey>? = nil
    let destination: (GalleryFilter) -> Destination

    enum KindKey { case trip, other }
    private var cards: [MemoriesModel.Card] {
        guard let kinds else { return model.cards }
        return model.cards.filter { kinds.contains($0.memory.kind == .trip ? .trip : .other) }
    }
    @State private var playing: MemoriesModel.Card?
    @State private var showingAll: MemoriesModel.Card?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(cards) { card in
                    Button { playing = card } label: { MemoryCard(card: card, cover: model.entries[card.memory.cover]) }
                        .buttonStyle(.plain)
                        .contextMenu { Button { showingAll = card } label: { Label("Show All Photos", systemImage: "square.grid.2x2") } }
                        .accessibilityLabel("\(card.title), \(card.subtitle)")
                        .accessibilityHint("Plays the memory")
                }
            }
            .padding(16)
        }
        .overlay {
            if model.loaded && model.cards.isEmpty {
                EmptyStateView(systemImage: "sparkles", title: "No Memories Yet",
                               message: "Photos from this day in earlier years and your trips show here.")
            } else if !model.loaded {
                ProgressView()
            }
        }
        .navigationTitle(kinds == [.trip] ? "Trips" : "Memories")
        .task(id: gallery.revision) { await model.refresh(entries: gallery.entries, revision: gallery.revision) }
        .navigationDestination(item: $showingAll) { card in destination(.matching(title: card.title, ids: Set(card.memory.allIds))) }
        #if os(iOS)
        .fullScreenCover(item: $playing) { card in story(card) }
        #else
        .sheet(item: $playing) { card in story(card).frame(minWidth: 760, minHeight: 560) }
        #endif
    }

    private func story(_ card: MemoriesModel.Card) -> some View {
        MemoryStoryView(card: card, entries: card.memory.ids.compactMap { model.entries[$0] }) {
            playing = nil
            showingAll = card
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

/// A memory played like Apple's and Google's: each photo for a few seconds with a slow zoom, cross-fading to the next,
/// which is already loaded. Tap the sides to move, hold to pause, swipe down to close.
struct MemoryStoryView: View {
    let card: MemoriesModel.Card
    let entries: [GalleryEntry]
    let showAll: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var images: [Int: PlatformImage] = [:]
    @State private var elapsed: Double = 0
    @State private var holding = false
    @State private var paused = false
    @State private var dragY: CGFloat = 0
    private static let seconds: Double = 4
    private static let tick: Double = 1.0 / 30

    var body: some View {
        ZStack {
            Color.black.opacity(1 - min(0.6, Double(dragY / 600))).ignoresSafeArea()
            ZStack {
                if let image = images[index] {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(1 + 0.06 * elapsed / Self.seconds)
                        .id(index)
                        .transition(.opacity)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .animation(.easeInOut(duration: 0.5), value: index)
            .offset(y: dragY)
            .scaleEffect(1 - min(0.25, dragY / 1600))
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle()).onTapGesture { move(-1) }
                    .accessibilityLabel("Previous photo").accessibilityAddTraits(.isButton)
                Color.clear.contentShape(Rectangle()).onTapGesture { move(1) }
                    .accessibilityLabel("Next photo").accessibilityAddTraits(.isButton)
            }
            .simultaneousGesture(holdToPause)
            .gesture(swipeDownToClose)
            chrome.opacity(dragY > 0 ? 0 : 1)
        }
        .task(id: index) { await preload() }
        .task { await play() }
        .onChange(of: index) { _, _ in
            elapsed = 0
            // A touch the system cancelled never ends its gesture: moving on clears it.
            holding = false
        }
    }

    private var chrome: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 3) {
                ForEach(entries.indices, id: \.self) { i in
                    GeometryReader { geo in
                        Capsule().fill(.white.opacity(0.35))
                            .overlay(alignment: .leading) {
                                Capsule().fill(.white)
                                    .frame(width: geo.size.width * (i < index ? 1 : (i == index ? min(1, elapsed / Self.seconds) : 0)))
                            }
                    }
                    .frame(height: 3)
                }
            }
            .accessibilityHidden(true)
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title).font(.headline)
                    Text(card.subtitle).font(.caption)
                }
                Spacer()
                Button { paused.toggle() } label: { Image(systemName: paused ? "play.fill" : "pause.fill") }
                    .accessibilityLabel(paused ? "Play" : "Pause")
                Button("Show All", action: showAll)
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Close")
                    .keyboardShortcut(.cancelAction)
            }
            .foregroundStyle(.white)
            .buttonStyle(.plain)
            .font(.body.weight(.semibold))
            .shadow(radius: 3)
            Spacer()
        }
        .padding(16)
    }

    /// Paused while a finger is down. A drag gesture always ends when the finger lifts, so a quick tap pauses only for
    /// the tap (a long press that failed after a tap never ended, and the story stayed frozen).
    private var holdToPause: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in if !holding { holding = true } }
            .onEnded { _ in holding = false }
    }

    private var swipeDownToClose: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { v in if v.translation.height > 0 { dragY = v.translation.height; holding = true } }
            .onEnded { v in
                holding = false
                if v.translation.height > 140 || v.predictedEndTranslation.height > 400 {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { dragY = 0 }
                }
            }
    }

    /// One clock for the whole story: it stops while paused, held, or waiting for a photo that hasn't loaded yet.
    private func play() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(Self.tick * 1_000_000_000))
            guard !paused, !holding, images[index] != nil else { continue }
            elapsed += Self.tick
            if elapsed >= Self.seconds { move(1) }
        }
    }

    private func move(_ delta: Int) {
        let next = index + delta
        if next >= entries.count { dismiss(); return }
        elapsed = 0
        index = max(0, next)
    }

    /// This photo and the next two, so moving on never waits; photos far behind are let go.
    private func preload() async {
        for i in [index, index + 1, index + 2] where entries.indices.contains(i) && images[i] == nil {
            if let image = await Self.image(for: entries[i]) { images[i] = image }
        }
        images = images.filter { abs($0.key - index) <= 3 }
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
