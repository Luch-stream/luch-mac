// Minimal settings: which device this is and what it runs. Nothing here changes the protocol.
// The sheet follows the same dark palette as every other screen.
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                LuchStyle.background.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 16) {
                    infoCard
                    hintCard
                    Spacer(minLength: 0)
                    HStack {
                        Spacer()
                        PrimaryActionButton(title: "Готово", systemImage: "checkmark") {
                            dismiss()
                        }
                        Spacer()
                    }
                }
                .padding(20)
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(LuchStyle.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .presentationBackground(LuchStyle.background)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }

    private var infoCard: some View {
        VStack(spacing: 0) {
            row("Устройство", value: UIDevice.current.name)
            Rectangle()
                .fill(LuchStyle.separator)
                .frame(height: 0.5)
            row("Версия", value: version)
        }
        .padding(.horizontal, 16)
        .glassSurface(cornerRadius: 20)
    }

    private var hintCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Как начать")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(LuchStyle.secondaryText)
            Text(
                "Откройте Luch на компьютере и выберите это устройство — картинка появится здесь. "
                    + "Компьютер и приёмник должны быть в одной сети."
            )
            .font(.footnote)
            .foregroundStyle(LuchStyle.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 20)
    }

    private func row(_ title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundStyle(LuchStyle.primaryText)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(LuchStyle.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.8)
        }
        .font(.subheadline)
        .padding(.vertical, 14)
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.1"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}
