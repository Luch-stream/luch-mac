// The hinge angle, bridged into SwiftUI. iOS 27.2 has no SwiftUI hinge API yet — only UIKit's
// UIHingeInteraction — so this one file is the whole UIKit surface: an invisible view that reports
// the angle and nothing else.
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UIKit

@available(iOS 27.1, *)
struct HingeAngleReader: UIViewRepresentable {
    /// Degrees between the two halves; nil when the hierarchy has no hinge (a flat phone, a tablet).
    let onChange: (CGFloat?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        context.coordinator.interaction = UIHingeInteraction { _, update in
            onChange(update.hinge?.angle)
        }
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
