// Synthetic NV12 frames for testing the encoder path without Screen Recording permission.
// SPDX-License-Identifier: GPL-3.0-or-later
import CoreVideo
import Foundation
import LuchProto

public enum SyntheticFrame {
    /// A moving gradient in the luma plane, neutral chroma: enough for the encoder to produce real P-frames.
    public static func make(width: Int, height: Int, index: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                         attrs as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let y = base.assumingMemoryBound(to: UInt8.self)
            let shift = index * 4
            for row in 0..<height {
                let line = y.advanced(by: row * stride)
                for col in 0..<width {
                    line[col] = UInt8(truncatingIfNeeded: (col + shift) & 0xff)
                }
            }
        }
        if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let c = base.assumingMemoryBound(to: UInt8.self)
            for row in 0..<(height / 2) {
                let line = c.advanced(by: row * stride)
                for col in 0..<(width / 2) {
                    line[col * 2] = 128
                    line[col * 2 + 1] = 128
                }
            }
        }
        return buffer
    }
}
