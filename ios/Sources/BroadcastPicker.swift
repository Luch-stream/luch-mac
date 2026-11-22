// The system broadcast picker has to start the broadcast — that is the only sanctioned path — but
// its own glyph in the middle of our card looked foreign. It stays hidden and is pressed for us
// when the user taps our button.
// SPDX-License-Identifier: GPL-3.0-or-later
import ReplayKit
import SwiftUI

struct BroadcastPicker: UIViewRepresentable {
    /// Bump it to press the system button.
    var trigger: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let view = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        view.preferredExtension = "dev.luch.ios.broadcast"
        view.showsMicrophoneButton = false
        return view
    }

    func updateUIView(_ view: RPSystemBroadcastPickerView, context: Context) {
        guard context.coordinator.last != trigger else { return }
        context.coordinator.last = trigger
        guard trigger > 0 else { return }
        let button = view.subviews.compactMap { $0 as? UIButton }.first
        button?.sendActions(for: .touchUpInside)
    }

    final class Coordinator { var last = 0 }
}
