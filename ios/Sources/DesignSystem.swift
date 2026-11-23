// Shared visual language: the Android client's palette, glass surfaces, status dots, and the
// number formatting for the HUD. The app is always dark: it is a video receiver.
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

enum LuchStyle {
    /// #121318 — the background of the current Android client (Material 3 status screen).
    static let background = Color(red: 18.0 / 255, green: 19.0 / 255, blue: 24.0 / 255)
    /// #1E1F24 — the cards the Android client puts its content on.
    static let surface = Color(red: 30.0 / 255, green: 31.0 / 255, blue: 36.0 / 255)
    /// #99000000 — black at 60%, the floating HUD colour over video.
    static let panel = Color.black.opacity(0.6)
    /// #F8B858 — the gold accent: the mark, the live dot and the primary action.
    static let accent = Color(red: 255.0 / 255, green: 186.0 / 255, blue: 95.0 / 255)
    /// #E3E2E8 — the Android client does not use pure white, and neither should we.
    static let primaryText = Color(red: 227.0 / 255, green: 226.0 / 255, blue: 232.0 / 255)
    /// #C4C6D0 — muted text in the Android client.
    static let secondaryText = Color(red: 196.0 / 255, green: 198.0 / 255, blue: 208.0 / 255)
    /// #292A2F — cards that sit on top of other cards.
    static let surfaceHigh = Color(red: 41.0 / 255, green: 42.0 / 255, blue: 47.0 / 255)
    /// #47484D — dividers and outlines.
    static let separator = Color(red: 71.0 / 255, green: 72.0 / 255, blue: 77.0 / 255)
    /// The live dot keeps the accent: the Android client paints its "receiving" icon gold.
    static let live = accent
    static let videoCorner: CGFloat = 30
    static let panelCorner: CGFloat = 26
}

/// A floating control surface: Liquid Glass on iOS 26, an ultra-thin material tinted to #99000000
/// before it. Layout and padding belong to the caller; the effect is always the last layer.
struct GlassSurface: ViewModifier {
    var cornerRadius: CGFloat
    var tint: Color? = LuchStyle.panel

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26, *) {
            if let tint {
                content.glassEffect(.regular.tint(tint), in: shape)
            } else {
                content.glassEffect(.regular, in: shape)
            }
        } else {
            content
                .background {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        if let tint { shape.fill(tint) }
                    }
                }
                .overlay {
                    shape.strokeBorder(LuchStyle.separator, lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        }
    }
}

extension View {
    func glassSurface(cornerRadius: CGFloat = LuchStyle.panelCorner, tint: Color? = LuchStyle.panel)
        -> some View
    {
        modifier(GlassSurface(cornerRadius: cornerRadius, tint: tint))
    }
}

/// A calm, expanding dot used for "searching" and "live" states.
struct PulseDot: View {
    var color: Color = LuchStyle.secondaryText
    var diameter: CGFloat = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .overlay {
                if !reduceMotion {
                    Circle()
                        .stroke(color.opacity(0.8), lineWidth: 1)
                        .scaleEffect(expanded ? 2.8 : 1)
                        .opacity(expanded ? 0 : 0.9)
                }
            }
            .onAppear {
                guard !reduceMotion, !expanded else { return }
                withAnimation(.easeOut(duration: 1.7).repeatForever(autoreverses: false)) {
                    expanded = true
                }
            }
            .accessibilityHidden(true)
    }
}

struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            PulseDot(color: LuchStyle.live, diameter: 7)
            Text("LIVE")
                .font(.caption2.weight(.bold))
                .tracking(0.9)
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.white.opacity(0.12), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Прямая трансляция")
    }
}

enum StatsFormat {
    static func fps(_ value: Double) -> String {
        value > 0 ? "\(Int(value.rounded())) fps" : "— fps"
    }

    static func latency(_ value: Double) -> String {
        value > 0 ? "\(Int(value.rounded())) мс" : "— мс"
    }
}

/// One line of live numbers. Monospaced digits keep the label from twitching every second.
struct StatsLine: View {
    let fps: Double
    let latency: Double

    var body: some View {
        HStack(spacing: 6) {
            Text(StatsFormat.fps(fps))
                .contentTransition(.numericText())
                .lineLimit(1)
            Text("·").foregroundStyle(.white.opacity(0.4))
            Text(StatsFormat.latency(latency))
                .contentTransition(.numericText())
                .lineLimit(1)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(LuchStyle.secondaryText)
        .animation(.easeOut(duration: 0.25), value: fps)
        .animation(.easeOut(duration: 0.25), value: latency)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Settings entry point on the waiting and finished screens.
struct SettingsIconButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LuchStyle.primaryText)
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.10), in: Circle())
                .overlay(Circle().strokeBorder(LuchStyle.separator, lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Настройки")
    }
}

/// Primary action for the finished and failed screens: a white plate with black text.
struct PrimaryActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.black)
                .padding(.horizontal, 22)
                .padding(.vertical, 13)
                .background(.white, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The dark backdrop shared by the waiting and finished screens: #101418 with soft white halos.
struct AmbientBackdrop: View {
    var body: some View {
        ZStack {
            LuchStyle.background

            GeometryReader { proxy in
                Circle()
                    .fill(.white.opacity(0.06))
                    .frame(width: proxy.size.width * 0.9)
                    .blur(radius: 140)
                    .offset(x: -proxy.size.width * 0.25, y: -proxy.size.height * 0.2)
                Circle()
                    .fill(.white.opacity(0.04))
                    .frame(width: proxy.size.width * 0.8)
                    .blur(radius: 130)
                    .offset(x: proxy.size.width * 0.3, y: proxy.size.height * 0.3)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
