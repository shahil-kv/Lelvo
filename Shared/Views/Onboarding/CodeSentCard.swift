import SwiftUI

/// A small picture of where the login code landed: the Telegram service chat, or Messages for SMS. People waiting for
/// an SMS didn't notice Telegram had sent the code to the Telegram app, so the code screen shows them what to look for.
/// Plays once when it appears: typing dots, the message lands, a light runs across the code. Tap to replay;
/// Reduce Motion shows it at rest.
struct CodeSentCard: View {
    let delivery: TDService.CodeDelivery
    /// Shows an Open button in the header, which stays above the keyboard.
    var open: (() -> Void)? = nil

    private enum Phase: Int { case hidden, card, typing, message }
    @State private var phase = Phase.hidden
    @State private var glow = false
    @State private var run = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var telegram: Bool { delivery == .telegram }
    private var brand: Color { telegram ? Self.telegramBlue : Color(red: 0.2, green: 0.78, blue: 0.35) }
    private var bubble: Color { telegram ? Color(red: 0.13, green: 0.17, blue: 0.23) : Color(white: 0.17) }
    static let telegramBlue = Color(red: 0.16, green: 0.67, blue: 0.93)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ZStack(alignment: .bottomLeading) {
                Color.clear
                if phase == .typing { TypingDots(color: bubble) }
                if phase == .message {
                    message.transition(.asymmetric(insertion: .scale(scale: 0.88, anchor: .bottomLeading).combined(with: .opacity),
                                                   removal: .opacity))
                }
            }
            .frame(minHeight: 46)
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 14)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.11), Color(white: 0.07)], startPoint: .top, endPoint: .bottom))
                // A faint wash of the app's colour, so the card reads as Telegram (or Messages) at a glance.
                .overlay(alignment: .topLeading) {
                    RadialGradient(colors: [brand.opacity(0.16), .clear], center: .topLeading, startRadius: 0, endRadius: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
        }
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
        .opacity(phase == .hidden ? 0 : 1)
        .offset(y: phase == .hidden ? 12 : 0)
        .scaleEffect(phase == .hidden ? 0.96 : 1, anchor: .top)
        .contentShape(Rectangle())
        .onTapGesture { if !reduceMotion { run += 1 } }
        .task(id: run) { await play() }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                if telegram {
                    TelegramMark()
                } else {
                    Image(systemName: "message.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 24, height: 24).background(brand, in: Circle())
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        Text(telegram ? "Telegram" : "Messages").font(.subheadline.weight(.semibold))
                        if telegram {
                            Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(Self.telegramBlue)
                        }
                    }
                    Text(telegram ? "service notifications" : "text message").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(telegram ? "Example: the message from Telegram with your login code"
                                         : "Example: the text message with your login code")
            Spacer(minLength: 8)
            if let open {
                Button(action: open) {
                    HStack(spacing: 5) {
                        Text("Open")
                        Image(systemName: "arrow.up.right").font(.caption.weight(.bold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 13).padding(.vertical, 7)
                    .background(Self.telegramBlue, in: Capsule())
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Telegram")
            }
        }
    }

    private var message: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(telegram ? "Login code:" : "Telegram code:").fontWeight(.medium)
                // Grey blocks, not digits: a made-up code would get typed in.
                HStack(spacing: 3) {
                    ForEach(0..<5, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(glow ? brand : Color.white.opacity(0.3))
                            .frame(width: 9, height: 14)
                            .scaleEffect(glow ? 1.12 : 1)
                            .animation(Motion.tap.delay(Double(i) * 0.06), value: glow)
                    }
                }
            }
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(telegram ? "Do not give this code to anyone, even if they say they are from Telegram."
                              : "Don't share it with anyone.")
                    .foregroundStyle(.white.opacity(0.78)).lineLimit(1)
                Text("now").font(.caption2).foregroundStyle(.white.opacity(0.45))
            }
        }
        .font(.footnote)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(bubble, in: UnevenRoundedRectangle(topLeadingRadius: 17, bottomLeadingRadius: 5,
                                                         bottomTrailingRadius: 17, topTrailingRadius: 17, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func play() async {
        if reduceMotion {
            phase = .message
            return
        }
        glow = false
        phase = .hidden
        try? await Task.sleep(for: .milliseconds(80))
        withAnimation(Motion.standard) { phase = .card }
        try? await Task.sleep(for: .milliseconds(280))
        withAnimation(Motion.tap) { phase = .typing }
        try? await Task.sleep(for: .milliseconds(750))
        guard !Task.isCancelled else { return }
        withAnimation(Motion.emphasis) { phase = .message }
        // A light runs across the code once, so the eye lands on it.
        try? await Task.sleep(for: .milliseconds(380))
        glow = true
        try? await Task.sleep(for: .milliseconds(520))
        glow = false
    }
}

/// Telegram's three bouncing dots, only on screen for under a second.
private struct TypingDots: View {
    let color: Color

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    let wave = (sin((t * 2 * .pi * 1.2) - Double(i) * 0.9) + 1) / 2
                    Circle().fill(Color.white.opacity(0.35 + 0.5 * wave)).frame(width: 6, height: 6)
                        .offset(y: -2 * wave)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            .background(color, in: UnevenRoundedRectangle(topLeadingRadius: 17, bottomLeadingRadius: 5,
                                                           bottomTrailingRadius: 17, topTrailingRadius: 17, style: .continuous))
        }
        .transition(.scale(scale: 0.8, anchor: .bottomLeading).combined(with: .opacity))
    }
}

// Drawn rather than an image asset: SF Symbols has no brand logos, and shapes stay sharp at every Dynamic Type size.
/// Telegram's mark: a white paper plane on the blue circle.
private struct TelegramMark: View {
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 24

    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.67, blue: 0.93), Color(red: 0.13, green: 0.62, blue: 0.85)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(.white)
                    .offset(x: -size * 0.03, y: size * 0.02)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
