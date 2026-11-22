// Экран приёма: ищем отправителя, показываем картинку и статистику.
// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import LuchReceive
import SwiftUI
import UIKit

/// Frames go to whichever view is on screen right now: SwiftUI may recreate it, and the receiver
/// keeps a stable sink instead of a view that may already be gone.
final class VideoRelay: VideoSink {
    weak var view: VideoSurfaceView?
    func enqueue(_ sample: CMSampleBuffer) { view?.enqueue(sample) }
    func flush() { view?.flush() }
}

final class Viewer: ObservableObject, Identifiable {
    @Published var status = "Ожидание отправителя"
    @Published var stats = ""
    var surface: VideoSurfaceView?
    let relay = VideoRelay()

    private var receiver: Receiver?

    func attach(_ view: VideoSurfaceView) {
        relay.view = view
        surface = view
        guard receiver == nil else { return }
        view.onBroken = { [weak self] in self?.receiver?.requestKeyframe() }
        let receiver = Receiver(name: UIDevice.current.name, sink: relay)
        receiver.onSession = { [weak self] sender in
            DispatchQueue.main.async {
                self?.status = sender.map { "Смотрим: \($0)" } ?? "Ожидание отправителя"
                UIApplication.shared.isIdleTimerDisabled = sender != nil
            }
        }
        receiver.onStats = { [weak self] stats in
            DispatchQueue.main.async {
                let extra = self?.surface.map {
                    " · enq \($0.enqueued) \($0.lastStatus) v=\(Int($0.bounds.width))x\(Int($0.bounds.height)) l=\(Int($0.displayLayerFrame.width))x\(Int($0.displayLayerFrame.height))"
                } ?? ""
                self?.stats = String(format: "%.0f fps · %.1f ms · потеряно %d", stats.fps, stats.decodeMs, stats.lost) + extra
            }
        }
        do {
            try receiver.start()
            self.receiver = receiver
        } catch {
            status = "Не удалось запустить приём: \(error.localizedDescription)"
        }
    }
}

struct ContentView: View {
    @StateObject private var viewer = Viewer()

    var body: some View {
        ZStack(alignment: .topLeading) {
            VideoSurface { viewer.attach($0) }
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 4) {
                Text(viewer.status).font(.caption).bold()
                if !viewer.stats.isEmpty { Text(viewer.stats).font(.caption2).monospacedDigit() }
            }
            .padding(10)
            .foregroundStyle(.white)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            .padding(12)
        }
        .background(.black)
    }
}
