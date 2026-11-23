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
        ZStack {
            LuchStyle.background.ignoresSafeArea()

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

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    header

                    modeSwitcher
                        .frame(maxWidth: foldWidth)

                    if wide {
                        HStack(alignment: .top, spacing: 18) {
                            cardColumn
                                .frame(width: 420)
                            bottomContainer
                                .frame(maxWidth: .infinity)
                        }
                        .padding(.horizontal, 20)
                    } else {
                        Group {
                            if pageIndex == 0 {
                                receiveCard
                            } else {
                                sendCard
                            }
                        }
                        .frame(height: cardHeight, alignment: .top)

                        bottomContainer
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 0)
                .padding(.bottom, 28)
                .frame(maxWidth: wide ? 920 : 520)
                .frame(maxWidth: .infinity)
            }
        }
        .onPreferenceChange(CardHeightKey.self) { heights in
            if let height = heights[0] { receiveHeight = height }
            if let height = heights[1] { sendHeight = height }
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

    // MARK: - header

    /// The middle of an active fold, or nil when the device is flat.
    private static func foldCentre(in proxy: GeometryProxy) -> CGFloat? {
        guard #available(iOS 27.1, *) else { return nil }
        let regions = proxy.reservedRegions(
            kind: .division, options: [.includeInactive], layoutDirectionBehavior: .fixed)
        guard let active = regions.first(where: { $0.isActive }) else { return nil }
        return active.frame.midX
    }

    private var modeSwitcher: some View {
        Picker("Режим", selection: $pageIndex) {
            Text("Принимать").tag(0)
            Text("Отправлять").tag(1)
        }
        .pickerStyle(.segmented)
        .controlSize(.large)
        // Phone: the full safe-area width. Wide: a comfortable fixed width, centred. Folded: only
        // as wide as the leading half, so the segments never sit in the crease.
        .frame(maxWidth: foldWidth)
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

    private var headerOld: some View {
        HStack(spacing: 12) {
            Image("LuchMark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(LuchStyle.accent)
                .frame(width: 24, height: 24)
                .frame(width: 46, height: 46)
                .background(LuchStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text("Luch")
                .font(.title2.weight(.semibold))
                .foregroundStyle(LuchStyle.accent)

            if wide {
                Spacer(minLength: 0)
                modeSwitcher
                Spacer(minLength: 0)
                Text(deviceName)
                    .font(.footnote)
                    .foregroundStyle(LuchStyle.secondaryText)
                    .lineLimit(1)
                    .frame(maxWidth: 200, alignment: .trailing)
            } else {
                Spacer(minLength: 0)
            }

            Button(action: onSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 17, weight: .semibold))
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
                chip(localAddress() ?? "без адреса")
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
                        .font(.callout.weight(.semibold))
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
                .font(.caption.weight(.semibold))
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

    private func localAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var found: String?
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = cur {
            let flags = Int32(pointer.pointee.ifa_flags)
            if let addr = pointer.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                flags & Int32(IFF_UP) != 0, flags & Int32(IFF_LOOPBACK) == 0
            {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
                    NI_NUMERICHOST) == 0
                {
                    let text = String(cString: host)
                    if text.hasPrefix("169.254.") { cur = pointer.pointee.ifa_next; continue }
                    found = text
                    if text.hasPrefix("192.168.") || text.hasPrefix("10.") { break }
                }
            }
            cur = pointer.pointee.ifa_next
        }
        return found
    }
}
