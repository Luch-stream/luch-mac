// Xcode previews for the screens that matter: both halves of the home card, the live picture, the
// settings sheet and the end states. Everything here is DEBUG-only.
// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import SwiftUI

#Preview("Трансляция") {
    StreamView(viewer: .previewStreaming, settingsPresented: .constant(false))
        .preferredColorScheme(.dark)
}

#Preview("Настройки") {
    SettingsView()
        .preferredColorScheme(.dark)
}

#Preview("Завершено") {
    EndedView(
        symbol: "checkmark.circle.fill",
        tint: .white,
        title: "Трансляция завершена",
        message: "Ожидание отправителя",
        actionTitle: "Искать снова",
        action: {},
        onSettings: {})
        .preferredColorScheme(.dark)
}

extension Viewer {
    static var previewReceivingSenders: Viewer {
        let viewer = Viewer()
        viewer.seedPreviewSenders(["MacBook Pro — iQQator", "S24+ пользователя Павел"])
        return viewer
    }

    static var previewStreaming: Viewer {
        let viewer = Viewer()
        viewer.seedPreviewStreaming(sender: "MacBook Pro — iQQator")
        return viewer
    }
}
#endif
