// Debug-only launch overrides: `-luchUI` picks the screen to show, `-luchFold` forces the Duo
// split. Both are read once at launch and are inert unless this is a Debug build or the host
// sets LUCH_UI_DEBUG=1. They never touch the receiver, the network or the audio path.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum UIDebugLaunch {
    /// What the app should look like right after launch. `error` is the failed receiver screen;
    /// `streamingHidden` is a live session whose HUD is already out of the way.
    enum State: String {
        case waiting
        case streaming
        case streamingHidden
        case ended
        case error
        case settings
    }

    /// The synthetic layout to draw when the simulator has no hinge to report.
    enum Pose: String {
        /// Fully open inner display: the content-first two-pane layout.
        case open
        case book
        case tabletop
        case tent
    }

    private static let enabled: Bool = {
        #if DEBUG
        return true
        #else
        return ProcessInfo.processInfo.environment["LUCH_UI_DEBUG"] == "1"
        #endif
    }()

    static let state: State? = enabled ? flagValue("-luchUI").flatMap(State.init(rawValue:)) : nil
    static let fold: Pose? = enabled ? flagValue("-luchFold").flatMap(Pose.init(rawValue:)) : nil

    /// The HUD is up for a normal streaming screenshot and hidden for `streamingHidden`.
    static var hudHidden: Bool { state == .streamingHidden }

    /// Debug streaming keeps the HUD on screen instead of letting it fade after three seconds.
    static var keepsHUDVisible: Bool { state == .streaming }

    private static func flagValue(_ flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        for (index, argument) in arguments.enumerated() {
            if argument == flag, index + 1 < arguments.count {
                return arguments[index + 1]
            }
            if argument.hasPrefix(flag + "=") {
                return String(argument.dropFirst(flag.count + 1))
            }
        }
        return nil
    }
}
