// Debug helper: decode frames with VideoToolbox and write one to the path in LUCH_SNAPSHOT.
// Handy for tests and for checking the receiver without screen-capture permission. Keeps one
// decompression session, because a P-frame needs the frames before it to decode.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreImage
import CoreMedia
import VideoToolbox

final class Snapshot {
    private let path = ProcessInfo.processInfo.environment["LUCH_SNAPSHOT"]
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var seen = 0

    func maybeSave(_ sample: CMSampleBuffer) {
        guard let path, let description = CMSampleBufferGetFormatDescription(sample) else { return }
        if format == nil || CMFormatDescriptionEqual(format, otherFormatDescription: description) == false {
            session = nil
            format = description
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            VTDecompressionSessionCreate(
                allocator: nil, formatDescription: description,
                decoderSpecification: nil,
                imageBufferAttributes: attributes as CFDictionary,
                outputCallback: nil, decompressionSessionOut: &session)
        }
        guard let session else { return }
        seen += 1
        let wanted = seen % 120 == 0
        var info = VTDecodeInfoFlags(rawValue: 0)
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: &info) {
            status, _, imageBuffer, _, _ in
            guard wanted, status == noErr, let imageBuffer else { return }
            let image = CIImage(cvPixelBuffer: imageBuffer)
            guard let cgImage = CIContext().createCGImage(image, from: image.extent) else { return }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}
