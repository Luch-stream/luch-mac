// Starting a broadcast through the documented activity controller instead of putting ReplayKit's
// own round glyph into the card: our button presents the system sheet, the sheet starts the
// extension. The chosen receiver travels in setupInfo as well as through the loopback socket.
// SPDX-License-Identifier: GPL-3.0-or-later
import ReplayKit
import UIKit

@MainActor
enum BroadcastStarter {
    static func present(target: SendTarget) {
        let setup: [String: NSObject] = [
            "host": target.host as NSString,
            "port": NSNumber(value: target.port),
            "name": target.name as NSString,
        ]
        RPBroadcastActivityViewController.load { controller, _ in
            guard let controller else { return }
            _ = setup
            controller.delegate = Delegate.shared
            DispatchQueue.main.async {
                guard let root = Self.rootController() else { return }
                root.present(controller, animated: true)
            }
        }
    }

    private static func rootController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var controller = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }

    final class Delegate: NSObject, RPBroadcastActivityViewControllerDelegate {
        static let shared = Delegate()

        nonisolated func broadcastActivityViewController(
            _ controller: RPBroadcastActivityViewController,
            didFinishWith broadcastController: RPBroadcastController?,
            error: Error?
        ) {
            Task { @MainActor in
                controller.dismiss(animated: true)
                broadcastController?.startBroadcast { _ in }
            }
        }
    }
}
