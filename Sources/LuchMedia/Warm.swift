// Warm the picture for night viewing: pull the blue chroma down and the red up, directly in the NV12
// chroma plane before the encoder. The shift is weighted by luma, so dark UI stays neutral instead of
// turning green, and only the bright parts of the picture actually get warmer. One pass over a
// half-resolution plane: well under a millisecond, no Core Image, no extra buffer.
// SPDX-License-Identifier: GPL-3.0-or-later
import CoreVideo
import Foundation

public enum WarmFilter {
    /// `strength` 0 = untouched, 1 = strong night mode.
    public static func apply(_ buffer: CVPixelBuffer, strength: Double) {
        guard strength > 0.01 else { return }
        guard CVPixelBufferGetPlaneCount(buffer) >= 2 else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return }
        apply(luma: luma,
              lumaWidth: CVPixelBufferGetWidthOfPlane(buffer, 0),
              lumaStride: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0),
              chroma: chroma,
              chromaWidth: CVPixelBufferGetWidthOfPlane(buffer, 1),
              chromaHeight: CVPixelBufferGetHeightOfPlane(buffer, 1),
              chromaStride: CVPixelBufferGetBytesPerRowOfPlane(buffer, 1),
              strength: strength)
    }

    /// Byte-level pass, exposed for tests and for callers that already hold the planes.
    public static func apply(luma: UnsafeMutableRawPointer, lumaWidth: Int, lumaStride: Int,
                             chroma: UnsafeMutableRawPointer, chromaWidth: Int, chromaHeight: Int,
                             chromaStride: Int, strength: Double) {
        let s = Float(min(1, max(0, strength)))
        let cbShift = -12 * s
        let crShift = 8 * s
        for row in 0..<chromaHeight {
            let c = chroma.advanced(by: row * chromaStride).assumingMemoryBound(to: UInt8.self)
            // Video-range luma: 0 is black, 235 is white. Weighting by it keeps blacks neutral, which a
            // constant chroma offset does not (it tints dark UI green).
            let yRow = luma.advanced(by: row * 2 * lumaStride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<chromaWidth {
                let lumaX = min(lumaWidth - 1, x * 2)
                let weight = min(1, max(0, Float(yRow[lumaX]) / 235))
                c[x * 2] = clamp(Float(c[x * 2]) + cbShift * weight)
                c[x * 2 + 1] = clamp(Float(c[x * 2 + 1]) + crShift * weight)
            }
        }
    }

    private static func clamp(_ value: Float) -> UInt8 {
        UInt8(min(255, max(0, value.rounded())))
    }
}
