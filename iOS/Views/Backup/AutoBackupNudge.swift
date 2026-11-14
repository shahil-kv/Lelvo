import LelvoCore
import SwiftUI

/// Asked right after a backup the person started finishes with everything safe, while automatic backup is off: the
/// moment they've just seen it work. Shown at most twice (`BackgroundRuns.shouldNudgeAutoBackup`).
struct AutoBackupNudgeSheet: View {
    let backedUp: Int
    @AppStorage(Prefs.Key.autoBackup) private var autoBackup = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turnedOn = false
    @State private var showInfo = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if turnedOn {
                        doneState
                    } else {
                        AutoBackupIllustration()
                            .frame(height: 150)
                            .accessibilityHidden(true)
                        Text("Everything is backed up")
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                        Text(backedUp > 0
                             ? "\(backedUp.formatted()) photos and videos are safe. Back up new ones on their own, so you don't have to remember."
                             : "Back up new photos on their own, so you don't have to remember.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 4)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom) { buttons }
            // No bar band above the picture: the info button floats like the close button in Apple's own sheets.
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showInfo = true } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel("How automatic backup works")
                }
            }
            .navigationDestination(isPresented: $showInfo) { AutomaticBackupExplainerView() }
            .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.3), value: turnedOn)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var doneState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.white, .green)
                .symbolEffect(.bounce, value: turnedOn)
                .padding(.top, 24)
            Text("Automatic backup is on").font(.title2.bold())
            Text("New photos go up when you open Lelvo, in the background and overnight. You can change this in Settings.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    private var buttons: some View {
        VStack(spacing: 6) {
            if turnedOn {
                Button { dismiss() } label: { Text("Done").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                Button {
                    autoBackup = true
                    Haptics.start()
                    turnedOn = true
                    // Photos taken since the backup that just finished go up now.
                    ContinuedBackup.start(everything: true)
                } label: { Text("Turn on automatic backup").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Button("Not now") { dismiss() }
                    .controlSize(.large)
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 8).padding(.top, 6)
    }
}

private struct TintedIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(Color.accentColor)
            configuration.title
        }
    }
}

/// A new photo appears on the phone and flies into the cloud, which gets a check. The line under it says when that
/// happens; it changes each pass. Uses the person's own recent photos. Transform and opacity only.
struct AutoBackupIllustration: View {
    @StateObject private var recent = RecentPhotos()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let cycle = 4.8
    private let whens: [(String, String)] = [("iphone", "When you open Lelvo"), ("clock", "In the background"),
                                             ("moon.zzz", "Overnight")]

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            // Reduce Motion: one still frame, with the photo already safe.
            let t = reduceMotion ? 0.8 : (time.truncatingRemainder(dividingBy: cycle)) / cycle
            let pass = reduceMotion ? 0 : Int(time / cycle) % whens.count
            scene(t: t, pass: pass)
        }
        .onAppear { recent.load(limit: 10, checkLibrary: false, skipScreenshots: true) }
    }

    private func scene(t: Double, pass: Int) -> some View {
        ZStack(alignment: .topLeading) {
            miniPhone.offset(x: 18, y: 18)
            // Shutter flash over the phone's screen.
            RoundedRectangle(cornerRadius: 11).fill(.white)
                .frame(width: 70, height: 118).offset(x: 21, y: 21)
                .opacity(0.85 * bump(t, 0.06, 0.09, 0.18))
            flyingPhoto(t: t)
            cloud(t: t).offset(x: 138, y: 14)
            Label(whens[pass].1, systemImage: whens[pass].0)
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .labelStyle(TintedIconLabel())
                .id(pass)
                .transition(.opacity.combined(with: .offset(y: 4)))
                .offset(x: 104, y: 118)
        }
        .frame(width: 250, height: 150, alignment: .topLeading)
        .animation(.easeOut(duration: 0.25), value: pass)
    }

    private var miniPhone: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(.primary, lineWidth: 3)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.systemGroupedBackground)))
            .frame(width: 76, height: 124)
            .overlay(alignment: .top) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(20), spacing: 2), count: 3), spacing: 2) {
                    ForEach(0..<9, id: \.self) { i in tile(i + 1) }
                }
                .padding(.top, 14)
            }
    }

    private func tile(_ i: Int) -> some View {
        Rectangle().fill(Color.accentColor.opacity(0.15 + 0.05 * Double(i % 4)))
            .frame(width: 20, height: 20)
            .overlay {
                if i < recent.photos.count, let image = recent.photos[i].image {
                    Image(platformImage: image).resizable().scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
    }

    private func flyingPhoto(t: Double) -> some View {
        // Appear, lift, fly to the cloud while shrinking, fade into it.
        let appear = ramp(t, 0.12, 0.20)
        let travel = ease(ramp(t, 0.34, 0.62))
        let scale = (0.6 + 0.4 * appear) * (1 - 0.45 * travel) + 0.08 * bump(t, 0.20, 0.34, 0.40)
        return RoundedRectangle(cornerRadius: 5)
            .fill(Color.accentColor.opacity(0.3))
            .overlay {
                if let image = recent.photos.first?.image { Image(platformImage: image).resizable().scaledToFill() }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 4)
            .scaleEffect(scale)
            .offset(x: 40 + 128 * travel, y: 76 - 62 * travel - 4 * bump(t, 0.20, 0.34, 0.40))
            .opacity(appear * (1 - ramp(t, 0.62, 0.68)))
    }

    private func cloud(t: Double) -> some View {
        let pop = t < 0.62 ? 0 : t < 0.70 ? 1.18 * ramp(t, 0.62, 0.70) : t < 0.76 ? 1.18 - 0.18 * ramp(t, 0.70, 0.76) : t < 0.92 ? 1 : 1 - ramp(t, 0.92, 1)
        return Image(systemName: "icloud.and.arrow.up.fill")
            .font(.system(size: 64))
            .foregroundStyle(Color.accentColor)
            .frame(width: 96, height: 72)
            .overlay(alignment: .topTrailing) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white, .green)
                    .background(Circle().fill(Color(.systemBackground)).padding(-2))
                    .scaleEffect(pop)
                    .offset(x: 4, y: -6)
            }
    }

    private func ramp(_ t: Double, _ a: Double, _ b: Double) -> Double { min(max((t - a) / (b - a), 0), 1) }
    private func ease(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    /// 0 → 1 → 0 between a, peak and b.
    private func bump(_ t: Double, _ a: Double, _ peak: Double, _ b: Double) -> Double {
        t < peak ? ramp(t, a, peak) : 1 - ramp(t, peak, b)
    }
}
