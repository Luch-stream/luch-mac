// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import LuchMedia

final class WarmTests: XCTestCase {
    /// Bright pixels warm up, dark ones do not: a constant chroma offset would turn black UI green.
    func testWarmthFollowsLuma() {
        var luma = [UInt8](repeating: 20, count: 16)    // 4x4 dark, except one bright sample
        luma[0] = 235
        var chroma = [UInt8](repeating: 0, count: 16)   // 2x2 samples, CbCr, stride 8
        for i in stride(from: 0, to: 16, by: 2) {
            chroma[i] = 200
            chroma[i + 1] = 100
        }
        luma.withUnsafeMutableBytes { lp in
            chroma.withUnsafeMutableBytes { cp in
                WarmFilter.apply(luma: lp.baseAddress!, lumaWidth: 4, lumaStride: 4,
                                 chroma: cp.baseAddress!, chromaWidth: 2, chromaHeight: 2,
                                 chromaStride: 8, strength: 1.0)
            }
        }
        XCTAssertEqual(chroma[0], 188, "bright pixel: Cb drops by the full 12")
        XCTAssertEqual(chroma[1], 108, "bright pixel: Cr rises by the full 8")
        XCTAssertEqual(chroma[8], 199, "dark pixel: almost no shift")
        XCTAssertEqual(chroma[9], 101, "dark pixel: almost no shift")
    }

    func testOffIsANoOp() {
        var luma = [UInt8](repeating: 200, count: 16)
        var chroma = [UInt8](repeating: 200, count: 16)
        let before = chroma
        luma.withUnsafeMutableBytes { lp in
            chroma.withUnsafeMutableBytes { cp in
                WarmFilter.apply(luma: lp.baseAddress!, lumaWidth: 4, lumaStride: 4,
                                 chroma: cp.baseAddress!, chromaWidth: 2, chromaHeight: 2,
                                 chromaStride: 8, strength: 0)
            }
        }
        XCTAssertEqual(chroma, before)
    }
}
