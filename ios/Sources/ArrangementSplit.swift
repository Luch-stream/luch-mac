// Apple's own two-pane container for foldables and wide screens: UIArrangementViewController with a
// split arrangement. It places the panes around the fold and the reserved regions itself, so the app
// does not have to guess where the crease is.
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UIKit

@available(iOS 27.1, *)
struct ArrangementSplit<Primary: View, Secondary: View>: UIViewControllerRepresentable {
    let primary: Primary
    let secondary: Secondary

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIArrangementViewController {
        let controller = UIArrangementViewController()
        controller.view.backgroundColor = UIColor(LuchStyle.background)

        let primaryHost = UIHostingController(rootView: primary)
        let secondaryHost = UIHostingController(rootView: secondary)
        for host in [primaryHost, secondaryHost] {
            host.view.backgroundColor = .clear
        }
        controller.setViewController(primaryHost, for: .primary)
        controller.setViewController(secondaryHost, for: .secondary)
        controller.updateArrangement(UISplitArrangement(), animated: false)
        context.coordinator.primary = primaryHost
        context.coordinator.secondary = secondaryHost
        return controller
    }

    func updateUIViewController(_ controller: UIArrangementViewController, context: Context) {
        // The panes are hosting controllers, so new state has to be pushed into them.
        context.coordinator.primary?.rootView = primary
        context.coordinator.secondary?.rootView = secondary
    }

    final class Coordinator {
        var primary: UIHostingController<Primary>?
        var secondary: UIHostingController<Secondary>?
    }
}
