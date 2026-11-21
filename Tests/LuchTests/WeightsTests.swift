// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import LuchEngine
import LuchMedia

final class WeightsTests: XCTestCase {
    func testWeightsSpecRoundTrip() {
        var weights = CodecWeights()
        weights.efficiency = 40
        weights.compatibility = 5
        let parsed = CodecWeights(spec: weights.spec)
        XCTAssertEqual(parsed?.efficiency, 40)
        XCTAssertEqual(parsed?.compatibility, 5)
        XCTAssertEqual(parsed?.preferMs, weights.preferMs)
    }

    func testUnknownWeightIsRejected() {
        XCTAssertNil(CodecWeights(spec: "preferms=10,blah=1"))
        XCTAssertNil(CodecWeights(spec: "prefer"))
    }

    /// At equal decode times HEVC wins on bitrate; a much faster H.264 flips it back.
    func testHEVCWinsUnlessH264IsMuchFaster() {
        let caps = ReceiverCaps(welcome: [
            "t": "welcome", "name": "tv", "model": "m", "max": "1920x1080", "modes": ["mirror"],
            "decoders": ["video/avc", "video/hevc"],
            "hw": ["video": [
                "video/avc": ["decoder": "a", "max": "1920x1080", "1080p60": true, "low_latency": true],
                "video/hevc": ["decoder": "b", "max": "1920x1080", "1080p60": true, "low_latency": true],
            ]],
            "bench": ["prefer": "video/avc",
                      "video/avc": ["ms": 10.0], "video/hevc": ["ms": 10.0]],
        ])!

        var options = MirrorOptions()
        options.codec = .auto
        let plan = CodecPlanner.plan(caps: caps, receiverID: nil, options: options)
        XCTAssertEqual(plan.codec, .hevc, "equal decode times: HEVC should win on bitrate")

        var capsSlowHEVC = caps
        capsSlowHEVC.video["video/hevc"]?.benchMs = 45
        let planSlow = CodecPlanner.plan(caps: capsSlowHEVC, receiverID: nil, options: options)
        XCTAssertEqual(planSlow.codec, .h264, "much faster H.264 should win")
    }
}
