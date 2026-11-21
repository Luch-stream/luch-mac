// Weighted codec grading. The client's benchmark is one input, not the whole decision: HEVC buys
// ~25-30% bitrate at the same quality, H.264 is the most compatible, and an explicit `prefer` from
// the receiver is a strong signal. Weights are overridable so the trade-off can be measured, and a
// decode time measured during an earlier session outranks the receiver's own benchmark (that one
// drains into an ImageReader and reports the decoder core, not the path to the screen).
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import LuchMedia
import LuchProto

public struct CodecPlan {
    public var codec: VideoCodec
    public var width: Int
    public var height: Int
    public var fps: Int
    public var audio: Bool
    public var reason: String
}

public struct CodecWeights {
    /// Milliseconds of credit for the codec the receiver names as its fastest. A credit, not a flat
    /// bonus: at equal decode times HEVC still wins on bitrate, which is the intended default.
    public var preferMs = 3.0
    /// Bitrate saved at the same quality: HEVC vs H.264.
    public var efficiency = 25.0
    /// How widely the codec is decodable: H.264 wins here.
    public var compatibility = 15.0
    /// Score per millisecond of decode latency, relative to `msBaseline`.
    public var perMs = 2.0
    public var msBaseline = 20.0
    public var fullHD60 = 5.0
    public var fullHD60Missing = -25.0
    public var lowLatency = 5.0

    public init() {}

    /// Parses "prefer=30,bytes=25,compat=15,ms=2,base=20,hd60=5,nohd60=-25,lowlat=5".
    /// Unknown keys are rejected so a typo cannot silently change the decision.
    public init?(spec: String) {
        for part in spec.split(separator: ",") {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2, let value = Double(kv[1].trimmingCharacters(in: .whitespaces)) else { return nil }
            switch kv[0].trimmingCharacters(in: .whitespaces) {
            case "prefer", "preferms": preferMs = value
            case "bytes", "efficiency": efficiency = value
            case "compat", "compatibility": compatibility = value
            case "ms", "perms", "per_ms": perMs = value
            case "base", "baseline": msBaseline = value
            case "hd60": fullHD60 = value
            case "nohd60": fullHD60Missing = value
            case "lowlat": lowLatency = value
            default: return nil
            }
        }
    }

    public var spec: String {
        String(format: "preferms=%.1f,bytes=%.1f,compat=%.1f,ms=%.1f,base=%.1f,hd60=%.1f,nohd60=%.1f,lowlat=%.1f",
               preferMs, efficiency, compatibility, perMs, msBaseline, fullHD60, fullHD60Missing, lowLatency)
    }
}

public struct CodecScore {
    public var codec: VideoCodec
    public var total: Double
    public var decodeMs: Double?
    /// Where `decodeMs` came from: "measured" (a real session) or "bench" (the receiver's own test).
    public var source: String
    public var parts: [(String, Double)]

    public var summary: String {
        let detail = parts.map { String(format: "%@%+.1f", $0.0, $0.1) }.joined(separator: " ")
        let ms = decodeMs.map { String(format: "%.1f ms %@", $0, source) } ?? "no measurement"
        return String(format: "%-6@ %6.1f  (%@)  %@", codec.label as NSString, total, ms as NSString, detail as NSString)
    }
}

/// Decode times measured during real sessions, per receiver and per codec.
public final class CodecMemory {
    public static let shared = CodecMemory()
    private let defaults = UserDefaults.standard

    private func key(_ receiverID: String, _ codec: VideoCodec) -> String {
        "measured.\(receiverID).\(codec.rawValue)"
    }

    public func measuredMs(receiverID: String, codec: VideoCodec) -> Double? {
        guard receiverID != "manual" else { return nil }
        let value = defaults.double(forKey: key(receiverID, codec))
        return value > 0 ? value : nil
    }

    public func record(receiverID: String, codec: VideoCodec, ms: Double) {
        // A decoder that "takes" hundreds of milliseconds is a measurement artifact (a frame stuck in a
        // queue), not a property of the codec: it would poison every later decision.
        guard receiverID != "manual", ms >= 1, ms <= 120 else { return }
        defaults.set(ms, forKey: key(receiverID, codec))
    }
}

public enum CodecPlanner {
    private static var supportCache: [String: Bool] = [:]
    private static let cacheLock = NSLock()

    public static func macSupports(_ codec: VideoCodec, width: Int, height: Int) -> Bool {
        let key = "\(codec.rawValue)@\(width)x\(height)"
        cacheLock.lock()
        if let hit = supportCache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        let ok = VideoEncoder.supports(codec, width: width, height: height)
        cacheLock.lock(); supportCache[key] = ok; cacheLock.unlock()
        return ok
    }

    public static func score(_ codec: VideoCodec, caps: ReceiverCaps, receiverID: String?,
                             width: Int, height: Int,
                             weights: CodecWeights = CodecWeights()) -> CodecScore? {
        guard caps.canDecode(codec), macSupports(codec, width: width, height: height) else { return nil }
        let cap = caps.cap(codec)
        var parts: [(String, Double)] = []
        var total = 0.0

        // HEVC: better compression per bit.
        let eff = codec == .hevc ? weights.efficiency : 0
        if eff != 0 { total += eff; parts.append(("bytes", eff)) }
        // H.264: every receiver out there understands it.
        let compat = codec == .h264 ? weights.compatibility : 0
        if compat != 0 { total += compat; parts.append(("compat", compat)) }

        // A real session outranks the receiver's benchmark.
        var decodeMs = receiverID.flatMap { CodecMemory.shared.measuredMs(receiverID: $0, codec: codec) }
        var source = "measured"
        if decodeMs == nil {
            decodeMs = cap?.benchMs
            source = "bench"
        }
        var effectiveMs = decodeMs
        if caps.prefer == codec.rawValue, let ms = effectiveMs {
            effectiveMs = max(0, ms - weights.preferMs)
            parts.append(("prefer", weights.preferMs * weights.perMs))
        }
        if let ms = effectiveMs {
            let speed = (weights.msBaseline - ms) * weights.perMs
            total += speed; parts.append(("ms", speed))
        }
        if let cap {
            let hd = cap.fullHD60 ? weights.fullHD60 : weights.fullHD60Missing
            total += hd; parts.append(("1080p60", hd))
            if cap.lowLatency { total += weights.lowLatency; parts.append(("lowlat", weights.lowLatency)) }
        }
        return CodecScore(codec: codec, total: total, decodeMs: decodeMs, source: source, parts: parts)
    }

    public static func ranking(caps: ReceiverCaps, receiverID: String?, width: Int, height: Int,
                               weights: CodecWeights = CodecWeights()) -> [CodecScore] {
        VideoCodec.allCases
            .compactMap { score($0, caps: caps, receiverID: receiverID, width: width, height: height, weights: weights) }
            .sorted { $0.total > $1.total }
    }

    public static func plan(caps: ReceiverCaps, receiverID: String?, options: MirrorOptions) -> CodecPlan {
        var width = options.width
        var height = options.height
        var fps = options.fps
        var reasons: [String] = []

        guard caps.canDoMirror else {
            return CodecPlan(codec: .h264, width: width, height: height, fps: fps, audio: false,
                             reason: "receiver does not advertise the mirror mode (\(caps.modes))")
        }

        let scores = ranking(caps: caps, receiverID: receiverID, width: width, height: height,
                             weights: options.weights)
        let chosen: VideoCodec
        switch options.codec {
        case .h264:
            chosen = scores.contains(where: { $0.codec == .h264 }) ? .h264 : (scores.first?.codec ?? .h264)
            reasons.append("forced H.264")
        case .hevc:
            if scores.contains(where: { $0.codec == .hevc }) {
                chosen = .hevc
                reasons.append("forced HEVC")
            } else {
                chosen = scores.first?.codec ?? .h264
                reasons.append("HEVC forced but not usable here, using \(chosen.label)")
            }
        case .auto:
            if let best = scores.first {
                chosen = best.codec
                reasons.append("best score \(String(format: "%.1f", best.total)) for \(best.codec.label)")
                if let second = scores.dropFirst().first {
                    reasons.append("vs \(String(format: "%.1f", second.total)) for \(second.codec.label)")
                }
                if let prefer = caps.prefer, prefer != best.codec.rawValue {
                    reasons.append("(receiver preferred \(prefer), not encodable here)")
                }
            } else {
                chosen = .h264
                reasons.append("no codec both sides support, trying H.264")
            }
        }

        // Two knobs: the size mode picks the aspect, the preset picks the height.
        let screen = NSScreen.main?.frame.size ?? CGSize(width: 16, height: 10)
        let sourceAspect = Double(screen.width) / Double(max(1, screen.height))
        let clientW = max(caps.renderWidth, caps.renderHeight)
        let clientH = min(caps.renderWidth, caps.renderHeight)
        let clientAspect = clientW > 0 && clientH > 0 ? Double(clientW) / Double(clientH) : 0
        if options.explicitSize, options.width > 0, options.height > 0 {
            width = options.width
            height = options.height
            reasons.append("explicit size \(width)x\(height)")
        } else {
            let aspect: Double
            switch options.sizeMode {
            case .source:
                aspect = sourceAspect
                reasons.append("\(options.preset.label), source aspect")
            case .client:
                aspect = clientAspect > 0 ? clientAspect : sourceAspect
                reasons.append("\(options.preset.label), client aspect (desktop cropped)")
            case .average:
                aspect = clientAspect > 0 ? (sourceAspect + clientAspect) / 2 : sourceAspect
                reasons.append(String(format: "\(options.preset.label), average aspect %.2f", aspect))
            case .fit:
                aspect = sourceAspect
                reasons.append("\(options.preset.label), fit to the client's screen")
            }
            // The preset describes my own renderer: it is honoured in `source` mode only. In the
            // other modes the client's screen decides, so a preset there would fight it.
            let targetHeight: Int
            switch options.preset {
            case .auto:
                // Exactly what the client reports: its own render height, no extra cap from us.
                targetHeight = clientH > 0 ? clientH : 1080
            default:
                targetHeight = options.sizeMode == .source
                    ? options.preset.height
                    : min(options.preset.height, clientH > 0 ? clientH : options.preset.height)
            }
            height = max(2, targetHeight / 2 * 2)
            width = max(2, Int((Double(height) * aspect) / 2) * 2)
            // Never wider than the client's surface: upscaling there would only cost pixels.
            if options.sizeMode == .fit, clientW > 0, width > clientW {
                width = max(2, clientW / 2 * 2)
                height = max(2, Int((Double(width) / aspect) / 2) * 2)
            }
        }
        // The decoder's own limit is the last word: 4K into a 1080p panel is clamped proportionally.
        if let cap = caps.cap(chosen) {
            let maxW = cap.maxWidth > 0 ? cap.maxWidth : width
            let maxH = cap.maxHeight > 0 ? cap.maxHeight : height
            if width > maxW || height > maxH {
                let scale = min(Double(maxW) / Double(width), Double(maxH) / Double(height))
                width = max(2, Int((Double(width) * scale) / 2) * 2)
                height = max(2, Int((Double(height) * scale) / 2) * 2)
                reasons.append("clamped to the decoder's \(maxW)x\(maxH)")
            }
            if width >= 1920, height >= 1080, !cap.fullHD60 {
                fps = min(fps, 30)
                reasons.append("decoder has no 1080p60, capped at 30 fps")
            }
        }
        if caps.maxRefreshRate > 0, fps > caps.maxRefreshRate {
            fps = caps.maxRefreshRate
            reasons.append("client panel tops out at \(caps.maxRefreshRate) Hz, capped")
        }
        if let res = caps.benchRes, res != "\(width)x\(height)" {
            reasons.append("benchmark measured at \(res)")
        }

        let audio = options.audio && caps.hasOpus
        if options.audio && !caps.hasOpus { reasons.append("receiver has no audio/opus, video only") }

        return CodecPlan(codec: chosen, width: width, height: height, fps: fps, audio: audio,
                         reason: reasons.joined(separator: "; "))
    }
}
