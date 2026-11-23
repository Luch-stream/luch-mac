// The hinge angle, bridged into SwiftUI. iOS 27.2 has no SwiftUI hinge API yet — only UIKit's
// UIHingeInteraction — so this one file is the whole UIKit surface: an invisible view that reports
// the angle and nothing else.
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UIKit

@available(iOS 27.1, *)
struct HingeAngleReader: UIViewRepresentable {
    /// Degrees between the two halves (180 = flat open); nil when the hierarchy has no hinge.
    let onChange: (CGFloat?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        let interaction = UIHingeInteraction { _, update in
            // UIKit reports radians; the screen thinks in degrees.
            let degrees = update.hinge.map { $0.angle * 180 / .pi }
            #if DEBUG
                NSLog("Luch hinge: angle=%@° status=%@",
                      degrees.map { String(format: "%.1f", $0) } ?? "nil",
                      update.hinge.map { "\($0.status.rawValue)" } ?? "nil")
            #endif
            onChange(degrees)
        }
        view.addInteraction(interaction)
        context.coordinator.interaction = interaction
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    final class Coordinator {
        var interaction: UIHingeInteraction?
    }
}

extension View {
    /// Reports the hinge angle while the device is fitted with one; does nothing elsewhere.
    @ViewBuilder
    func readingHinge(_ onChange: @escaping (CGFloat?) -> Void) -> some View {
        if #available(iOS 27.1, *) {
            background(HingeAngleReader(onChange: onChange))
        } else {
            self
        }
    }
}
