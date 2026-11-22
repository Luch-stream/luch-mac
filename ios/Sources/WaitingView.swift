// The idle screen: Luch is discoverable and waits for a computer to start a session.
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UIKit

struct WaitingView: View {
    let deviceName: String
    var senders: [SenderBrowser.Sender] = []
    @Binding var pageIndex: Int
    let onSettings: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var occlusionTop: CGFloat = 0

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var deviceWord: String { isPad ? "этот iPad" : "этот iPhone" }
    private var deviceSymbol: String { isPad ? "ipad" : "iphone" }

    var body: some View {
        ZStack {
            LuchStyle.background.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    header
                    statusCard
                    PageDots(index: $pageIndex, count: 2)
                        .padding(.top, -4)
                    sendersBlock
                    HintCard(deviceWord: deviceWord, deviceSymbol: deviceSymbol)
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 28)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .safeAreaPadding(.top, occlusionTop)
        }
        .onAppear {
            guard !appeared else { return }
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.spring(duration: 0.55, bounce: 0.12)) {
                    appeared = true
                }
            }
        }
    }

    // MARK: - pieces

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

    private var statusCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(LuchStyle.accent)
                .frame(width: 84, height: 84)
                .background(LuchStyle.accent.opacity(0.14), in: Circle())

            Text("Готов принимать")
                .font(.title.weight(.bold))
                .foregroundStyle(LuchStyle.primaryText)
                .multilineTextAlignment(.center)

            Text(isPad ? "iPad виден в сети как" : "Телефон виден в сети как")
                .font(.subheadline)
                .foregroundStyle(LuchStyle.secondaryText)

            Text(deviceName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(LuchStyle.primaryText)
                .multilineTextAlignment(.center)

            HStack(spacing: 8) {
                chip(localAddress() ?? "без адреса")
                chip("Wi-Fi · порт 47800")
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity)
        .background(LuchStyle.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var sendersBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ОТПРАВИТЕЛИ РЯДОМ")
                .font(.caption.weight(.semibold))
                .tracking(1.1)
                .foregroundStyle(LuchStyle.secondaryText)
                .padding(.leading, 6)

            if senders.isEmpty {
                HStack(spacing: 10) {
                    PulseDot(diameter: 8)
                    Text("Пока не найдены")
                        .font(.callout)
                        .foregroundStyle(LuchStyle.secondaryText)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
                .background(LuchStyle.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(senders) { sender in
                        HStack(spacing: 12) {
                            Image(systemName: "laptopcomputer")
                                .font(.system(size: 18, weight: .regular))
                                .foregroundStyle(LuchStyle.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sender.name)
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(LuchStyle.primaryText)

                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        if sender.id != senders.last?.id {
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

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.footnote.monospacedDigit())
            .foregroundStyle(LuchStyle.primaryText)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .overlay {
                Capsule().strokeBorder(LuchStyle.separator, lineWidth: 1)
            }
    }

    /// The address a sender would connect to, so the screen can be matched with the computer.
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
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
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

/// The app mark: the vector traced from the Android client's `ic_luch.xml`, white on dark glass.
struct LogoMark: View {
    var diameter: CGFloat

    var body: some View {
        Image("LuchMark")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(LuchStyle.primaryText)
            .frame(width: diameter * 0.5, height: diameter * 0.5)
            .frame(width: diameter, height: diameter)
            .glassSurface(cornerRadius: diameter * 0.26, tint: LuchStyle.panel)
            .accessibilityHidden(true)
    }
}

struct SearchStatus: View {
    var body: some View {
        HStack(spacing: 9) {
            PulseDot(diameter: 8)
            Text("Ищу отправителя…")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(LuchStyle.primaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .glassSurface(cornerRadius: 22)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Поиск отправителя")
    }
}

struct HintCard: View {
    let deviceWord: String
    let deviceSymbol: String

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image("LuchMark")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.semibold))
                Image(systemName: deviceSymbol)
                    .font(.system(size: 22, weight: .regular))
            }
            .foregroundStyle(LuchStyle.secondaryText)

            Text("Откройте Luch на компьютере и выберите \(deviceWord)")
                .font(.callout)
                .foregroundStyle(LuchStyle.primaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(maxWidth: 360)
        .glassSurface(cornerRadius: 26)
        .accessibilityElement(children: .combine)
    }
}
