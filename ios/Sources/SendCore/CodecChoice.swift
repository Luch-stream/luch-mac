// Both sides have their own capabilities, and the pair has to be married into the combination that
// streams the most and decodes the fastest. The receiver says what it can decode and how fast it did
// that last time; this side says what it can encode. The same weights as the Mac planner are used,
// so a phone and a Mac pick the same codec for the same receiver.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum CodecChoice {
    /// Mirrors CodecWeights in LuchEngine.
    struct Weights {
        var efficiency = 25.0  // HEVC: fewer bits for the same picture
        var compatibility = 15.0  // H.264: every receiver understands it
        var perMs = 2.0  // one millisecond of decode is worth this much
        var baselineMs = 3.0  // the decode time we consider free
        var preferBonusMs = 3.0  // the receiver asked for it
        var fullHD60 = 5.0
        var fullHD60Missing = -25.0
        var lowLatency = 5.0
    }

    /// The best pair for this session, from the receiver's welcome and what we can encode.
    static func video(from welcome: [String: Any], weights: Weights = Weights())
        -> ScreenEncoder.Codec
    {
        let decoders = welcome["decoders"] as? [String] ?? []
        let bench = welcome["bench"] as? [String: Any] ?? [:]
        let prefer = bench["prefer"] as? String
        let hw = (welcome["hw"] as? [String: Any])?["video"] as? [String: Any] ?? [:]
        let encodable = Set(DeviceCapabilities.videoEncoders)

        var best: (codec: ScreenEncoder.Codec, score: Double)?
        for mime in decoders where encodable.contains(mime) {
            let codec: ScreenEncoder.Codec = mime == "video/hevc" ? .hevc : .avc
            var score = 0.0
            score += codec == .hevc ? weights.efficiency : weights.compatibility

            let entry = bench[mime] as? [String: Any]
            let ms = (entry?["ms"] as? Double) ?? (hw[mime] as? [String: Any]).flatMap(msFrom)
            if let ms {
                score += (weights.baselineMs - ms) * weights.perMs
                if prefer == mime { score += weights.preferBonusMs * weights.perMs }
            } else if prefer == mime {
                score += weights.preferBonusMs * weights.perMs
            }

            let caps = hw[mime] as? [String: Any]
            if let caps {
                score += (caps["full_hd_60"] as? Bool ?? false)
                    ? weights.fullHD60 : weights.fullHD60Missing
                if caps["low_latency"] as? Bool ?? false { score += weights.lowLatency }
            }

            if best == nil || score > best!.score {
                best = (codec, score)
            }
        }
        // Nothing in common: HEVC if this phone can, so the picture still goes out.
        return best?.codec ?? (DeviceCapabilities.videoEncoders.contains("video/hevc") ? .hevc : .avc)
    }

    private static func msFrom(_ entry: [String: Any]) -> Double? {
        (entry["hw_ms"] as? Double) ?? (entry["sw_ms"] as? Double)
    }
}
