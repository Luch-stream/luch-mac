// The system broadcast picker, stretched under our capsule: the tap goes to the system button
// itself, which opens the confirmation. No programmatic presses.
// SPDX-License-Identifier: GPL-3.0-or-later
import ReplayKit
import SwiftUI

struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let view = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 220, height: 44))
        view.preferredExtension = "dev.luch.ios.broadcast"
        view.showsMicrophoneButton = false
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        return view
    }

    func updateUIView(_ view: RPSystemBroadcastPickerView, context: Context) {}
}
