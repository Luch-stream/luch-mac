// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import LuchMedia
@testable import LuchProto

final class ProtoTests: XCTestCase {
    func testHeaderLayout() {
        let h = Proto.header(kind: .video, flags: [.idr], shard: 2, shards: 5,
                             seq: 0x01020304, ptsUS: 0x0a0b0c0d, frameLen: 7000, hostLat: 33)
        XCTAssertEqual(Array(h[0..<8]), [1, 1, 0, 2, 0, 5, 0, 0])
        XCTAssertEqual(Array(h[8..<12]), [1, 2, 3, 4])
        XCTAssertEqual(Array(h[12..<16]), [0x0a, 0x0b, 0x0c, 0x0d])
        XCTAssertEqual(h.be32(16), 7000)
        XCTAssertEqual(h.be16(20), 33)
        XCTAssertEqual(h.count, Proto.headerSize)
    }

    func testFrameIsShardedAndReassembles() {
        let frame = (0..<(Proto.shardSize * 2 + 100)).map { UInt8(truncatingIfNeeded: $0) }
        let chunks = Proto.shards(frame)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks.map(\.count), [Proto.shardSize, Proto.shardSize, 100])
        XCTAssertEqual(Array(chunks.joined()), frame)
    }

    func testShardsEmptyFrame() {
        XCTAssertTrue(Proto.shards([]).isEmpty)
    }

    func testOpusHeadIsRfc7845() {
        let h = Proto.opusHead()
        XCTAssertEqual(h.count, 19)
        XCTAssertEqual(String(decoding: h[0..<8], as: UTF8.self), "OpusHead")
        XCTAssertEqual(h[8], 1)
        XCTAssertEqual(h[9], 2)
        XCTAssertEqual(UInt16(h[10]) | UInt16(h[11]) << 8, 312)
        XCTAssertEqual(UInt32(h[12]) | UInt32(h[13]) << 8 | UInt32(h[14]) << 16 | UInt32(h[15]) << 24, 48_000)
    }

    func testAnnexBAddsStartCodesAndParameterSets() {
        let sps = Data([0x67, 0x42, 0x00, 0x1f])
        let pps = Data([0x68, 0xce, 0x3c, 0x80])
        let idr = Data([0x65, 0x01, 0x02])
        let sei = Data([0x06, 0xaa])
        var avcc = Data()
        for nal in [sei, idr] {
            var len = UInt32(nal.count).bigEndian
            avcc.append(Data(bytes: &len, count: 4))
            avcc.append(nal)
        }
        let out = VideoEncoder.annexB(avcc, nalLengthSize: 4, paramSets: [sps, pps], isIDR: true)
        let expected = Data([0, 0, 0, 1]) + sps + Data([0, 0, 0, 1]) + pps
            + Data([0, 0, 0, 1]) + sei + Data([0, 0, 0, 1]) + idr
        XCTAssertEqual(out, expected)
    }

    func testAnnexBLeavesNonIDRWithoutParameterSets() {
        let nal = Data([0x41, 0x9a, 0x00])
        var avcc = Data()
        var len = UInt32(nal.count).bigEndian
        avcc.append(Data(bytes: &len, count: 4))
        avcc.append(nal)
        let out = VideoEncoder.annexB(avcc, nalLengthSize: 4, paramSets: [Data([0x67])], isIDR: false)
        XCTAssertEqual(out, Data([0, 0, 0, 1]) + nal)
    }

    func testAnnexBStopsOnTruncatedNal() {
        var avcc = Data([0, 0, 0, 99]) // promises 99 bytes, has none
        avcc.append(Data([0x65]))
        let out = VideoEncoder.annexB(avcc, nalLengthSize: 4, paramSets: [], isIDR: false)
        XCTAssertTrue(out.isEmpty)
    }
}
