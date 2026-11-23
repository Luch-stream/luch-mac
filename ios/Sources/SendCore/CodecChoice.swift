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

    /// Android's Bench orders codecs this way when they decode about as fast: the more senders can
    /// encode a codec, the better. VP9 and AV1 are listed there too; this phone cannot encode them,
    /// so they never become candidates here.
    private static let order = ["video/avc", "video/hevc"]

    /// The best pair for this session: the receiver's fastest decoder that this phone can encode.
    /// A codec lower in the order has to win by 0.5 ms, exactly as the Android bench decides.
    static func video(from welcome: [String: Any], weights: Weights = Weights())
        -> ScreenEncoder.Codec
    {
        let decoders = welcome["decoders"] as? [String] ?? []
        let bench = welcome["bench"] as? [String: Any] ?? [:]
        let prefer = bench["prefer"] as? String
        let hw = (welcome["hw"] as? [String: Any])?["video"] as? [String: Any] ?? [:]
        let encodable = Set(DeviceCapabilities.videoEncoders)

        var measured: [String: Double] = [:]
        for mime in order where decoders.contains(mime) && encodable.contains(mime) {
            if let ms = (bench[mime] as? [String: Any]).flatMap(measuredMs)
                ?? (hw[mime] as? [String: Any]).flatMap(msFrom)
            {
                measured[mime] = ms
            }
        }

        if let fastest = measured.min(by: { $0.value < $1.value }) {
            var winner = fastest.key
            for mime in order where mime != winner {
                if let ms = measured[mime], ms < fastest.value - 0.5,
                    orderIndex(mime) < orderIndex(winner)
                {
                    winner = mime
                }
            }
            // The receiver's own answer settles a tie it takes part in.
            if let prefer, prefer != winner, let preferMs = measured[prefer],
                let winnerMs = measured[winner], preferMs < winnerMs - 0.5
            {
                winner = prefer
            }
            return winner == "video/hevc" ? .hevc : .avc
        }

        // Nothing measured: fall back to the receiver's word, then to the weighted score.
        if let prefer, decoders.contains(prefer), encodable.contains(prefer) {
            return prefer == "video/hevc" ? .hevc : .avc
        }
        return weighted(decoders: decoders, bench: bench, hw: hw, encodable: encodable, weights: weights)
    }

    private static func orderIndex(_ mime: String) -> Int {
        order.firstIndex(of: mime) ?? order.count
    }

    private static func measuredMs(_ entry: [String: Any]) -> Double? {
        entry["ms"] as? Double
    }

    /// No measurement at all: HEVC saves bits, H.264 reaches further, and 1080p60 or a low-latency
    /// decoder breaks the tie.
    private static func weighted(
        decoders: [String], bench: [String: Any], hw: [String: Any], encodable: Set<String>,
        weights: Weights
    ) -> ScreenEncoder.Codec {
        let prefer = bench["prefer"] as? String
        var best: (codec: ScreenEncoder.Codec, score: Double)?
        for mime in order where decoders.contains(mime) && encodable.contains(mime) {
            let codec: ScreenEncoder.Codec = mime == "video/hevc" ? .hevc : .avc
            var score = codec == .hevc ? weights.efficiency : weights.compatibility
            if prefer == mime { score += weights.preferBonusMs * weights.perMs }
            if let caps = hw[mime] as? [String: Any] {
                score += (caps["1080p60"] as? Bool ?? false)
                    ? weights.fullHD60 : weights.fullHD60Missing
                if caps["low_latency"] as? Bool ?? false { score += weights.lowLatency }
            }
            if best == nil || score > best!.score { best = (codec, score) }
        }
        return best?.codec ?? (encodable.contains("video/hevc") ? .hevc : .avc)
    }

    private static func msFrom(_ entry: [String: Any]) -> Double? {
        (entry["hw_ms"] as? Double) ?? (entry["sw_ms"] as? Double)
    }
}
