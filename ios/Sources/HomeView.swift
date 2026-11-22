// The home screen: one header, one card that pages between receiving and sending, dots under it,
// and a container underneath that is rebuilt for whichever half is showing. The card keeps a fixed
// height so nothing jumps when the page changes.
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

    private var sending: Bool { pageIndex == 1 }
    private var deviceName: String { UIDevice.current.name }

    /// Both cards are this tall, so the dots and the container below never move.
    private let cardHeight: CGFloat = 322

    var body: some View {
        ZStack {
            LuchStyle.background.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    header
                        .padding(.horizontal, 20)

                    // Full-bleed pager: the card keeps its margins inside, but a swipe that starts
                    // at the screen edge still lands on the page instead of the parent scroller.
                    TabView(selection: $pageIndex) {
                        receiveCard.tag(0)
                        sendCard.tag(1)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(height: cardHeight)

                    PageDots(index: $pageIndex, count: 2)

                    bottomContainer
                        .padding(.horizontal, 20)
                }
                .padding(.top, 6)
                .padding(.bottom, 28)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
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

    // MARK: - header

    private var header: some View {
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

            Spacer(minLength: 0)

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
        VStack(spacing: 12) {
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
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LuchStyle.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, 20)
    }

    private var sendCard: some View {
        VStack(spacing: 12) {
            cardIcon("rectangle.dashed.badge.record")
            Text("Куда показывать")
                .font(.title.weight(.bold))
                .foregroundStyle(LuchStyle.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(chosen == nil ? "Выберите приёмник ниже" : "Показываем на")
                .font(.subheadline)
                .foregroundStyle(LuchStyle.secondaryText)
            Text(chosen?.name ?? "—")
                .font(.title3.weight(.semibold))
                .foregroundStyle(LuchStyle.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if !sendStatus.isEmpty {
                Text(sendStatus)
                    .font(.caption)
                    .foregroundStyle(LuchStyle.accent)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

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
                .frame(height: 52)
            } else {
                Color.clear.frame(height: 52)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LuchStyle.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, 20)
    }

    private func cardIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(LuchStyle.accent)
            .frame(width: 84, height: 84)
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
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: sending)
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
