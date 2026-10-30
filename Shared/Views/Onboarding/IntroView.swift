import SwiftUI
import Photos
import ImageIO
import MemvoCore

/// The first-run story before Telegram sign-in: what Memvo is, the problem it solves, what you get, who can see your
/// photos, honest answers, and your own library in numbers. Nothing here talks to Telegram or reads the library.
struct IntroView: View {
    enum Page: Int, CaseIterable { case hook, pain, features, privacy, questions, numbers }

    @Binding var page: Int
    @Binding var encrypted: Bool
    @Binding var photoStatus: PHAuthorizationStatus
    let finish: () -> Void

    @StateObject private var photos = IntroPhotos()
    @StateObject private var stats = LibraryStats()
    @StateObject private var recent = RecentPhotos()
    @State private var forward = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var current: Page { Page(rawValue: page) ?? .hook }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if current != .hook {
                    Button { go(-1) } label: {
                        Image(systemName: "chevron.left").font(.body.weight(.semibold))
                            .frame(width: 40, height: 40).background(Color.white.opacity(0.1), in: Circle())
                    }
                    .foregroundStyle(.primary)
                    .accessibilityLabel("Back")
                }
                Spacer()
            }
            .frame(height: 44)
            .padding(.horizontal, 20)

            ZStack {
                pageView(current)
                    .id(current)
                    .transition(.asymmetric(
                        insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            footer
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .background {
            ZStack {
                if current == .hook {
                    PhotoWall(images: photos.images).transition(.opacity)
                } else {
                    RadialGradient(colors: [Color.accentColor.opacity(0.24), .clear], center: .top, startRadius: 0, endRadius: 460)
                        .transition(.opacity)
                }
            }
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.6), value: current == .hook)
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 30).onEnded { value in
            guard abs(value.translation.width) > abs(value.translation.height) else { return }
            if value.translation.width < -60, current != .numbers { go(1) }
            if value.translation.width > 60 { go(-1) }
        })
        .task { photos.load() }
        .task(id: photoStatus) {
            if photoStatus == .authorized || photoStatus == .limited { stats.load(); recent.load(limit: 5, checkLibrary: false) }
        }
    }

    // MARK: - Navigation

    private func go(_ delta: Int) {
        let next = page + delta
        guard Page(rawValue: next) != nil else { return }
        Haptics.tap()
        forward = delta > 0
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.1)) { page = next }
    }

    private var buttonTitle: String {
        switch current {
        case .hook: return "Get started"
        case .questions: return "Continue to Memvo"
        case .numbers:
            if photoStatus == .notDetermined { return "Allow access to Photos" }
            return "Continue with Telegram"
        default: return "Continue"
        }
    }

    private func primary() {
        guard current == .numbers else { go(1); return }
        if photoStatus == .notDetermined {
            Task { photoStatus = await PhotoLibraryService.requestAuthorization() }
        } else {
            finish()
        }
    }

    private var footer: some View {
        VStack(spacing: 14) {
            HStack(spacing: 7) {
                ForEach(Page.allCases, id: \.self) { p in
                    Capsule().fill(p == current ? Color.accentColor : Color.white.opacity(0.2))
                        .frame(width: p == current ? 20 : 7, height: 7)
                }
            }
            .animation(.spring(duration: 0.3), value: current)
            .accessibilityElement()
            .accessibilityLabel("Page \(page + 1) of \(Page.allCases.count)")

            PrimaryCapsuleButton(title: buttonTitle, action: primary)

            if current == .numbers, photoStatus == .notDetermined {
                // Photos access can wait: sign-in and the cloud library work without it.
                Button("Not now", action: finish).font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
            }

            if current == .hook {
                // Telegram API terms 2.2: say the app uses the Telegram API (and isn't Telegram's own).
                Text("Uses the Telegram API. Not affiliated with Telegram.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    // MARK: - Pages

    @ViewBuilder private func pageView(_ p: Page) -> some View {
        switch p {
        case .hook:
            HookPage()
        case .pain:
            IntroPage(title: "Storage full again? Keep every photo without a monthly bill.",
                      subtitle: "Your library lives in the Telegram account you already have.") {
                PainArt()
            }
        case .features:
            FeaturesPage()
        case .privacy:
            PrivacyPage(encrypted: $encrypted)
        case .questions:
            QuestionsPage()
        case .numbers:
            NumbersPage(status: photoStatus, stats: stats, recent: recent)
        }
    }
}

/// Art on top, then a big title and a short line. Scrolls on small screens and with large text.
private struct IntroPage<Art: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let art: Art

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                art.frame(maxWidth: .infinity)
                    .padding(.bottom, 10)
                Text(title).font(.system(size: 30, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                Text(subtitle).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

// MARK: - 1. Hook

/// Big, confident type over the photo wall: what Memvo is in two lines.
private struct HookPage: View {
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer(minLength: 0)
            Label("Private · Open source · No servers", systemImage: "lock.fill")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.15)))
            (Text("Your photos.\n")
             + Text("Your Telegram.").foregroundStyle(LinearGradient(colors: [Color.accentColor, Color(red: 0.83, green: 0.66, blue: 1)],
                                                                    startPoint: .leading, endPoint: .trailing)))
                .font(.system(size: 46, weight: .bold))
                .tracking(-0.8)
                .lineSpacing(-4)
                .fixedSize(horizontal: false, vertical: true)
            Text("Every original, backed up to a private channel in your own Telegram account. No one else's servers.")
                .font(.title3).foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 28)
        .onAppear { withAnimation(reduceMotion ? nil : .spring(duration: 0.9, bounce: 0.15).delay(0.25)) { shown = true } }
    }
}

/// Full-bleed, slowly drifting columns of photos, like a library scrolling by. Green cloud badges pop onto photos as
/// they pass: everything getting backed up. Fades into black where the text sits.
private struct PhotoWall: View {
    let images: [CGImage]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let ratios: [CGFloat] = [1.3, 1.0, 1.45, 1.1, 1.25, 0.95, 1.4, 1.15]
    private static let speeds: [Double] = [16, 24, 13, 20]
    private let spacing: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let wall = geo.size.width * 1.4
            let width = (wall - spacing * 3) / 4
            TimelineView(.animation(paused: reduceMotion)) { ctx in
                let t = reduceMotion ? 0 : ctx.date.timeIntervalSinceReferenceDate
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(0..<4, id: \.self) { col in column(col, width: width, time: t) }
                }
                .frame(width: wall, alignment: .leading)
                .rotationEffect(.degrees(-9))
                .offset(x: -(wall - geo.size.width) / 2, y: -geo.size.height * 0.12)
            }
        }
        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.3),
                                     .init(color: .black.opacity(0.3), location: 0.48), .init(color: .clear, location: 0.6)],
                             startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .top) {
            // Keeps the status bar readable over bright photos.
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom).frame(height: 120)
        }
        .accessibilityHidden(true)
    }

    private func column(_ col: Int, width: CGFloat, time: Double) -> some View {
        let heights = (0..<8).map { width * Self.ratios[($0 + col * 3) % 8] }
        let loop = heights.reduce(0) { $0 + $1 + spacing }
        let moved = CGFloat((time * Self.speeds[col]).truncatingRemainder(dividingBy: Double(loop)))
        // Neighbouring columns drift in opposite directions, which reads as depth.
        let y = col.isMultiple(of: 2) ? -moved : moved - loop
        return VStack(spacing: spacing) {
            ForEach(0..<16, id: \.self) { i in
                let n = i % 8 + col * 8
                IntroTile(image: images.isEmpty ? nil : images[n % images.count], index: n)
                    .frame(width: width, height: heights[i % 8])
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(alignment: .topTrailing) { badge(n, time: time).padding(8) }
            }
        }
        .offset(y: y)
    }

    /// Each photo gets its badge at its own moment, pops in, stays a while, then the cycle repeats.
    private func badge(_ n: Int, time: Double) -> some View {
        let phase = ((time + Double(n) * 0.73) / 7).truncatingRemainder(dividingBy: 1)
        let k = min(1, max(0, (phase - 0.35) * 8))
        let pop = k < 1 ? k * (1 + 0.35 * sin(k * .pi)) : 1
        return Circle().fill(Color.green).frame(width: 22, height: 22)
            .overlay { Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(.white) }
            .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
            .scaleEffect(reduceMotion ? 1 : pop)
            .opacity(reduceMotion || phase > 0.35 ? 1 : 0)
    }
}

/// A sample photo, or a soft gradient where none is bundled (the Mac app).
private struct IntroTile: View {
    let image: CGImage?
    let index: Int
    private static let palettes: [[Color]] = [[.orange, .pink], [.teal, .blue], [.green, .teal], [.purple, .indigo],
                                              [.yellow, .orange], [.pink, .red], [.cyan, .blue], [.mint, .green], [.blue, .purple]]

    var body: some View {
        if let image {
            Image(decorative: image, scale: 1).resizable().scaledToFill()
        } else {
            LinearGradient(colors: Self.palettes[index % Self.palettes.count], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

// MARK: - 2. Pain

private struct PainArt: View {
    @State private var full = false
    @State private var mine = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 12) {
            meter(title: "iCloud", value: "5.0 of 5.0 GB", fill: full ? 1 : 0, color: .red) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Storage full. Backups have stopped.").font(.footnote.weight(.semibold)).foregroundStyle(.red)
                    Text("Upgrade for a monthly fee, or start deleting.").font(.footnote).foregroundStyle(.secondary)
                }
                .opacity(full ? 1 : 0)
            }
            meter(title: "Your Telegram library", value: "No storage plan", fill: mine ? 0.18 : 0, color: .accentColor) {
                Text("Every original, full quality, nothing compressed.").font(.footnote).foregroundStyle(.secondary)
            }
            .opacity(mine ? 1 : 0)
            .offset(y: mine ? 0 : 12)
        }
        .padding(.top, 20)
        .onAppear {
            if reduceMotion { full = true; mine = true; return }
            withAnimation(.easeInOut(duration: 0.7).delay(0.15)) { full = true }
            withAnimation(.spring(duration: 0.6).delay(0.85)) { mine = true }
        }
        .accessibilityElement(children: .combine)
    }

    private func meter<Below: View>(title: String, value: String, fill: CGFloat, color: Color, @ViewBuilder below: () -> Below) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(value).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(color).frame(width: geo.size.width * fill)
                }
            }
            .frame(height: 10)
            below()
        }
        .padding(16)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - 3. What you get

/// Every feature in plain words, most loved first, lit up one at a time with a real screenshot of it above.
/// Tapping a feature shows it straight away. Screenshots: Scripts/onboarding-shots.sh.
private struct FeaturesPage: View {
    @State private var active = 0
    @State private var pausedUntil = Date.distantPast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let features: [(icon: String, title: String, detail: String, shot: String)] = [
        ("icloud.and.arrow.up", "Every original, backed up", "Photos and videos at full quality", "feature-backup"),
        ("internaldrive", "Free up space", "Remove what's safely in Telegram", "feature-freeup"),
        ("play.fill", "Videos play at once", "Streamed, no full download", "feature-video"),
        ("magnifyingglass", "Search your photos", "Places, dates, text and things", "feature-search"),
        ("sparkles.rectangle.stack", "Memories and collections", "Your best days, picked for you", "feature-memories"),
        ("map", "Your photos on a map", "Every trip, every place", "feature-map"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            screenshot
            Text("Everything in one app").font(.system(size: 28, weight: .bold))
            VStack(spacing: 2) {
                ForEach(Self.features.indices, id: \.self) { i in row(i) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.6))
                if Date() >= pausedUntil { withAnimation(.easeInOut(duration: 0.45)) { active = (active + 1) % Self.features.count } }
            }
        }
    }

    /// The real screen for the lit feature, in an iPhone rising from the bottom of the card, like App Store art.
    private var screenshot: some View {
        let f = Self.features[active]
        return GeometryReader { geo in
            let phone = min(geo.size.width * 0.66, 250)
            // The screenshots are iPhone 17 Pro screens (402 × 874 points).
            let screen = phone - 12
            ZStack {
                RoundedRectangle(cornerRadius: phone * 0.16, style: .continuous).fill(Color(white: 0.1))
                    .overlay(RoundedRectangle(cornerRadius: phone * 0.16, style: .continuous).stroke(Color.white.opacity(0.22), lineWidth: 1.5))
                Image(f.shot).resizable()
                    .frame(width: screen, height: screen * 874 / 402)
                    .clipShape(RoundedRectangle(cornerRadius: screen * 0.14, style: .continuous))
                    .id(f.shot)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 14)), removal: .opacity))
            }
            .frame(width: phone, height: screen * 874 / 402 + 12)
            .shadow(color: .black.opacity(0.6), radius: 20, y: 10)
            .position(x: geo.size.width / 2, y: 22 + (screen * 874 / 402 + 12) / 2)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 250)
        .background(RadialGradient(colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.05)],
                                   center: .top, startRadius: 0, endRadius: 320))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.white.opacity(0.12)))
        .accessibilityHidden(true)
    }

    private func row(_ i: Int) -> some View {
        let f = Self.features[i]
        let on = i == active
        return Button {
            Haptics.tap()
            pausedUntil = Date().addingTimeInterval(6)
            withAnimation(.easeInOut(duration: 0.35)) { active = i }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: f.icon).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(on ? .white : Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(on ? Color.accentColor : Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(f.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    Text(f.detail).font(.footnote).foregroundStyle(.white.opacity(0.65))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.white.opacity(on ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

// MARK: - 4. Privacy

private struct PrivacyPage: View {
    @Binding var encrypted: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                flow
                Text("Choose who can see your photos").font(.system(size: 30, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 10) {
                    choice(title: "Standard", icon: "photo", selected: !encrypted,
                           detail: "Fastest, and photos also open in the Telegram app. Telegram could see them, like any cloud chat.") { encrypted = false }
                    choice(title: "End-to-end encrypted", icon: "lock.fill", selected: encrypted,
                           detail: "Locked on your \(Device.name) before upload. Only you can open them, with your passphrase.") { encrypted = true }
                }
                if encrypted {
                    Label("If you lose your passphrase and your recovery key, nobody can help you get your photos back. Not us, not Telegram.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.medium)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
                Text("You'll see exactly what Telegram stores when you create your library, and you can change your mind there.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .animation(.spring(duration: 0.35), value: encrypted)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// Your device, an empty crossed-out box where a company's server would be, then your Telegram.
    private var flow: some View {
        TimelineView(.animation(paused: reduceMotion)) { ctx in
            let p = reduceMotion ? 0.5 : (ctx.date.timeIntervalSinceReferenceDate / 2.6).truncatingRemainder(dividingBy: 1)
            GeometryReader { geo in
                let w = geo.size.width
                HStack(alignment: .top) {
                    node(Image(systemName: Device.symbol), "Your \(Device.name)")
                    Spacer()
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .strokeBorder(Color.red, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                            .frame(width: 54, height: 54)
                            .overlay { Rectangle().fill(Color.red).frame(width: 66, height: 2).rotationEffect(.degrees(-35)) }
                        Text("Our servers: none").font(.caption.weight(.semibold)).foregroundStyle(.red)
                    }
                    Spacer()
                    node(Image(systemName: "paperplane.fill"), "Your Telegram")
                }
                .padding(.top, 34)
                // Your photo arcs over the empty box, straight to your Telegram. The room above keeps the arc inside.
                let x = w * 0.13 + (w * 0.74) * p
                let y = 61 - 52 * sin(p * .pi)
                RoundedRectangle(cornerRadius: 3).fill(Color.accentColor).frame(width: 11, height: 11).position(x: x, y: y)
            }
            .frame(height: 118)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Photos go from your \(Device.name) straight to your Telegram. Memvo has no servers.")
    }

    private func node(_ image: Image, _ label: String) -> some View {
        VStack(spacing: 6) {
            image.font(.system(size: 24)).foregroundStyle(Color.accentColor)
                .frame(width: 54, height: 54)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 92)
    }

    private func choice(title: String, icon: String, selected: Bool, detail: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon).font(.system(size: 14, weight: .bold)).foregroundStyle(selected ? .white : .secondary)
                    .frame(width: 30, height: 30)
                    .background(selected ? Color.accentColor : Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).foregroundStyle(.white)
                    Text(detail).font(.footnote).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
            }
            .padding(14)
            .background(selected ? Color.accentColor.opacity(0.16) : Color.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(selected ? Color.accentColor : Color.white.opacity(0.12), lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// What the library channel in Telegram shows for one photo: the photo itself (Standard) or an unreadable `.cge`
/// file (encrypted), like the real channel. Shared with the Create Library step.
struct TelegramPreview: View {
    let encrypted: Bool
    @StateObject private var photos = IntroPhotos()

    // Real-looking CGFE caption text, as the channel shows it. Not a real key or file.
    private static let cipher = "CG1E:mvOrfa5vpbolKpiUJQy4f5UvnWUk7KLmQnt2Fdpe+zHb5H4B85PgZEbUzr/wkrJHgjrFrltUd62No9R4NfniT+4ZXYwhHBSsg+oLXC+n57UghHwPElFF3hO1hWhmFehMrWh8oqE1oGRP"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("In your Telegram, it looks like this").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
            ZStack(alignment: .topLeading) {
                if encrypted {
                    fileBubble.transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.95, anchor: .topLeading)),
                                                      removal: .opacity))
                } else {
                    photoBubble.transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.95, anchor: .topLeading)),
                                                       removal: .opacity))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.spring(duration: 0.4), value: encrypted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.06, green: 0.09, blue: 0.13), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task { photos.load() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(encrypted ? "In Telegram, an encrypted photo is an unreadable file." : "In Telegram, a Standard photo shows as the photo.")
    }

    private static let bubble = Color(red: 0.16, green: 0.21, blue: 0.27)

    private var photoBubble: some View {
        VStack(alignment: .leading, spacing: 0) {
            IntroTile(image: photos.images.first, index: 0)
                .frame(width: 200, height: 128).clipped()
            HStack {
                Text("IMG_4019.HEIC").font(.caption.weight(.semibold))
                Spacer()
                Text("2.8 MB").font(.caption).foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
        }
        .frame(width: 200)
        .background(Self.bubble)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var fileBubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "lock.doc.fill").font(.system(size: 18)).foregroundStyle(.white)
                    .frame(width: 40, height: 40).background(Color.accentColor.opacity(0.6), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("094f94fb-2064-49c6.o.cge").font(.caption.weight(.semibold)).lineLimit(1)
                    Text("2.8 MB · nobody can open it but you").font(.caption2).foregroundStyle(.white.opacity(0.6))
                }
            }
            Text(Self.cipher).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.55))
                .lineLimit(3)
        }
        .padding(10)
        .frame(maxWidth: 290, alignment: .leading)
        .background(Self.bubble, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - 5. Questions

/// Straight answers before anyone trusts us with their photos, including what Memvo can't promise. The four that
/// matter most show first; the rest are one tap away. Keep these in line with docs/FAQ.md.
private struct QuestionsPage: View {
    @State private var open: Int?
    @State private var showAll = false

    private static let shownFirst = 4
    private static let items: [(icon: String, question: String, answer: String)] = [
        ("eye", "Can Memvo see my photos?",
         "**No. Memvo has no servers.** The app talks only to Telegram, as you, like the official Telegram apps. **We have no way to see your library or your account.**"),
        ("paperplane", "Can Telegram see my photos?",
         "In a Standard library, **Telegram could see them**: files are stored like any Telegram cloud chat, which isn't end-to-end encrypted. In an encrypted library, **Memvo locks every file on your device first**, so Telegram stores only unreadable files."),
        ("trash", "Will Memvo delete photos from my \(Device.name)?",
         "**Only when you choose Free Up Space**, and only items Memvo has just checked are complete in Telegram. **You confirm every deletion**, and they stay in Recently Deleted for 30 days."),
        ("exclamationmark.triangle", "What if I lose my Telegram account?",
         "**Your library goes with it.** Telegram deletes accounts unused for 18 months by default; **Memvo can raise this to 2 years**. For a second copy, **Download a copy of your library** saves every original to a drive or folder."),
        ("externaldrive", "Is the storage really free?",
         "Telegram describes its cloud storage as **unlimited**, with files up to 2 GB each, or 4 GB with Premium. Memvo splits bigger videos automatically. **This is Telegram's offer, not ours, and Telegram can change it.**"),
        ("key", "What if I forget my passphrase?",
         "Your **recovery key** opens the library and lets you set a new passphrase. **If you lose both, nobody can open your photos, including us.** Keep them in a password manager."),
        ("checkmark.shield", "Is this allowed by Telegram?",
         "**Yes.** Memvo uses Telegram's public API under its terms, with its own app ID. It's an independent project, **not made or reviewed by Telegram**."),
        ("chevron.left.forwardslash.chevron.right", "What if Memvo stops being developed?",
         "**Your photos stay in your Telegram** as normal files, in a documented format. The code is open source, so anyone can keep it going, and **you can download everything at any time**."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "checkmark.shield.fill").font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white, Color.accentColor)
                    .frame(width: 60, height: 60)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .accentColor.opacity(0.5), radius: 16)
                Text("Before you trust us with your photos").font(.system(size: 30, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    badge("chevron.left.forwardslash.chevron.right", "Open source")
                    badge("server.rack", "No servers")
                    badge("eye.slash", "No tracking")
                }
                Text("Straight answers, including the parts that aren't in our favour.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 0) {
                    ForEach(Array(Self.items.indices.prefix(showAll ? Self.items.count : Self.shownFirst)), id: \.self) { i in
                        if i > 0 { Divider().overlay(Color.white.opacity(0.1)).padding(.leading, 50) }
                        row(i).transition(.opacity)
                    }
                }
                .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.top, 6)
                HStack {
                    if !showAll {
                        Button {
                            Haptics.tap()
                            withAnimation(.spring(duration: 0.4)) { showAll = true }
                        } label: {
                            Label("\(Self.items.count - Self.shownFirst) more questions", systemImage: "chevron.down")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    Spacer()
                    Link("Full FAQ", destination: AppLinks.faq).font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// The key points (in **bold**) in bright white, the rest dimmer, so a skim catches what matters.
    private static func answer(_ markdown: String) -> AttributedString {
        var text = (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
        text.foregroundColor = .white.opacity(0.6)
        for run in text.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            text[run.range].foregroundColor = .white
        }
        return text
    }

    private func badge(_ icon: String, _ text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.accentColor)
            Text(text).font(.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.1)))
        .accessibilityElement(children: .combine)
    }

    private func row(_ i: Int) -> some View {
        let item = Self.items[i]
        let isOpen = open == i
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                Haptics.tap()
                withAnimation(.spring(duration: 0.35, bounce: 0.05)) { open = isOpen ? nil : i }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: item.icon).font(.system(size: 17, weight: .medium)).foregroundStyle(Color.accentColor)
                        .frame(width: 26)
                    Text(item.question).font(.body.weight(.medium)).foregroundStyle(.white).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isOpen ? "Hides the answer" : "Shows the answer")
            if isOpen {
                // Bright enough to read on black: answers are the point of this screen.
                Text(Self.answer(item.answer))
                    .font(.subheadline)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 52).padding(.trailing, 16).padding(.bottom, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
    }
}

// MARK: - 6. Your numbers

private struct NumbersPage: View {
    let status: PHAuthorizationStatus
    @ObservedObject var stats: LibraryStats
    @ObservedObject var recent: RecentPhotos

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch status {
                case .notDetermined: ask
                case .authorized, .limited: numbers
                default: denied
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// Why access is needed, where the photos go, what still works without it.
    private var ask: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 34, weight: .semibold)).foregroundStyle(.tint)
                .frame(width: 64, height: 64)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.top, 30)
            Text("See your library in numbers").font(.system(size: 30, weight: .bold)).fixedSize(horizontal: false, vertical: true)
            Text("Memvo needs access to Photos to back them up. Your photos go only to your own Telegram, and they're counted here on this \(Device.name).")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Label("Choose Full Access so every photo is backed up. You can change it in Settings at any time.", systemImage: "info.circle")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var numbers: some View {
        VStack(alignment: .leading, spacing: 16) {
            // The user's own newest photos, fanned out: the moment this stops being a demo.
            PhotoFan(images: recent.photos.compactMap(\.image))
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            VStack(spacing: 4) {
                Text(stats.items, format: .number)
                    .font(.system(size: 60, weight: .heavy, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Color.accentColor)
                    .contentTransition(.numericText(value: Double(stats.items)))
                Text(status == .limited ? "photos and videos you've shared with Memvo" : "photos and videos on this \(Device.name)")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 10) {
                tile(value: stats.bytes.map(Self.size) ?? "…", label: "to back up", tint: .primary)
                tile(value: stats.free.map(Self.size) ?? "…", label: "free on this \(Device.name)",
                     tint: (stats.free ?? .max) < 10_000_000_000 ? .red : .primary)
            }

            Text(stats.bytes.map { "Keep all \(Self.size($0)) safe in your Telegram." } ?? "Measuring your library…")
                .font(.system(size: 26, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
            Text("Counted on this \(Device.name). Nothing has been uploaded yet.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            nextStep
        }
        .animation(.smooth(duration: 1.2), value: stats.items)
        .animation(.default, value: stats.bytes)
    }

    private var denied: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "photo.badge.exclamationmark").font(.system(size: 34, weight: .semibold)).foregroundStyle(.orange)
                .frame(width: 64, height: 64)
                .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.top, 30)
            Text("No access to Photos").font(.system(size: 30, weight: .bold))
            Text("You can still sign in and browse your Telegram library. To back up this \(Device.name), allow access in Settings.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Open Settings") { PlatformActions.openPhotoSettings() }.font(.subheadline.weight(.semibold))
            nextStep
        }
    }

    /// What happens after this screen. People expect an SMS; Telegram usually sends the code to its own app instead.
    private var nextStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Next: sign in with Telegram", systemImage: "paperplane.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
            Text("Your photos are stored in your own Telegram account. Telegram sends the login code to your Telegram app, usually not by SMS.")
                .font(.subheadline).foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.top, 6)
    }

    private func tile(value: String, label: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.weight(.bold)).monospacedDigit().foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Up to five photos dealt onto the table one after another, like prints.
private struct PhotoFan: View {
    let images: [PlatformImage]
    @State private var dealt = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let angles: [Double] = [-14, -7, 0, 7, 14]
    private static let offsets: [CGFloat] = [-96, -48, 0, 48, 96]

    var body: some View {
        let shown = Array(images.prefix(5))
        ZStack {
            ForEach(Array(shown.enumerated()), id: \.offset) { i, image in
                let slot = shown.count == 5 ? i : i + (5 - shown.count) / 2
                Image(platformImage: image).resizable().scaledToFill()
                    .frame(width: 84, height: 108)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white, lineWidth: 3))
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 6)
                    .rotationEffect(.degrees(i < dealt ? Self.angles[slot] : 0))
                    .offset(x: i < dealt ? Self.offsets[slot] : 0, y: i < dealt ? abs(Self.offsets[slot]) * 0.12 : 40)
                    .opacity(i < dealt ? 1 : 0)
                    .zIndex(Double(slot == 2 ? 10 : 5 - abs(slot - 2)))
                    .animation(reduceMotion ? nil : .spring(duration: 0.55, bounce: 0.3).delay(Double(i) * 0.12), value: dealt)
            }
        }
        .frame(height: 140)
        .accessibilityHidden(true)
        .onChange(of: images.count, initial: true) { _, count in dealt = min(count, 5) }
    }
}

// MARK: - 7. First win

/// The last onboarding step once Photos access is granted.
/// New library: the user picks the photo that matters to them and watches it land in Telegram, for real.
/// Restored library: welcome back, with how much came back and which photos here are already safe.
/// Uploads go through the normal backup (one queued item), so pacing and FLOOD_WAIT handling are the engine's own.
struct FirstBackupView: View {
    /// Items found in the library that was just restored; nil or 0 for a new or empty library.
    var restored: Int?
    let done: () -> Void

    enum Phase: Equatable { case choosing, uploading, safe, alreadySafe, nothing, stuck(String) }

    @ObservedObject private var activity = BackupActivity.shared
    @StateObject private var recent = RecentPhotos()
    @State private var phase: Phase = .choosing
    @State private var selected: String?
    @State private var progress: Double = 0
    @State private var shownCount = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var returning: Bool { (restored ?? 0) > 0 }
    private var finished: Bool { phase == .safe || phase == .alreadySafe }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if returning { welcomeBack }
                    else if phase == .choosing { chooser }
                    else { upload }
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            buttons
        }
        .task { recent.load(limit: returning ? 9 : 12) }
        .onChange(of: recent.loaded) { _, loaded in if loaded, recent.photos.isEmpty, !returning { phase = .nothing } }
        .onChange(of: activity.lanes) { _, lanes in
            guard phase == .uploading, let lane = lanes.values.first, lane.total > 0 else { return }
            withAnimation(.easeOut(duration: 0.4)) { progress = min(0.97, Double(lane.sent) / Double(lane.total)) }
        }
    }

    // MARK: Restored library

    private var welcomeBack: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "checkmark.icloud.fill").font(.system(size: 34, weight: .semibold)).foregroundStyle(.green)
                .frame(width: 64, height: 64)
                .background(Color.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .symbolEffect(.bounce, value: shownCount > 0)
            Text("Welcome back").font(.system(size: 34, weight: .bold))
            VStack(alignment: .leading, spacing: 2) {
                Text(shownCount, format: .number)
                    .font(.system(size: 52, weight: .heavy, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Color.accentColor)
                    .contentTransition(.numericText(value: Double(shownCount)))
                Text("photos and videos are in your Telegram library").foregroundStyle(.secondary)
            }
            photoGrid(selectable: false)
            Label("A green cloud means that photo on this \(Device.name) is already in your library. Back up now sends the rest.",
                  systemImage: "info.circle")
                .font(.footnote).foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await countUp(to: restored ?? 0) }
    }

    /// 0 → total in about a second and a half, easing out, then a success tap. Driven step by step rather than by one
    /// implicit animation, which the screen's own entrance transition swallowed.
    private func countUp(to total: Int) async {
        guard total > 0 else { return }
        if reduceMotion { shownCount = total; return }
        try? await Task.sleep(for: .milliseconds(350))
        let steps = 36
        for i in 1...steps {
            let k = Double(i) / Double(steps), eased = 1 - pow(1 - k, 3)
            withAnimation(.snappy(duration: 0.08)) { shownCount = Int((Double(total) * eased).rounded()) }
            try? await Task.sleep(for: .milliseconds(40))
            if Task.isCancelled { return }
        }
        Haptics.success()
    }

    // MARK: New library

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose your first photo").font(.system(size: 32, weight: .bold))
            Text("Pick one that matters to you. You'll watch it arrive in your Telegram library.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            photoGrid(selectable: true).padding(.top, 4)
        }
    }

    private var upload: some View {
        VStack(spacing: 22) {
            ring.padding(.top, 30)
            VStack(spacing: 10) {
                Text(title).font(.system(size: 30, weight: .bold)).multilineTextAlignment(.center)
                Text(detail).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .animation(.default, value: phase)
        }
        .frame(maxWidth: .infinity)
    }

    private func photoGrid(selectable: Bool) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
            ForEach(recent.photos) { photo in
                let isSelected = selected == photo.id
                Button {
                    guard selectable else { return }
                    Haptics.tap()
                    withAnimation(.spring(duration: 0.25)) { selected = isSelected ? nil : photo.id }
                } label: {
                    Color.white.opacity(0.08).aspectRatio(1, contentMode: .fit)
                        .overlay { if let image = photo.image { Image(platformImage: image).resizable().scaledToFill() } }
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            if photo.backedUp {
                                Circle().fill(Color.green).frame(width: 20, height: 20)
                                    .overlay { Image(systemName: "icloud.fill").font(.system(size: 10)).foregroundStyle(.white) }
                                    .padding(5)
                            }
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill").font(.title2).symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, Color.accentColor).padding(6)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3))
                        .scaleEffect(isSelected ? 0.94 : 1)
                }
                .buttonStyle(.plain)
                .disabled(!selectable)
                .accessibilityLabel(photo.backedUp ? "Photo, already backed up" : "Photo")
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
    }

    // MARK: Buttons

    @ViewBuilder private var buttons: some View {
        VStack(spacing: 10) {
            if returning || finished || phase == .nothing {
                PrimaryCapsuleButton(title: "Start using Memvo", action: done)
            } else if phase == .choosing {
                PrimaryCapsuleButton(title: "Back up this photo", enabled: selected != nil) {
                    if let selected { Task { await upload(selected) } }
                }
                Button("Skip for now", action: done).font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
            } else {
                PrimaryCapsuleButton(title: "Continue in the background", action: done)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
    }

    // MARK: Upload

    private var title: String {
        switch phase {
        case .choosing, .uploading: return "Backing up your first photo"
        case .safe: return "Your first photo is safe."
        case .alreadySafe: return "That photo is already safe."
        case .nothing: return "You're ready."
        case .stuck: return "Your first backup is waiting"
        }
    }

    private var detail: String {
        switch phase {
        case .choosing, .uploading: return "Uploading the original to your Telegram library."
        case .safe: return "Telegram confirmed it, at full quality. Back up now sends the rest."
        case .alreadySafe: return "It's in your Telegram library. Back up now sends the rest."
        case .nothing: return "There are no photos on this \(Device.name) yet. New ones can be backed up any time."
        case .stuck(let reason): return "\(reason) It carries on by itself once that's sorted."
        }
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.1), lineWidth: 6)
            Circle().trim(from: 0, to: finished ? 1 : progress)
                .stroke(finished ? Color.green : Color.accentColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Group {
                if let image = recent.photos.first(where: { $0.id == selected })?.image {
                    Image(platformImage: image).resizable().scaledToFill()
                } else {
                    Color.white.opacity(0.08).overlay { Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary) }
                }
            }
            .frame(width: 150, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            Image(systemName: "checkmark").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                .frame(width: 50, height: 50).background(Color.green, in: Circle())
                .overlay(Circle().stroke(Color.black, lineWidth: 3))
                .offset(x: 72, y: 72)
                .scaleEffect(finished ? 1 : 0.01)
                .opacity(finished ? 1 : 0)
                .animation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.45), value: finished)
        }
        .frame(width: 200, height: 200)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }

    private func upload(_ id: String) async {
        let env = AppEnvironment.shared
        withAnimation(.spring(duration: 0.45)) { phase = .uploading }
        if recent.photos.first(where: { $0.id == id })?.backedUp == true {
            phase = .alreadySafe
            Haptics.success()
            return
        }
        _ = await Task.detached { env.engine.enqueue(localIdentifiers: [id]) }.value
        appLog("Onboarding: backing up the chosen first photo")
        ContinuedBackup.start(everything: false)
        // Poll the index: "safe" means the engine saw Telegram confirm every part at the right size.
        var sawRunning = false
        for second in 0..<600 {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
            let item = await Task.detached { try? env.store.item(localIdentifier: id) }.value
            switch item?.status {
            case .backedUp?:
                withAnimation(.easeOut(duration: 0.3)) { progress = 1 }
                phase = .safe
                Haptics.success()
                appLog("Onboarding: first photo backed up")
                return
            case .failed?:
                phase = .stuck(item?.lastError ?? "The upload didn't go through. It's listed under Backup › Failed.")
                return
            default:
                if activity.isRunning { sawRunning = true; if phase != .uploading { phase = .uploading } }
                // The run ended, or never started, with the photo still queued: a setting such as Wi-Fi only is
                // holding it back. The message from a run before this one is ignored for the first few seconds.
                else if sawRunning || second > 8, let message = activity.message { phase = .stuck(message) }
            }
        }
    }
}


// MARK: - Data

/// Down-sampled sample photos bundled for the App Review demo (iOS only); the Mac falls back to gradients.
@MainActor
final class IntroPhotos: ObservableObject {
    @Published private(set) var images: [CGImage] = []

    func load() {
        guard images.isEmpty, let folder = DemoMode.folder else { return }
        Task.detached(priority: .userInitiated) {
            let loaded: [CGImage] = (1...24).compactMap { n in
                let url = folder.appendingPathComponent(String(format: "photo%02d.jpg", n))
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                kCGImageSourceCreateThumbnailWithTransform: true,
                                                kCGImageSourceThumbnailMaxPixelSize: 240]
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            }
            await MainActor.run { self.images = loaded }
        }
    }
}

/// The newest photos on this device, with whether each is already in the library. Fetched off the main actor;
/// thumbnails are published together so they can be dealt out in one go.
@MainActor
final class RecentPhotos: ObservableObject {
    struct Photo: Identifiable {
        let id: String
        var image: PlatformImage?
        let backedUp: Bool
    }

    @Published private(set) var photos: [Photo] = []
    @Published private(set) var loaded = false
    private var started = false

    /// `checkLibrary`: false before sign-in, when there's no library yet; only the device's photos are read.
    func load(limit: Int, checkLibrary: Bool = true) {
        guard !started else { return }
        started = true
        let env = AppEnvironment.shared
        Task {
            let found: [(PHAsset, Bool)] = await Task.detached(priority: .userInitiated) {
                let options = PHFetchOptions()
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                options.fetchLimit = limit
                let assets = PHAsset.fetchAssets(with: .image, options: options)
                return (0..<assets.count).map { i in
                    let asset = assets.object(at: i)
                    return (asset, checkLibrary && (try? env.store.item(localIdentifier: asset.localIdentifier))?.status == .backedUp)
                }
            }.value
            var photos = found.map { Photo(id: $0.0.localIdentifier, image: nil, backedUp: $0.1) }
            for (i, (asset, _)) in found.enumerated() { photos[i].image = await Self.thumbnail(asset) }
            self.photos = photos
            loaded = true
        }
    }

    private static func thumbnail(_ asset: PHAsset) async -> PlatformImage? {
        await withCheckedContinuation { done in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 360, height: 360), contentMode: .aspectFill,
                                                  options: options) { image, _ in done.resume(returning: image) }
        }
    }
}

/// The user's own library: item count first (instant), then total original size and free space (a few seconds
/// for a large library). Everything is read on the device; nothing is uploaded.
@MainActor
final class LibraryStats: ObservableObject {
    @Published private(set) var items = 0
    @Published private(set) var bytes: Int64?
    @Published private(set) var free: Int64?
    private var started = false

    func load() {
        guard !started else { return }
        started = true
        Task.detached(priority: .userInitiated) {
            let assets = PHAsset.fetchAssets(with: nil)
            let count = assets.count
            let free = (try? URL(fileURLWithPath: NSHomeDirectory())
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? nil
            await MainActor.run { self.items = count; self.free = free }
            var total: Int64 = 0
            for i in 0..<count {
                // The originals Memvo uploads (photo or video, and a Live Photo's video).
                for r in PHAssetResource.assetResources(for: assets.object(at: i))
                where [.photo, .video, .pairedVideo].contains(r.type) {
                    // `fileSize` isn't public API, but PHAssetResource has answered to it since iOS 10 and macOS 10.15.
                    total += (r.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0
                }
            }
            let measured = total
            await MainActor.run { self.bytes = measured }
            appLog("Intro: library has \(count) items, \(measured >> 20) MB")
        }
    }
}
