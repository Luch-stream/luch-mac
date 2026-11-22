// The finished and failed screens: the session is over, or the receiver could not start.
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct EndedView: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void
    let onSettings: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var occlusionTop: CGFloat = 0

    var body: some View {
        ZStack {
            AmbientBackdrop()

            VStack(spacing: 0) {
                Spacer(minLength: 32)

                ZStack {
                    Circle()
                        .fill(tint.opacity(0.10))
                        .frame(width: 96, height: 96)
                        .overlay(Circle().strokeBorder(LuchStyle.separator, lineWidth: 0.5))
                    Image(systemName: symbol)
                        .font(.system(size: 40, weight: .regular))
                        .foregroundStyle(tint)
                }
                .scaleEffect(appeared ? 1 : 0.92)
                .accessibilityHidden(true)

                Text(title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(LuchStyle.primaryText)
                    .multilineTextAlignment(.center)
                    .padding(.top, 26)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(LuchStyle.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)

                PrimaryActionButton(title: actionTitle, systemImage: "arrow.clockwise", action: action)
                    .padding(.top, 30)

                Spacer(minLength: 32)
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: 420)
            .opacity(appeared ? 1 : 0)
        }
        .overlay(alignment: .topTrailing) {
            SettingsIconButton(action: onSettings)
                .padding(.top, 10 + occlusionTop)
                .padding(.trailing, 20)
        }
        .background {
            GeometryReader { proxy in
                Color.clear.onAppear {
                    occlusionTop = ReservedSpace.occlusionInsets(in: proxy).top
                }
            }
        }
        .onAppear {
            guard !appeared else { return }
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.spring(duration: 0.55, bounce: 0.12)) {
                    appeared = true
                }
            }
        }
    }
}
