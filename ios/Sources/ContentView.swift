// The app's root: one receiver, and a screen for each stage of the session.
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UIKit

struct ContentView: View {
    @State private var viewer = Viewer()
    @State private var settingsPresented = false

    var body: some View {
        ZStack {
            LuchStyle.background.ignoresSafeArea()

            switch viewer.phase {
            case .waiting:
                WaitingView(deviceName: UIDevice.current.name, senders: viewer.senders, onSettings: presentSettings)
                    .transition(.opacity)
            case .streaming:
                StreamView(
                    viewer: viewer,
                    settingsPresented: $settingsPresented,
                    startsWithControlsHidden: UIDebugLaunch.hudHidden,
                    autoHidesControls: !UIDebugLaunch.keepsHUDVisible)
                    .transition(.opacity)
            case .ended:
                EndedView(
                    symbol: "checkmark.circle.fill",
                    tint: LuchStyle.primaryText,
                    title: "Трансляция завершена",
                    message: "Ожидание отправителя",
                    actionTitle: "Искать снова",
                    action: { viewer.searchAgain() },
                    onSettings: presentSettings)
                    .transition(.opacity)
            case .failed:
                EndedView(
                    symbol: "exclamationmark.triangle.fill",
                    tint: LuchStyle.primaryText,
                    title: "Не удалось запустить приём",
                    message: "Проверьте подключение к сети и попробуйте снова",
                    actionTitle: "Попробовать снова",
                    action: { viewer.searchAgain() },
                    onSettings: presentSettings)
                    .transition(.opacity)
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.onAppear { ReservedSpace.probeUntilChanged(proxy) }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: viewer.phase)
        .sheet(isPresented: $settingsPresented) {
            SettingsView()
        }
        .preferredColorScheme(.dark)
        .task {
            // A `-luchUI` launch shows the screen directly and never starts the receiver.
            if let state = UIDebugLaunch.state {
                viewer.applyDebugLaunch(state)
                if state == .settings {
                    // Let the waiting screen settle before the sheet slides in.
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    settingsPresented = true
                }
                return
            }
            viewer.start()
        }
    }

    private func presentSettings() {
        settingsPresented = true
    }
}
