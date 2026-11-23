// What the Mac answers to `hello`. The sender decides with this: which decoders exist, how big the
// picture may be, and how the screen is shaped.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import VideoToolbox

#if canImport(AppKit)
    import AppKit
#endif
#if canImport(UIKit)
    import UIKit
#endif

public enum ReceiveCaps {
    /// A stable id for this Mac, kept next to the sender's own id.
    public static func identifier() -> String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Luch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("viewer-id")
        if let text = try? String(contentsOf: file, encoding: .utf8),
            text.trimmingCharacters(in: .whitespacesAndNewlines).count == 36
        {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let id = UUID().uuidString
        try? id.write(to: file, atomically: true, encoding: .utf8)
        return id
    }

    public static func model() -> String {
        #if canImport(UIKit)
            return "\(UIDevice.current.model) \(UIDevice.current.systemVersion)"
        #else
            var uts = utsname()
            uname(&uts)
            let machine = withUnsafeBytes(of: &uts.machine) { raw -> String in
                let bytes = raw.prefix { $0 != 0 }
                return String(decoding: bytes, as: UTF8.self)
            }
            return machine.isEmpty ? "Mac" : machine
        #endif
    }

    /// Screen geometry in pixels, read on the main thread where AppKit wants it.
    public static func screen() -> (width: Int, height: Int, refresh: Int) {
        func read() -> (Int, Int, Int) {
            #if canImport(UIKit)
                let bounds = UIScreen.main.bounds
                let scale = UIScreen.main.scale
                let width = Int((bounds.width * scale).rounded())
                let height = Int((bounds.height * scale).rounded())
                let refresh = UIScreen.main.maximumFramesPerSecond
                return (width, height, refresh > 0 ? refresh : 60)
            #elseif canImport(AppKit)
                guard let screen = NSScreen.main ?? NSScreen.screens.first else { return (1920, 1080, 60) }
                let scale = screen.backingScaleFactor
                let width = Int((screen.frame.width * scale).rounded())
                let height = Int((screen.frame.height * scale).rounded())
                return (width, height, screen.maximumFramesPerSecond > 0 ? screen.maximumFramesPerSecond : 60)
            #else
                return (1920, 1080, 60)
            #endif
        }
        if Thread.isMainThread { return read() }
        return DispatchQueue.main.sync { read() }
    }

    /// `videoPreference` is the codec the person chose in settings; nil or an unavailable codec
    /// falls back to the hardware order.
    public static func welcome(
        name: String, id: String, accepting: Bool, audioCodecs: [String] = ["audio/opus"],
        videoPreference: String? = nil
    ) -> [String: Any] {
        let hevc = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        let avc = VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)
        let screen = screen()
        let maxSize = hevc || avc ? "3840x2160" : "1920x1080"

        func decoder(_ mime: String, _ name: String) -> [String: Any] {
            [
                "decoder": name, "max": maxSize, "1080p60": true, "2160p60": true, "10bit": false,
                "low_latency": true,
            ]
        }
        var video: [String: Any] = [:]
        var decoders: [String] = []
        if avc {
            video["video/avc"] = decoder("video/avc", "VideoToolbox H.264")
            decoders.append("video/avc")
        }
        if hevc {
            video["video/hevc"] = decoder("video/hevc", "VideoToolbox HEVC")
            decoders.append("video/hevc")
        }

        let current = "\(screen.width)x\(screen.height)@\(screen.refresh)"
        let display: [String: Any] = [
            "type": "desktop",
            "current": current,
            "rotation": 0,
            "refresh": screen.refresh,
            "modes": [current],
            "hdr": false,
            "game_mode": false,
        ]

        // A chosen codec moves to the front of the list and becomes the preferred one.
        if let videoPreference, decoders.contains(videoPreference) {
            decoders.removeAll { $0 == videoPreference }
            decoders.insert(videoPreference, at: 0)
        }

        // Measurements from an earlier bench: the fastest decoder wins, and a codec later in the
        // Android order has to be 0.5 ms faster, exactly as their Bench decides.
        var measured: [String: Double] = [:]
        for mime in decoders {
            let ms = UserDefaults.standard.double(forKey: "decode.\(mime)")
            if ms > 0 { measured[mime] = ms }
        }
        var preferred = decoders.first ?? (hevc ? "video/hevc" : "video/avc")
        if let fastest = measured.min(by: { $0.value < $1.value }) {
            preferred = fastest.key
            for mime in decoders {
                guard let ms = measured[mime], mime != fastest.key else { continue }
                if ms < fastest.value - 0.5, let index = decoders.firstIndex(of: mime),
                    let current = decoders.firstIndex(of: preferred), index < current
                {
                    preferred = mime
                }
            }
        }

        var bench: [String: Any] = [
            "prefer": preferred,
            "res":
                "\(screen.width > screen.height ? 1920 : 1080)x\(screen.width > screen.height ? 1080 : 1920)",
        ]
        // Decode times from the bench, so a sender starts from measurements, not guesses.
        for (mime, ms) in measured {
            bench[mime] = ["ms": (ms * 10).rounded() / 10]
        }

        return [
            "t": "welcome",
            "v": 0,
            "name": name,
            "model": model(),
            "max": maxSize,
            "modes": accepting ? ["mirror"] : [],
            "decoders": decoders,
            "hw": ["video": video, "audio": audioCodecs, "display": display],
            "bench": bench,
        ]
    }
}
