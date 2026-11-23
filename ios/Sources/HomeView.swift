// The home screen: two tabs, one per mode, each a plain List — status on top, the room around the
// device below. No cards, no measured heights, no fold arithmetic: List and TabView already handle
// safe areas, the fold, Dynamic Type and selection.
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

    private var deviceName: String { UIDevice.current.name }

    var body: some View {
        TabView(selection: $pageIndex) {
            NavigationStack {
                receiveList
                    .navigationTitle("Luch")
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar { settingsItem }
            }
            .tabItem { Label("Принимать", systemImage: "wifi") }
            .tag(0)

            NavigationStack {
                sendList
                    .navigationTitle("Luch")
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar { settingsItem }
            }
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

    private var receiveList: some View {
        List {
            Section {
                statusRow(
                    symbol: "wifi",
                    title: "Готов принимать",
                    subtitle: "Телефон виден в сети как «\(deviceName)»",
                    footnote: [LocalAddress.preferred(), "Wi-Fi", "порт 47800"]
                        .compactMap { $0 }.joined(separator: " · "))
            }

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
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(LuchStyle.background)
    }

    private var sendList: some View {
        List {
            Section {
                statusRow(
                    symbol: "rectangle.dashed.badge.record",
                    title: chosen == nil ? "Куда показывать" : "Показываем на",
                    subtitle: chosen?.name ?? "Выберите приёмник ниже",
                    footnote: sendStatus.isEmpty ? nil : sendStatus,
                    footnoteTint: sendStatus.isEmpty ? nil : LuchStyle.accent)
            }

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
                                        .foregroundStyle(LuchStyle.accent)
                                        .fontWeight(.semibold)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
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
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.insetGrouped)
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
