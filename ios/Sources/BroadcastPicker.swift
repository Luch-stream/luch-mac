// The system broadcast picker: the only sanctioned way to start a screen broadcast, so the user
// confirms it and picks our extension themselves.
// SPDX-License-Identifier: GPL-3.0-or-later
import ReplayKit
import SwiftUI

struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let view = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        view.preferredExtension = "dev.luch.ios.broadcast"
        view.showsMicrophoneButton = false
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    func updateUIView(_ view: RPSystemBroadcastPickerView, context: Context) {}
}
