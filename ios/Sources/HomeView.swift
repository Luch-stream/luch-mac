// The home screen: two tabs, one per mode. Wide screens put the status beside the collection in a
// NavigationSplitView; a narrow (vertical) screen stacks them — status first, collection below.
// Both layouts are made of standard parts: List rows for the status, an adaptive grid for devices.
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
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var deviceName: String { UIDevice.current.name }
    /// Wide: side by side. Narrow: the collection sits under the status.
    private var sideBySide: Bool { horizontalSizeClass == .regular }

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
        Group {
            if sideBySide {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    List { receiveStatus }
                        .navigationTitle("Luch")
                        .toolbar { settingsItem }
                } detail: {
                    sendersCollection
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            receiveStatus
                                .padding(.horizontal, 20)
                            sendersCollection
                        }
                        .padding(.vertical, 12)
                    }
                    .background(LuchStyle.background)
                    .navigationTitle("Luch")
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar { settingsItem }
                }
            }
        }
        .background(LuchStyle.background)
    }

    private var sendTab: some View {
        Group {
            if sideBySide {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    List {
                        sendStatusRow
                        startSection
                    }
                    .navigationTitle("Luch")
                    .toolbar { settingsItem }
                } detail: {
                    targetsCollection
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            sendStatusRow
                                .padding(.horizontal, 20)
                            startSection
                                .padding(.horizontal, 20)
                            targetsCollection
                        }
                        .padding(.vertical, 12)
                    }
                    .background(LuchStyle.background)
                    .navigationTitle("Luch")
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar { settingsItem }
                }
            }
        }
        .background(LuchStyle.background)
    }

    // MARK: - status

    private var receiveStatus: some View {
        statusCard(
            symbol: "wifi",
            title: "Готов принимать",
            subtitle: "Телефон виден в сети как «\(deviceName)»",
            footnote: [LocalAddress.preferred(), "Wi-Fi", "порт 47800"]
                .compactMap { $0 }.joined(separator: " · "))
    }

    private var sendStatusRow: some View {
        statusCard(
            symbol: "rectangle.dashed.badge.record",
            title: chosen == nil ? "Куда показывать" : "Показываем на",
            subtitle: chosen?.name ?? "Выберите приёмник ниже",
            footnote: sendStatus.isEmpty ? nil : sendStatus,
            footnoteTint: sendStatus.isEmpty ? nil : LuchStyle.accent)
    }

    @ViewBuilder
    private var startSection: some View {
        if let chosen {
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

    private func statusCard(
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    // MARK: - collections

    private var sendersCollection: some View {
        ScrollView {
            if viewer.senders.isEmpty {
                emptyState(
                    title: "Пока не найдены",
                    symbol: "laptopcomputer",
                    message: "Откройте Luch на компьютере в этой же сети")
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(viewer.senders) { sender in
                        deviceCard(
                            symbol: "laptopcomputer",
                            title: sender.name,
                            subtitle: "Luch",
                            selected: false)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .background(LuchStyle.background)
        .navigationTitle("Отправители рядом")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var targetsCollection: some View {
        ScrollView {
            if targets.isEmpty {
                emptyState(
                    title: "Пока не найдены",
                    symbol: "display",
                    message: "Приёмник должен быть в этой же сети")
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(targets) { target in
                        Button {
                            chosen = target
                            prepare(target)
                        } label: {
                            deviceCard(
                                symbol: "display",
                                title: target.name,
                                subtitle: "Luch",
                                selected: chosen?.id == target.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .background(LuchStyle.background)
        .navigationTitle("Приёмники рядом")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Adaptive columns: the grid decides how many cards fit, as HIG asks for a collection.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 220), spacing: 12)]
    }

    private func emptyState(title: String, symbol: String, message: String) -> some View {
        ContentUnavailableView(
            title, systemImage: symbol, description: Text(message))
            .padding(.top, 60)
    }

    private func deviceCard(
        symbol: String, title: String, subtitle: String, selected: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(LuchStyle.accent)
            Text(title)
                .font(.headline)
                .foregroundStyle(LuchStyle.primaryText)
                .lineLimit(1)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(LuchStyle.secondaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(LuchStyle.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    selected ? LuchStyle.accent : LuchStyle.separator,
                    lineWidth: selected ? 2 : 1)
        }
        .contentShape(Rectangle())
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
