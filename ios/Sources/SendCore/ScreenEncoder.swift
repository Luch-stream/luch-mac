// VideoToolbox on the phone: ReplayKit gives pixel buffers, the wire wants Annex-B with the
// parameter sets in front of every IRAP, exactly like the Mac sender writes it.
// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

final class ScreenEncoder {
    /// (annex-b frame, pts in microseconds, isKeyframe)
    var onFrame: (([UInt8], UInt32, Bool) -> Void)?
    var onKeyframeRequest: (() -> Void)?

    private var session: VTCompressionSession?
    private var parameterSets: [UInt8] = []
    private let width: Int
    private let height: Int

    init?(width: Int, height: Int, fps: Int, bitrate: Int) {
        self.width = width
        self.height = height
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_HEVC, encoderSpecification: nil,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
            refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else {
            // HEVC may be unavailable; fall back to H.264.
            var fallback: VTCompressionSession?
            let h264 = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
                codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
                refcon: nil, compressionSessionOut: &fallback)
            guard h264 == noErr, let fallback else { return nil }
            self.session = fallback
            configure(fallback, fps: fps, bitrate: bitrate)
            return
        }
        self.session = session
        configure(session, fps: fps, bitrate: bitrate)
    }

    private func configure(_ session: VTCompressionSession, fps: Int, bitrate: Int) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_ProfileLevel,
            value: kVTProfileLevel_HEVC_Main_AutoLevel as CFString)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: fps as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func encode(_ pixelBuffer: CVPixelBuffer, ptsUS: UInt32) {
        guard let session else { return }
        let pts = CMTime(value: CMTimeValue(ptsUS), timescale: 1_000_000)
        var flags: VTEncodeInfoFlags = []
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: nil, infoFlagsOut: &flags
        ) { [weak self] status, _, sampleBuffer in
            guard let self, status == noErr, let sampleBuffer else { return }
            self.handle(sampleBuffer)
        }
    }

    func invalidate() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
    }

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        var keyframe = true
        if let attachments, CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
            let value = CFDictionaryGetValue(
                dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque())
            keyframe = value == nil
        }
        if keyframe || parameterSets.isEmpty {
            parameterSets = Self.parameterSets(from: format)
        }
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(
            dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
            dataPointerOut: &pointer)
        guard let pointer, length > 0 else { return }
        var out = parameterSets
        var offset = 0
        let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
        while offset + 4 <= length {
            let size =
                Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8
                | Int(bytes[offset + 3])
            offset += 4
            guard size > 0, offset + size <= length else { break }
            out.append(contentsOf: [0, 0, 0, 1])
            out.append(contentsOf: UnsafeBufferPointer(start: bytes + offset, count: size))
            offset += size
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsUS = UInt32(max(0, pts.seconds * 1_000_000))
        onFrame?(out, ptsUS, keyframe)
    }

    private static func parameterSets(from format: CMFormatDescription) -> [UInt8] {
        var out: [UInt8] = []
        let count = CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC
            ? hevcParameterSetCount(format) : h264ParameterSetCount(format)
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            var headerLength: Int32 = 0
            let status: OSStatus
            if CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC {
                status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: &headerLength)
            } else {
                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: &headerLength)
            }
            guard status == noErr, let pointer else { continue }
            out.append(contentsOf: [0, 0, 0, 1])
            out.append(contentsOf: UnsafeBufferPointer(start: pointer, count: size))
        }
        return out
    }

    private static func h264ParameterSetCount(_ format: CMFormatDescription) -> Int {
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        return count
    }

    private static func hevcParameterSetCount(_ format: CMFormatDescription) -> Int {
        var count = 0
        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        return count
    }
}
