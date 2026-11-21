// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import LuchEngine

final class EngineTests: XCTestCase {
    /// The receiver tears the session down after 15 s without video packets; both keepalive rates must
    /// leave a wide margin, including the slow one used for a repeated IDR.
    func testKeepaliveBeatsReceiverSilenceLimit() {
        let receiverSilence: TimeInterval = 15
        XCTAssertLessThan(Engine.keepaliveInterval(isIDR: false), receiverSilence / 3)
        XCTAssertLessThan(Engine.keepaliveInterval(isIDR: true), receiverSilence / 2)
    }

    func testKeepaliveRates() {
        XCTAssertEqual(Engine.keepaliveInterval(isIDR: false), 0.5)
        XCTAssertEqual(Engine.keepaliveInterval(isIDR: true), 5.0)
    }
}
