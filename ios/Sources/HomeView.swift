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
    /// Live hinge angle in degrees; nil when this device has no hinge or is flat open.
    @State private var hingeAngle: CGFloat?
    /// The active fold band, in the window's coordinates; nil when the device is flat.
    @State private var division: CGRect?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var deviceName: String { UIDevice.current.name }
    /// Wide: side by side. Narrow: the collection sits under the status.
    private var sideBySide: Bool { horizontalSizeClass == .regular }

    var body: some View {
        Group {
            if wideLayout {
                splitHome
            } else {
                tabsHome
            }
        }
        .tint(LuchStyle.accent)
        .background(LuchStyle.background)
        .readingHinge { angle in hingeAngle = angle }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { division = Self.foldBand(in: proxy) }
                    .onChange(of: proxy.size) { _, _ in division = Self.foldBand(in: proxy) }
            }
        }
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

    /// A phone switches modes with the tab bar; a tablet or a folded-open Duo keeps them in the
    /// split view's sidebar, where nothing floats over the navigation bar.
    private var wideLayout: Bool { horizontalSizeClass == .regular }

    private var tabsHome: some View {
        TabView(selection: $pageIndex) {
            NavigationStack {
                receiveScreen
                    .navigationTitle("Luch")
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar { settingsItem }
            }
            .tabItem { Label("Принимать", systemImage: "wifi") }
            .tag(0)

            NavigationStack {
                sendScreen
                    .navigationTitle("Luch")
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar { settingsItem }
            }
            .tabItem { Label("Отправлять", systemImage: "rectangle.dashed.badge.record") }
            .tag(1)
        }
    }

    private var splitHome: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List {
                modeRow(0, "Принимать", "wifi")
                modeRow(1, "Отправлять", "rectangle.dashed.badge.record")
            }
            .navigationTitle("Luch")
            .toolbar { settingsItem }
        } detail: {
            if pageIndex == 0 {
                receiveScreen
                    .navigationTitle("Отправители рядом")
                    .navigationBarTitleDisplayMode(.inline)
            } else {
                sendScreen
                    .navigationTitle("Приёмники рядом")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// A mode in the split view's sidebar: a row with a checkmark, the way a sidebar selection looks.
    private func modeRow(_ index: Int, _ title: String, _ symbol: String) -> some View {
        Button {
            pageIndex = index
        } label: {
            HStack {
                Label(title, systemImage: symbol)
                    .foregroundStyle(LuchStyle.primaryText)
                Spacer(minLength: 0)
                if pageIndex == index {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(LuchStyle.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var receiveScreen: some View {
        twoSides { receiveStatus } trailing: { sendersCollection }
    }

    private var sendScreen: some View {
        twoSides {
            VStack(alignment: .leading, spacing: 20) {
                sendStatusRow
                startSection
            }
        } trailing: {
            targetsCollection
        }
    }

    /// The band of an active fold, or nil when the device is flat.
    private static func foldBand(in proxy: GeometryProxy) -> CGRect? {
        guard #available(iOS 27.1, *) else { return nil }
        let regions = proxy.reservedRegions(
            kind: .division, options: [.includeInactive], layoutDirectionBehavior: .fixed)
        guard let active = regions.first(where: { $0.isActive }), active.frame.width > 4 else {
            return nil
        }
        return active.frame
    }

    /// When the device is half folded, the two blocks sit on either side of the crease with the
    /// fold's own width as the gutter; flat, they stack in one column.
    @ViewBuilder
    private func twoSides<Leading: View, Trailing: View>(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        if let division {
            ScrollView {
                HStack(alignment: .top, spacing: 0) {
                    leading()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 12)
                    Color.clear.frame(width: division.width + 24)
                    trailing()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 12)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
            }
            .background(LuchStyle.background)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    leading()
                    trailing()
                }
                .padding(20)
            }
            .background(LuchStyle.background)
        }
    }

    // MARK: - status

    private var receiveStatus: some View {
        statusCard(
            symbol: "wifi",
            title: "Готов принимать",
            subtitle: "Телефон виден в сети как «\(deviceName)»",
            footnote: nil,
            chips: receiveChips)
    }

    private var sendStatusRow: some View {
        statusCard(
            symbol: "rectangle.dashed.badge.record",
            title: chosen == nil ? "Куда показывать" : "Показываем на",
            subtitle: chosen?.name ?? "Выберите приёмник ниже",
            footnote: sendStatus.isEmpty ? nil : sendStatus,
            footnoteTint: sendStatus.isEmpty ? nil : LuchStyle.accent,
            chips: sendChips)
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
        footnoteTint: Color? = nil,
        chips: [Chip] = []
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
                if !chips.isEmpty {
                    // Chips wrap instead of being cut off by the pane's edge, each at its own width.
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(chips) { chip($0) }
                    }
                    .padding(.top, 4)
                }
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
        Group {
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
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var targetsCollection: some View {
        Group {
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
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: - chips

    /// What we can play, from the same list the receiver advertises.
    /// The chosen codec first, then the rest of what the hardware has.
    private var advertisedVideo: [String] {
        let all = DeviceCapabilities.videoDecoders
        guard let preferred = CodecSettings.video.codec, all.contains(preferred) else { return all }
        return [preferred] + all.filter { $0 != preferred }
    }

    private var receiveChips: [Chip] {
        var chips = [
            Chip(LocalAddress.preferred() ?? "без адреса", "wifi"),
            Chip("47800", "number"),
        ]
        for label in DeviceCapabilities.labels(for: advertisedVideo) {
            chips.append(Chip(label, label == "HEVC" ? "video" : "film"))
        }
        for label in DeviceCapabilities.labels(for: CodecSettings.audio.codecs) {
            chips.append(Chip(label, "waveform"))
        }
        if let hingeAngle, hingeAngle < 175 {
            chips.append(Chip("\(Int(hingeAngle.rounded()))°", "book.closed"))
        }
        return chips
    }

    /// What we can send. The receiver's own answer arrives with its welcome, and the extension
    /// picks the codec from it, so these are our side of the bargain.
    private var sendChips: [Chip] {
        var chips: [Chip] = []
        if let chosen {
            chips.append(Chip(chosen.host, "wifi"))
            chips.append(Chip("\(chosen.port)", "number"))
        } else {
            chips.append(Chip("47800", "number"))
        }
        for label in DeviceCapabilities.labels(for: DeviceCapabilities.videoEncoders) {
            chips.append(Chip(label, label == "HEVC" ? "video" : "film"))
        }
        for label in DeviceCapabilities.labels(for: CodecSettings.audio.codecs) {
            chips.append(Chip(label, "waveform"))
        }
        return chips
    }

    // MARK: - pieces

    /// The mark leads the sidebar: the toolbar's leading and principal slots do not draw it in this
    /// configuration, and a sign of the app belongs next to its name anyway.
    private var brandRow: some View {
        HStack(spacing: 10) {
            Image("LuchMark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(LuchStyle.accent)
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
            Text("Luch")
                .font(.title3.weight(.semibold))
                .foregroundStyle(LuchStyle.accent)
            Spacer(minLength: 0)
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
    }

    private var settingsItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: onSettings) {
                Image(systemName: "gearshape.fill")
                    .foregroundStyle(LuchStyle.primaryText)
            }
            .accessibilityLabel("Настройки")
        }
    }

    /// A fact that reads as a tag: address, port, codec, audio.
    struct Chip: Identifiable {
        let text: String
        let symbol: String?
        var id: String { text }

        init(_ text: String, _ symbol: String? = nil) {
            self.text = text
            self.symbol = symbol
        }
    }

    private func chip(_ chip: Chip) -> some View {
        HStack(spacing: 5) {
            if let symbol = chip.symbol {
                Image(systemName: symbol)
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
            }
            Text(chip.text)
                .font(.caption)
        }
        .foregroundStyle(LuchStyle.secondaryText)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(LuchStyle.background, in: Capsule())
        .overlay { Capsule().strokeBorder(LuchStyle.separator, lineWidth: 1) }
        .fixedSize()
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
