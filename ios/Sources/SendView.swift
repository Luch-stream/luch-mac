// The "Send" half of the app: pick a receiver on the network and broadcast this screen to it.
// The broadcast itself runs in the ReplayKit extension; this screen only chooses the target and
// says what is happening.
// SPDX-License-Identifier: GPL-3.0-or-later
import ReplayKit
import SwiftUI

struct SendView: View {
    @Binding var pageIndex: Int
    let onSettings: () -> Void
    @State private var configServer = ConfigServer()
    @State private var browser = ReceiverBrowser()
    @State private var browseTask: Task<Void, Never>?

    @State private var targets: [SendTarget] = []
    @State private var choosing = false
    @State private var chosen: SendTarget?
    @State private var pickerShown = false

    var body: some View {
        ZStack {
            LuchStyle.background.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    header
                    statusCard
                    PageDots(index: $pageIndex, count: 2)
                        .padding(.top, -4)
                    targetsBlock
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 28)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
        }
        .task {
            configServer.start()
            browseTask = Task { @MainActor in
                for await list in browser.updates() {
                    targets = list
                }
            }
            browser.start()
        }
    }

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
            Image(systemName: "rectangle.dashed.badge.record")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(LuchStyle.accent)
                .frame(width: 84, height: 84)
                .background(LuchStyle.accent.opacity(0.14), in: Circle())

            Text(chosen == nil ? "Куда показывать" : "Показываем на \(chosen!.name)")
                .font(.title3.weight(.bold))
                .foregroundStyle(LuchStyle.primaryText)
                .multilineTextAlignment(.center)

            Text("Выберите приёмник, затем начните трансляцию")
                .font(.subheadline)
                .foregroundStyle(LuchStyle.secondaryText)
                .multilineTextAlignment(.center)

            if let chosen {
                Button {
                    startBroadcast(to: chosen)
                } label: {
                    Text("Начать трансляцию")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .background(LuchStyle.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity)
        .background(LuchStyle.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var targetsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ПРИЁМНИКИ РЯДОМ")
                .font(.caption.weight(.semibold))
                .tracking(1.1)
                .foregroundStyle(LuchStyle.secondaryText)
                .padding(.leading, 6)

            if targets.isEmpty {
                Text("Пока не найдены")
                    .font(.callout)
                    .foregroundStyle(LuchStyle.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 18)
                    .background(LuchStyle.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(targets) { target in
                        Button {
                            chosen = target
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "display")
                                    .font(.system(size: 18))
                                    .foregroundStyle(LuchStyle.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(target.name)
                                        .font(.callout.weight(.medium))
                                        .foregroundStyle(LuchStyle.primaryText)
                                    Text(target.model)
                                        .font(.caption)
                                        .foregroundStyle(LuchStyle.secondaryText)
                                }
                                Spacer(minLength: 0)
                                if chosen == target {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(LuchStyle.accent)
                                }
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 14)
                        }
                        .buttonStyle(.plain)
                        if target.id != targets.last?.id {
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
        .sheet(isPresented: $choosing) { EmptyView() }
    }

    /// ReplayKit asks the user to confirm the broadcast; the extension asks the app where to send.
    private func startBroadcast(to target: SendTarget) {
        SendConfig.store(target)
        configServer.target = target
        pickerShown = true
    }
}

/// What the app and the broadcast extension agree on through the App Group.
enum SendConfig {
    static let suite = "group.dev.luch.ios"
    private static let hostKey = "send.host"
    private static let portKey = "send.port"
    private static let nameKey = "send.name"

    static func store(_ target: SendTarget) {
        let defaults = UserDefaults(suiteName: suite)
        defaults?.set(target.host, forKey: hostKey)
        defaults?.set(Int(target.port), forKey: portKey)
        defaults?.set(target.name, forKey: nameKey)
    }

    static func load() -> SendTarget? {
        guard let defaults = UserDefaults(suiteName: suite),
            let host = defaults.string(forKey: hostKey),
            let name = defaults.string(forKey: nameKey)
        else { return nil }
        let port = UInt16(defaults.integer(forKey: portKey))
        guard port > 0 else { return nil }
        return SendTarget(id: host, name: name, host: host, port: port, model: "receiver")
    }
}
