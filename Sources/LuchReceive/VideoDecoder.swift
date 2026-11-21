// Decoding with VideoToolbox in our own code, so the receiver knows how long a frame really took and
// can report it to the sender. The display layer gets decoded sample buffers — it composites, it no
// longer decodes.
// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import Foundation
import VideoToolbox

public final class VideoDecoder {
    public var onDecoded: ((CMSampleBuffer) -> Void)?
    public var onDecodeTime: ((Double) -> Void)?

    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?

    public func decode(_ sample: CMSampleBuffer, format description: CMVideoFormatDescription) {
        if format == nil || !CMFormatDescriptionEqual(format, otherFormatDescription: description) {
            rebuild(description)
        }
        guard let session else { return }
        let start = DispatchTime.now().uptimeNanoseconds
        var flags = VTDecodeInfoFlags(rawValue: 0)
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [], infoFlagsOut: &flags
        ) { [weak self] status, _, imageBuffer, pts, _ in
            guard let self, status == noErr, let imageBuffer else { return }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            self.onDecodeTime?(elapsed)
            if let image = Self.imageSample(imageBuffer, pts: pts) {
                self.onDecoded?(image)
            }
        }
        if status != noErr {
            onDecodeTime?(-1)   // a failed frame still tells us the decoder is unhappy
        }
    }

    public func reset() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
    }

    private func rebuild(_ description: CMVideoFormatDescription) {
        reset()
        format = description
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        let specification: [String: Any] = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true]
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: description,
            decoderSpecification: specification as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &created)
        guard status == noErr, let created else { return }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = created
    }

    /// A decoded frame as a sample buffer the display layer can show immediately.
    private static func imageSample(_ image: CVImageBuffer, pts: CMTime) -> CMSampleBuffer? {
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: image,
            formatDescriptionOut: &description) == noErr, let description else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: image, formatDescription: description,
            sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
