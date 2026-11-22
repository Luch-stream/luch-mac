// ReplayKit's own button. Apple requires the user to confirm a broadcast, and this is the control
// that does it; the app just gives it a place in the card.
// SPDX-License-Identifier: GPL-3.0-or-later
import ReplayKit
import SwiftUI

struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let view = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 56, height: 56))
        view.preferredExtension = "dev.luch.ios.broadcast"
        view.showsMicrophoneButton = false
        return view
    }

    func updateUIView(_ view: RPSystemBroadcastPickerView, context: Context) {}
}
