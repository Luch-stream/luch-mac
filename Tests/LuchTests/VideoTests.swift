// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import LuchMedia

final class VideoTests: XCTestCase {
    func testH264NalTypes() {
        XCTAssertEqual(VideoCodec.h264.nalType(Data([0x65, 0x88])), 5)   // IDR slice
        XCTAssertEqual(VideoCodec.h264.nalType(Data([0x27, 0x42])), 7)   // SPS with nal_ref_idc=1
        XCTAssertTrue(VideoCodec.h264.isIRAP(Data([0x65])))
        XCTAssertFalse(VideoCodec.h264.isIRAP(Data([0x41])))
    }

    func testHEVCNalTypes() {
        XCTAssertEqual(VideoCodec.hevc.nalType(Data([0x26, 0x01])), 19) // IDR_W_RADL
        XCTAssertEqual(VideoCodec.hevc.nalType(Data([0x28, 0x01])), 20) // IDR_N_LP
        XCTAssertEqual(VideoCodec.hevc.nalType(Data([0x2a, 0x01])), 21) // CRA
        XCTAssertEqual(VideoCodec.hevc.nalType(Data([0x40, 0x01])), 32) // VPS
        XCTAssertEqual(VideoCodec.hevc.nalType(Data([0x42, 0x01])), 33) // SPS
        XCTAssertEqual(VideoCodec.hevc.nalType(Data([0x44, 0x01])), 34) // PPS
        XCTAssertEqual(VideoCodec.hevc.nalType(Data([0x02, 0x01])), 1)  // TRAIL_R
        XCTAssertTrue(VideoCodec.hevc.isIRAP(Data([0x26, 0x01])))
        XCTAssertFalse(VideoCodec.hevc.isIRAP(Data([0x02, 0x01])))
        XCTAssertFalse(VideoCodec.hevc.isIRAP(Data([0x40, 0x01])))
    }

    func testHEVCAnnexBStampsVPS_SPS_PPS() {
        let vps = Data([0x40, 0x01, 0x0c])
        let sps = Data([0x42, 0x01, 0x01])
        let pps = Data([0x44, 0x01, 0xc1])
        let idr = Data([0x26, 0x01, 0xaf])
        var avcc = Data()
        for nal in [vps, sps, pps, idr] {
            var len = UInt32(nal.count).bigEndian
            avcc.append(Data(bytes: &len, count: 4))
            avcc.append(nal)
        }
        let out = VideoEncoder.annexB(avcc, nalLengthSize: 4, paramSets: [vps, sps, pps], isIDR: true)
        let sc = Data([0, 0, 0, 1])
        var expected = Data()
        for nal in [vps, sps, pps] { expected.append(sc); expected.append(nal) }
        for nal in [vps, sps, pps, idr] { expected.append(sc); expected.append(nal) }
        XCTAssertEqual(out, expected)
    }
}
