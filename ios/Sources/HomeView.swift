// The home screen: two tabs, one per mode. Each is a NavigationSplitView — the system's own two-pane
// container — so the panes are placed by iOS (around the fold, with its own column widths), and the
// app only says what goes on the left and what goes on the right.
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UIKit

struct HomeView: View {
    let viewer: Viewer
    @Binding var pageIndex: Int
    let onSettings: () -> Void

    @State private var receiverBrowser = ReceiverBrowser()
    @State private var targets: [SendTarget] = []
    @State private var chosen: SendTarget?
    @State private var configServer = ConfigServer()
    @State private var browseTask: Task<Void, Never>?
    @State private var sendStatus = ""
    /// Both panes stay visible; the divider is where a fold lands.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var deviceName: String { UIDevice.current.name }

    var body: some View {
        TabView(selection: $pageIndex) {
            receiveTab
                .tabItem { Label("Принимать", systemImage: "wifi") }
                .tag(0)

            sendTab
                .tabItem { Label("Отправлять", systemImage: "rectangle.dashed.badge.record") }
                .tag(1)
        }
        .tint(LuchStyle.accent)
        .task {
            configServer.onStatus = { line in sendStatus = line }
            configServer.start()
            browseTask = Task { @MainActor in
                for await list in receiverBrowser.updates() {
                    targets = list
                    if let chosen, !list.contains(where: { $0.id == chosen.id }) {
                        self.chosen = nil
                    }
                }
            }
            receiverBrowser.start()
        }
    }

    // MARK: - tabs

    private var receiveTab: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List {
                Section {
                    statusRow(
                        symbol: "wifi",
                        title: "Готов принимать",
                        subtitle: "Телефон виден в сети как «\(deviceName)»",
                        footnote: [LocalAddress.preferred(), "Wi-Fi", "порт 47800"]
                            .compactMap { $0 }.joined(separator: " · "))
                }
            }
            .navigationTitle("Luch")
            .toolbar { settingsItem }
        } detail: {
            List {
                Section("Отправители рядом") {
                    if viewer.senders.isEmpty {
                        ContentUnavailableView(
                            "Пока не найдены",
                            systemImage: "laptopcomputer",
                            description: Text("Откройте Luch на компьютере в этой же сети"))
                    } else {
                        ForEach(viewer.senders) { sender in
                            Label(sender.name, systemImage: "laptopcomputer")
                        }
                    }
                }
            }
            .navigationTitle("Отправители рядом")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationSplitViewStyle(.balanced)
        .scrollContentBackground(.hidden)
        .background(LuchStyle.background)
    }

    private var sendTab: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List {
                Section {
                    statusRow(
                        symbol: "rectangle.dashed.badge.record",
                        title: chosen == nil ? "Куда показывать" : "Показываем на",
                        subtitle: chosen?.name ?? "Выберите приёмник справа",
                        footnote: sendStatus.isEmpty ? nil : sendStatus,
                        footnoteTint: sendStatus.isEmpty ? nil : LuchStyle.accent)
                }

                if let chosen {
                    Section {
                        Button {
                            BroadcastStarter.present(target: chosen)
                        } label: {
                            Text("Начать трансляцию")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }
            }
            .navigationTitle("Luch")
            .toolbar { settingsItem }
        } detail: {
            List {
                Section("Приёмники рядом") {
                    if targets.isEmpty {
                        ContentUnavailableView(
                            "Пока не найдены",
                            systemImage: "display",
                            description: Text("Приёмник должен быть в этой же сети"))
                    } else {
                        ForEach(targets) { target in
                            Button {
                                chosen = target
                                prepare(target)
                            } label: {
                                HStack {
                                    Label(target.name, systemImage: "display")
                                        .foregroundStyle(LuchStyle.primaryText)
                                    Spacer(minLength: 0)
                                    if chosen?.id == target.id {
                                        Image(systemName: "checkmark")
                                            .fontWeight(.semibold)
                                            .foregroundStyle(LuchStyle.accent)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Приёмники рядом")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationSplitViewStyle(.balanced)
        .scrollContentBackground(.hidden)
        .background(LuchStyle.background)
    }

    // MARK: - pieces

    private var settingsItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: onSettings) {
                Image(systemName: "gearshape.fill")
                    .foregroundStyle(LuchStyle.primaryText)
            }
            .accessibilityLabel("Настройки")
        }
    }

    /// A status line: a symbol, the mode, what it means, and a small footnote.
    private func statusRow(
        symbol: String,
        title: String,
        subtitle: String,
        footnote: String?,
        footnoteTint: Color? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(LuchStyle.accent)
                .frame(width: 34, alignment: .center)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(LuchStyle.primaryText)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(LuchStyle.secondaryText)
                if let footnote {
                    Text(footnote)
                        .font(.caption)
                        .foregroundStyle(footnoteTint ?? LuchStyle.secondaryText)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    // MARK: - actions

    /// The system picker starts the broadcast itself, so the target is stored the moment it is
    /// chosen; there is no second step where the app could forget it.
    private func prepare(_ target: SendTarget) {
        SendConfig.store(target)
        configServer.target = target
    }
}

#if DEBUG
#Preview {
    HomeView(viewer: .previewReceivingSenders, pageIndex: .constant(0), onSettings: {})
        .preferredColorScheme(.dark)
}
#endif
