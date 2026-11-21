// Typed view of the receiver's `welcome`: what it can decode, how fast, and at which size.
// Selection is always the intersection of what the client reports and what this Mac can encode —
// there is no M4-specific hardcoding.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import LuchMedia
import LuchProto

public struct VideoCapability {
    public var mime: String
    public var decoder: String
    public var maxWidth: Int
    public var maxHeight: Int
    public var fullHD60: Bool
    public var uhd60: Bool
    public var tenBit: Bool
    public var lowLatency: Bool
    public var benchMs: Double?
}

public struct ReceiverCaps {
    public var name: String
    public var model: String
    public var maxSize: String
    public var modes: [String]
    public var decoders: [String]
    public var audio: [String]
    public var video: [String: VideoCapability]
    public var benchRes: String?
    public var prefer: String?
    /// tv, phone or tablet; plus the mode it would render into right now.
    public var deviceType: String
    public var renderWidth: Int
    public var renderHeight: Int
    public var refreshRate: Int
    /// Fastest rate the panel supports: the current one drops to 24 Hz or lower when the screen idles.
    public var maxRefreshRate: Int
    /// Device state from `welcome.hw.device`: a snapshot taken when the sender said hello.
    public var battery: Int = -1
    public var charging = true
    public var thermal = "none"
    public var powerSave = false

    /// A phone or tablet running off its own battery.
    public var onBattery: Bool { battery >= 0 && !charging }
    /// none=0, light=1, moderate=2, severe=3, critical=4, and worse.
    public var thermalRank: Int {
        switch thermal {
        case "light": return 1
        case "moderate": return 2
        case "severe": return 3
        case "critical": return 4
        case "emergency": return 5
        case "shutdown": return 6
        default: return 0
        }
    }

    public init?(welcome: [String: Any]) {
        guard (welcome["t"] as? String) == "welcome" else { return nil }
        name = welcome["name"] as? String ?? "?"
        model = welcome["model"] as? String ?? ""
        maxSize = welcome["max"] as? String ?? ""
        modes = welcome["modes"] as? [String] ?? []
        decoders = welcome["decoders"] as? [String] ?? []
        let hw = welcome["hw"] as? [String: Any] ?? [:]
        audio = hw["audio"] as? [String] ?? []
        let bench = welcome["bench"] as? [String: Any] ?? [:]
        benchRes = bench["res"] as? String
        prefer = bench["prefer"] as? String
        let display = hw["display"] as? [String: Any] ?? [:]
        deviceType = display["type"] as? String ?? "unknown"
        let current = (display["current"] as? String)?.split(separator: "x") ?? []
        renderWidth = Int(current.first ?? "") ?? 0
        renderHeight = Int(current.last?.split(separator: "@").first ?? "") ?? 0
        refreshRate = (display["refresh"] as? NSNumber)?.intValue ?? 0
        var fastest = 0
        for entry in (display["modes"] as? [String] ?? []) {
            if let hz = entry.split(separator: "@").last.flatMap({ Int($0) }) { fastest = max(fastest, hz) }
        }
        maxRefreshRate = max(fastest, refreshRate)
        let device = hw["device"] as? [String: Any] ?? [:]
        battery = (device["battery"] as? NSNumber)?.intValue ?? -1
        charging = (device["charging"] as? Bool) ?? true
        thermal = device["thermal"] as? String ?? "none"
        powerSave = (device["power_save"] as? Bool) ?? false

        var parsed: [String: VideoCapability] = [:]
        for (mime, raw) in (hw["video"] as? [String: Any] ?? [:]) {
            guard let entry = raw as? [String: Any] else { continue }
            let size = (entry["max"] as? String)?.split(separator: "x") ?? []
            let width = Int(size.first ?? "") ?? 0
            let height = Int(size.last ?? "") ?? 0
            let benchEntry = bench[mime] as? [String: Any]
            parsed[mime] = VideoCapability(
                mime: mime,
                decoder: entry["decoder"] as? String ?? "",
                maxWidth: width,
                maxHeight: height,
                fullHD60: Self.flag(entry["1080p60"]),
                uhd60: Self.flag(entry["2160p60"]),
                tenBit: Self.flag(entry["10bit"]),
                lowLatency: Self.flag(entry["low_latency"]),
                benchMs: (benchEntry?["ms"] as? NSNumber)?.doubleValue)
        }
        video = parsed
    }

    private static func flag(_ any: Any?) -> Bool {
        if let number = any as? NSNumber { return number.boolValue }
        if let value = any as? Bool { return value }
        return false
    }

    public func canDecode(_ codec: VideoCodec) -> Bool {
        decoders.contains(codec.rawValue) || video[codec.rawValue] != nil
    }

    public func cap(_ codec: VideoCodec) -> VideoCapability? { video[codec.rawValue] }

    public var canDoMirror: Bool { modes.isEmpty || modes.contains("mirror") }
    public var hasOpus: Bool { audio.contains("audio/opus") }

    /// Short human-readable table for logs and `luch caps`.
    public func describe() -> String {
        var lines = ["receiver: \(name) (\(model)) type=\(deviceType)",
                     "modes: \(modes.joined(separator: ","))  max: \(maxSize)  opus: \(hasOpus ? "yes" : "no")  " +
                     "render: \(renderWidth)x\(renderHeight)@\(refreshRate)Hz (max \(maxRefreshRate))"]
        for codec in VideoCodec.allCases {
            guard let cap = cap(codec) else { continue }
            let bench = cap.benchMs.map { String(format: "%.1f ms", $0) } ?? "-"
            lines.append("  \(codec.rawValue): decoder=\(cap.decoder) max=\(cap.maxWidth)x\(cap.maxHeight) " +
                         "1080p60=\(cap.fullHD60 ? "y" : "n") 2160p60=\(cap.uhd60 ? "y" : "n") " +
                         "10bit=\(cap.tenBit ? "y" : "n") low_latency=\(cap.lowLatency ? "y" : "n") bench=\(bench)")
        }
        if let prefer { lines.append("  prefer: \(prefer)  (bench at \(benchRes ?? "?"))") }
        return lines.joined(separator: "\n")
    }
}
