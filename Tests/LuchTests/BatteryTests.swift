// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import LuchEngine

final class BatteryTests: XCTestCase {
    private func caps(battery: Int, charging: Bool, thermal: String = "none", powerSave: Bool = false,
                      max: String = "2340x1080") -> ReceiverCaps {
        ReceiverCaps(welcome: [
            "t": "welcome", "name": "phone", "model": "m", "max": max, "modes": ["mirror"],
            "decoders": ["video/avc", "video/hevc"],
            "hw": ["video": [
                "video/avc": ["decoder": "a", "max": max, "1080p60": true],
                "video/hevc": ["decoder": "b", "max": max, "1080p60": true],
            ], "display": ["type": "phone", "current": "2340x1080@120", "modes": ["2340x1080@120"],
                         "refresh": 60],
                   "device": ["battery": battery, "charging": charging, "thermal": thermal,
                              "power_save": powerSave]],
        ])!
    }

    /// The user decides; we only warn. A client on battery still gets the preset it asked for.
    func testBatteryDoesNotCapThePicture() {
        var options = MirrorOptions()
        options.codec = .auto
        options.sizeMode = .source
        options.preset = .max
        let plan = CodecPlanner.plan(caps: caps(battery: 40, charging: false, max: "3840x2160"),
                                     receiverID: nil, options: options)
        XCTAssertGreaterThan(plan.height, 1080)
    }

    func testOnBatteryIsReported() {
        XCTAssertTrue(caps(battery: 40, charging: false).onBattery)
        XCTAssertFalse(caps(battery: 100, charging: true).onBattery)
    }

    func testChargingKeepsThePreset() {
        var options = MirrorOptions()
        options.codec = .auto
        options.sizeMode = .source
        options.preset = .high
        // A 4K-capable client keeps the preset while it is charging.
        let plan = CodecPlanner.plan(caps: caps(battery: 100, charging: true, max: "3840x2160"),
                                     receiverID: nil, options: options)
        XCTAssertGreaterThan(plan.height, 1080)
    }

    func testThermalIsReportedNotEnforced() {
        XCTAssertEqual(caps(battery: 20, charging: false, thermal: "moderate").thermalRank, 2)
        XCTAssertEqual(caps(battery: 20, charging: false, thermal: "critical").thermalRank, 4)
    }
}
