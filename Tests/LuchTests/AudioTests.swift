// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import LuchMedia
import LuchProto

final class AudioTests: XCTestCase {
    func testOpusHeadUsesEncoderPreSkip() throws {
        let audio = try XCTUnwrap(OpusAudio())
        let head = audio.head
        XCTAssertEqual(head.count, 19)
        XCTAssertEqual(String(decoding: head[0..<8], as: UTF8.self), "OpusHead")
        XCTAssertEqual(head[9], 2)
        let preSkip = UInt16(head[10]) | UInt16(head[11]) << 8
        XCTAssertEqual(preSkip, audio.preSkip)
        XCTAssertGreaterThan(preSkip, 0)
        let rate = UInt32(head[12]) | UInt32(head[13]) << 8 | UInt32(head[14]) << 16 | UInt32(head[15]) << 24
        XCTAssertEqual(rate, 48_000)
    }

    func testFramesAreCutToFiveMilliseconds() throws {
        let audio = try XCTUnwrap(OpusAudio())
        var packets: [Data] = []
        audio.onPacket = { data, _ in packets.append(data) }

        audio.emit([Float](repeating: 0, count: 480), pts: .zero) // exactly 5 ms stereo
        XCTAssertEqual(packets.count, 1)

        audio.emit([Float](repeating: 0, count: 960), pts: .zero) // exactly 10 ms
        XCTAssertEqual(packets.count, 3)
        XCTAssertTrue(packets.allSatisfy { !$0.isEmpty && $0.count < 4000 })
    }

    func testPartialFrameIsBuffered() throws {
        let audio = try XCTUnwrap(OpusAudio())
        var packets: [Data] = []
        audio.onPacket = { data, _ in packets.append(data) }
        audio.emit([Float](repeating: 0, count: 300), pts: .zero) // 3.1 ms: not a whole frame
        XCTAssertEqual(packets.count, 0)
        audio.emit([Float](repeating: 0, count: 180), pts: .zero) // tops it up to 5 ms
        XCTAssertEqual(packets.count, 1)
    }
}
