// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import LuchEngine

final class PresetTests: XCTestCase {
    func testHeights() {
        XCTAssertEqual(QualityPreset.low.height, 720)
        XCTAssertEqual(QualityPreset.balanced.height, 1080)
        XCTAssertEqual(QualityPreset.high.height, 1440)
        XCTAssertEqual(QualityPreset.max.height, 2160)
    }

    func testParsing() {
        XCTAssertEqual(QualityPreset.parse("720p"), .low)
        XCTAssertEqual(QualityPreset.parse("1080P"), .balanced)
        XCTAssertEqual(QualityPreset.parse("2k"), .high)
        XCTAssertEqual(QualityPreset.parse("4k"), .max)
        XCTAssertEqual(QualityPreset.parse("1440p"), .high)
        XCTAssertEqual(QualityPreset.parse("2160p"), .max)
        XCTAssertNil(QualityPreset.parse("8k"))
    }

    /// The preset sets the height, the size mode the aspect: 4K keeps the Mac's aspect.
    func testPlanFollowsPreset() {
        let caps = ReceiverCaps(welcome: [
            "t": "welcome", "name": "tv", "model": "m", "max": "1920x1080", "modes": ["mirror"],
            "decoders": ["video/avc", "video/hevc"],
            "hw": ["video": [
                "video/avc": ["decoder": "a", "max": "1920x1080", "1080p60": true, "low_latency": true],
                "video/hevc": ["decoder": "b", "max": "1920x1080", "1080p60": true, "low_latency": true],
            ], "display": ["type": "tv", "modes": ["1920x1080@60"]]],
        ])!
        var options = MirrorOptions()
        options.codec = .auto
        options.preset = .low
        options.sizeMode = .source
        let low = CodecPlanner.plan(caps: caps, receiverID: nil, options: options)
        XCTAssertEqual(low.height, 720)
        options.preset = .max
        let max = CodecPlanner.plan(caps: caps, receiverID: nil, options: options)
        // 4K cannot be decoded by a 1080p receiver: the decoder limit wins over the preset.
        XCTAssertLessThanOrEqual(max.height, 1080)
        XCTAssertGreaterThan(max.height, 720)
    }
}
