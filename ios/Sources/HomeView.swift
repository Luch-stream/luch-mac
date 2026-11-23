// The home screen: one header, one card that pages between receiving and sending, dots under it,
// and a container underneath that is rebuilt for whichever half is showing. The card keeps a fixed
// height so nothing jumps when the page changes.
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UIKit

private struct CardHeightKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

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

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var sending: Bool { pageIndex == 1 }
    private var deviceName: String { UIDevice.current.name }
    /// The Android client switches to two columns at 840 dp; we use the same number.
    @State private var width: CGFloat = 0
    /// Where the fold is, when the device is partially folded: nothing interactive may sit there.
    @State private var foldMid: CGFloat?
    private var wide: Bool { width >= 840 }

    /// Both cards are this tall, so the dots and the container below never move.
    /// Measured, not guessed: the pager is as tall as the taller of the two cards, so neither
    /// leaves a gap nor spills over the list underneath.
    @State private var receiveHeight: CGFloat = 0
    @State private var sendHeight: CGFloat = 0
    private var cardHeight: CGFloat { max(260, receiveHeight, sendHeight) }

    var body: some View {
        TabView(selection: $pageIndex) {
            NavigationStack {
                receiveScreen
                    .navigationTitle("Luch")
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar { settingsItem }
                    .toolbarBackground(LuchStyle.background, for: .navigationBar)
                    .toolbarBackground(.visible, for: .navigationBar)
            }
            .tabItem {
                Label("Принимать", systemImage: "wifi")
            }
            .tag(0)

            NavigationStack {
                sendScreen
                    .navigationTitle("Luch")
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar { settingsItem }
                    .toolbarBackground(LuchStyle.background, for: .navigationBar)
                    .toolbarBackground(.visible, for: .navigationBar)
            }
            .tabItem {
                Label("Отправлять", systemImage: "rectangle.dashed.badge.record")
            }
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

    // MARK: - header

    /// The middle of an active fold, or nil when the device is flat.
    private static func foldCentre(in proxy: GeometryProxy) -> CGFloat? {
        guard #available(iOS 27.1, *) else { return nil }
        let regions = proxy.reservedRegions(
            kind: .division, options: [.includeInactive], layoutDirectionBehavior: .fixed)
        guard let active = regions.first(where: { $0.isActive }) else { return nil }
        return active.frame.midX
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

    private var receiveScreen: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                if wide {
                    HStack(alignment: .top, spacing: 18) {
                        receiveCard.frame(width: 420)
                        sendersSection.frame(maxWidth: .infinity)
                    }
                } else {
                    receiveCard
                    sendersSection
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
            .frame(maxWidth: wide ? 920 : 520)
            .frame(maxWidth: .infinity)
        }
        .background(LuchStyle.background.ignoresSafeArea())
        .overlay { widthReader }
    }

    private var sendScreen: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                if wide {
                    HStack(alignment: .top, spacing: 18) {
                        sendCard.frame(width: 420)
                        targetsSection.frame(maxWidth: .infinity)
                    }
                } else {
                    sendCard
                    targetsSection
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
            .frame(maxWidth: wide ? 920 : 520)
            .frame(maxWidth: .infinity)
        }
        .background(LuchStyle.background.ignoresSafeArea())
        .overlay { widthReader }
    }

    private var widthReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear {
                    width = proxy.size.width
                    foldMid = Self.foldCentre(in: proxy)
                }
                .onChange(of: proxy.size.width) { _, new in
                    width = new
                    foldMid = Self.foldCentre(in: proxy)
                }
        }
    }

    private var sendersSection: some View {
        list(
            viewer.senders.map { ($0.id, $0.name, "") },
            empty: "Пока не найдены",
            selected: nil,
            icon: "laptopcomputer",
            onTap: { _ in })
    }

    private var targetsSection: some View {
        list(
            targets.map { ($0.id, $0.name, $0.model) },
            empty: "Пока не найдены",
            selected: chosen?.id,
            icon: "display",
            onTap: { id in
                chosen = targets.first { $0.id == id }
                if let chosen { prepare(chosen) }
            })
    }

    private var cardColumn: some View {
        Group {
            if pageIndex == 0 {
                receiveCard
            } else {
                sendCard
            }
        }
        .frame(height: cardHeight, alignment: .top)
    }

    private var foldWidth: CGFloat {
        if let foldMid { return max(180, foldMid - 28) }
        return wide ? 320 : .infinity
    }


    private var header: some View {
        HStack(spacing: 12) {
            Image("LuchMark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(LuchStyle.accent)
                .frame(width: 26, height: 26)
                .frame(width: 52, height: 52)
                .background(LuchStyle.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            Text("Luch")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(LuchStyle.accent)

            Spacer(minLength: 0)

            if wide {
                Text(deviceName)
                    .font(.footnote)
                    .foregroundStyle(LuchStyle.secondaryText)
                    .lineLimit(1)
            }

            Button(action: onSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(LuchStyle.primaryText)
                    .frame(width: 46, height: 46)
                    .background(LuchStyle.surface, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Настройки")
        }
    }

    // MARK: - cards

    private var receiveCard: some View {
        VStack(spacing: 10) {
            cardIcon("wifi")
            Text("Готов принимать")
                .font(.title.weight(.bold))
                .foregroundStyle(LuchStyle.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text("Телефон виден в сети как")
                .font(.subheadline)
                .foregroundStyle(LuchStyle.secondaryText)
            Text(deviceName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(LuchStyle.primaryText)
                .lineLimit(1)
            HStack(spacing: 8) {
                chip(LocalAddress.preferred() ?? "без адреса")
                chip("Wi-Fi · порт 47800")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        // Without this the card would shrink to its text and sit in the middle of the page.
        .frame(maxWidth: .infinity)
        .background(LuchStyle.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: CardHeightKey.self, value: [0: proxy.size.height])
            }
        }
    }

    private var sendCard: some View {
        VStack(spacing: 10) {
            cardIcon("rectangle.dashed.badge.record")
            Text("Куда показывать")
                .font(.title.weight(.bold))
                .foregroundStyle(LuchStyle.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(chosen?.name ?? "Выберите приёмник ниже")
                .font(chosen == nil ? .subheadline : .title3.weight(.semibold))
                .foregroundStyle(chosen == nil ? LuchStyle.secondaryText : LuchStyle.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if let chosen {
                Button {
                    BroadcastStarter.present(target: chosen)
                } label: {
                    Text("Начать трансляцию")
                        .font(LuchType.button)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 11)
                        .background(LuchStyle.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .frame(height: 44)
            } else {
                Color.clear.frame(height: 44)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        // Without this the card would shrink to its text and sit in the middle of the page.
        .frame(maxWidth: .infinity)
        .background(LuchStyle.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: CardHeightKey.self, value: [1: proxy.size.height])
            }
        }
    }

    private func cardIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(LuchStyle.accent)
            .frame(width: 64, height: 64)
            .background(LuchStyle.accent.opacity(0.14), in: Circle())
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.footnote.monospacedDigit())
            .foregroundStyle(LuchStyle.primaryText)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .overlay { Capsule().strokeBorder(LuchStyle.separator, lineWidth: 1) }
    }

    // MARK: - the container under the card

    @ViewBuilder
    private var bottomContainer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(sending ? "ПРИЁМНИКИ РЯДОМ" : "ОТПРАВИТЕЛИ РЯДОМ")
                .font(LuchType.caption)
                .tracking(1.1)
                .foregroundStyle(LuchStyle.secondaryText)
                .padding(.leading, 6)

            if sending, !sendStatus.isEmpty {
                Text(sendStatus)
                    .font(.caption)
                    .foregroundStyle(LuchStyle.accent)
                    .lineLimit(2)
                    .padding(.leading, 6)
            }

            if sending {
                list(
                    targets.map { ($0.id, $0.name, $0.model) },
                    empty: "Пока не найдены",
                    selected: chosen?.id,
                    icon: "display",
                    onTap: { id in
                        chosen = targets.first { $0.id == id }
                        if let chosen { prepare(chosen) }
                    })
            } else {
                list(
                    viewer.senders.map { ($0.id, $0.name, "") },
                    empty: "Пока не найдены",
                    selected: nil,
                    icon: "laptopcomputer",
                    onTap: { _ in })
            }
        }
    }

    private func list(
        _ rows: [(String, String, String)], empty: String, selected: String?, icon: String,
        onTap: @escaping (String) -> Void
    ) -> some View {
        Group {
            if rows.isEmpty {
                Text(empty)
                    .font(.callout)
                    .foregroundStyle(LuchStyle.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 18)
                    .background(LuchStyle.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(rows, id: \.0) { row in
                        Button {
                            onTap(row.0)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: icon)
                                    .font(.system(size: 18))
                                    .foregroundStyle(LuchStyle.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.1)
                                        .font(.callout.weight(.medium))
                                        .foregroundStyle(LuchStyle.primaryText)
                                        .lineLimit(1)
                                    if !row.2.isEmpty {
                                        Text(row.2)
                                            .font(.caption)
                                            .foregroundStyle(LuchStyle.secondaryText)
                                    }
                                }
                                Spacer(minLength: 0)
                                if selected == row.0 {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(LuchStyle.accent)
                                }
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 14)
                            // The whole row is the tap target, not just the label and the icon.
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        if row.0 != rows.last?.0 {
                            Rectangle()
                                .fill(LuchStyle.separator)
                                .frame(height: 0.5)
                                .padding(.leading, 48)
                        }
                    }
                }
                .background(LuchStyle.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
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
