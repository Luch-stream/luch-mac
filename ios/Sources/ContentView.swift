// The app's root: one receiver, and a screen for each stage of the session.
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UIKit

struct ContentView: View {
    enum Mode: String, CaseIterable { case receive = "Принимать", send = "Отправлять" }

    @State private var mode: Mode = UIDebugLaunch.page == 1 ? .send : .receive
    private var pageIndex: Binding<Int> {
        Binding(
            get: { mode == .receive ? 0 : 1 },
            set: { mode = $0 == 0 ? .receive : .send })
    }
    @State private var viewer = Viewer()
    @State private var settingsPresented = false

    var body: some View {
        ZStack {
            LuchStyle.background.ignoresSafeArea()

            // Two pages the user swipes between; the dots below show where they are, and the
            // page content (card, hints, buttons) is rebuilt as the page changes.
            if viewer.phase == .waiting {
                HomeView(viewer: viewer, pageIndex: pageIndex, onSettings: presentSettings)
            } else {
                receiving
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

    @ViewBuilder
    private var receiving: some View {
            switch viewer.phase {
            case .waiting:
                HomeView(viewer: viewer, pageIndex: pageIndex, onSettings: presentSettings)
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

    private func presentSettings() {
        settingsPresented = true
    }
}
