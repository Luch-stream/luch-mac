// What the app tells the broadcast extension before it starts: which receiver to stream to.
// A loopback socket carries it at start time; the defaults are a fallback for a cold extension.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

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
