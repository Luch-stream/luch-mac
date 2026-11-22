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
    var audio: PcmSink?
    @Published var status = "Ожидание отправителя"
    @Published var streaming = false
    @Published var stats = ""
    var surface: VideoSurfaceView?
    let relay = VideoRelay()

    private var receiver: Receiver?

    /// The view only shows frames; the receiver lives independently, so a view that is not on
    /// screen yet does not stop the device from being discoverable.
    func attach(_ view: VideoSurfaceView) {
        relay.view = view
        surface = view
        view.onBroken = { [weak self] in self?.receiver?.requestKeyframe() }
    }

    func start() {
        guard receiver == nil else { return }
        let receiver = Receiver(name: UIDevice.current.name, sink: relay, audioCodecs: ["audio/pcm"])
        receiver.makeAudio = { [weak self] fd in
            let sink = PcmSink(fd: fd)
            DispatchQueue.main.async { self?.audio = sink }
            return sink
        }
        receiver.onSession = { [weak self] sender in
            DispatchQueue.main.async {
                self?.status = sender.map { "Смотрим: \($0)" } ?? "Ожидание отправителя"
                self?.streaming = sender != nil
                UIApplication.shared.isIdleTimerDisabled = sender != nil
                if sender == nil {
                    // The session is over: drop the last frame instead of freezing on it.
                    self?.surface?.flush()
                }
            }
        }
        receiver.onStats = { [weak self] stats in
            DispatchQueue.main.async {
                let audioCounters = self?.audio.map { a in
                    let c = a.counters
                    return " · a \(c.appended) p \(c.played) u \(c.underruns) q \(c.queued)"
                } ?? ""
                let extra = (self?.surface.map {
                    " · enq \($0.enqueued) \($0.lastStatus) v=\(Int($0.bounds.width))x\(Int($0.bounds.height)) l=\(Int($0.displayLayerFrame.width))x\(Int($0.displayLayerFrame.height))"
                } ?? "") + audioCounters
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
            Color.black.ignoresSafeArea()
            if viewer.streaming {
                VideoSurface { viewer.attach($0) }
                    .ignoresSafeArea()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(viewer.status).font(.caption).bold()
                if !viewer.stats.isEmpty { Text(viewer.stats).font(.caption2).monospacedDigit() }
            }
            .padding(10)
            .foregroundStyle(.white)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            .padding(12)
        }
        .onAppear { viewer.start() }
    }
}
