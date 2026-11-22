// Luch для iPhone и iPad: принимает поток от отправителя в локальной сети.
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

@main
struct LuchApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .persistentSystemOverlays(.hidden)
                .statusBarHidden()
        }
    }
}
