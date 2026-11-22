// Экран приёма: ищем отправителя, показываем картинку и статистику.
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UIKit
import LuchReceive

final class Viewer: ObservableObject, Identifiable {
    @Published var status = "Ожидание отправителя"
    @Published var stats = ""
    var surface: VideoSurfaceView?

    private var receiver: Receiver?

    func attach(_ view: VideoSurfaceView) {
        guard receiver == nil else { return }
        surface = view
        view.onBroken = { [weak self] in self?.receiver?.requestKeyframe() }
        let receiver = Receiver(name: UIDevice.current.name, sink: view)
        receiver.onSession = { [weak self] sender in
            DispatchQueue.main.async {
                self?.status = sender.map { "Смотрим: \($0)" } ?? "Ожидание отправителя"
                UIApplication.shared.isIdleTimerDisabled = sender != nil
            }
        }
        receiver.onStats = { [weak self] stats in
            DispatchQueue.main.async {
                self?.stats = String(format: "%.0f fps · %.1f ms · потеряно %d",
                                     stats.fps, stats.decodeMs, stats.lost)
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
