// Measures how fast this device decodes, the way the Android client's Bench does: real frames at
// 1080p60 through the same low-latency path a session uses. The result goes to the senders in
// "welcome" so they pick the codec this phone actually handles best.
// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

enum DecoderBench {
    /// The picture size the sender cares about; a smaller one would flatter the result.
    private static let width = 1920
    private static let height = 1080
    private static let frameCount = 40
    /// The first frames include the decoder warming up; they are not counted.
    private static let warmup = 5

    private static let lock = NSLock()
    private static var running = false

    /// Runs the measurement off the main thread and stores the result. Skips when it is already
    /// running; the caller decides when the device is idle.
    static func runIfNeeded() {
        lock.lock()
        let alreadyMeasured =
            UserDefaults.standard.double(forKey: "decode.video/hevc") > 0
            || UserDefaults.standard.double(forKey: "decode.video/avc") > 0
        if running || alreadyMeasured {
            lock.unlock()
            return
        }
        running = true
        lock.unlock()

        Task.detached(priority: .utility) {
            defer {
                lock.lock()
                running = false
                lock.unlock()
            }
            for mime in ["video/hevc", "video/avc"] where DeviceCapabilities.videoDecoders.contains(mime) {
                if let ms = measure(mime: mime) {
                    UserDefaults.standard.set(ms, forKey: "decode.\(mime)")
                }
            }
        }
    }

    /// Encodes a few frames with the matching encoder, then decodes them back and times the decode.
    private static func measure(mime: String) -> Double? {
        let codec: CMVideoCodecType =
            mime == "video/hevc" ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        guard let frames = encodeFrames(codec: codec), !frames.isEmpty else { return nil }
        guard let format = frames.first?.format else { return nil }

        var session: VTDecompressionSession?
        let created = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: nil, imageBufferAttributes: nil,
            outputCallback: nil, decompressionSessionOut: &session)
        guard created == noErr, let session else { return nil }
        defer { VTDecompressionSessionInvalidate(session) }
        VTSessionSetProperty(
            session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        var times: [Double] = []
        for (index, frame) in frames.enumerated() {
            let start = DispatchTime.now().uptimeNanoseconds
            var flagsOut = VTDecodeInfoFlags()
            let status = VTDecompressionSessionDecodeFrame(
                session, sampleBuffer: frame.sample, flags: [._1xRealTimePlayback],
                infoFlagsOut: &flagsOut
            ) { _, _, _, _, _ in }
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            guard status == noErr else { return nil }
            if index >= warmup {
                times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
        }
        guard !times.isEmpty else { return nil }
        let average = times.reduce(0, +) / Double(times.count)
        // A decoder that "takes" hundreds of milliseconds is an artifact, not a measurement.
        guard average > 0, average < 100 else { return nil }
        return (average * 10).rounded() / 10
    }

    private struct Frame {
        let sample: CMSampleBuffer
        let format: CMFormatDescription
    }

    private static func encodeFrames(codec: CMVideoCodecType) -> [Frame]? {
        var session: VTCompressionSession?
        let created = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
            codecType: codec, encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &session)
        guard created == noErr, let session else { return nil }
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_AverageBitRate, value: 6_000_000 as CFNumber)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)

        var frames: [Frame] = []
        let lock = NSLock()

        for index in 0..<frameCount {
            guard let buffer = pixelBuffer(seed: index) else { return nil }
            let pts = CMTime(value: CMTimeValue(index), timescale: 60)
            var flags: VTEncodeInfoFlags = []
            VTCompressionSessionEncodeFrame(
                session, imageBuffer: buffer, presentationTimeStamp: pts, duration: .invalid,
                frameProperties: nil, infoFlagsOut: &flags
            ) { status, _, sample in
                guard status == noErr, let sample,
                    let format = CMSampleBufferGetFormatDescription(sample)
                else { return }
                lock.lock()
                frames.append(Frame(sample: sample, format: format))
                lock.unlock()
            }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        lock.lock()
        let result = frames
        lock.unlock()
        return result.count > warmup ? result : nil
    }

    /// A moving picture, so the encoder produces a stream like a screen would, not a still.
    private static func pixelBuffer(seed: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        guard
            CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                attributes as CFDictionary, &buffer) == kCVReturnSuccess,
            let buffer
        else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        for y in stride(from: 0, to: height, by: 4) {
            let row = pixels + y * bytesPerRow
            for x in stride(from: 0, to: width, by: 4) {
                let offset = x * 4
                row[offset] = UInt8((x + seed * 7) & 0xFF)
                row[offset + 1] = UInt8((y + seed * 3) & 0xFF)
                row[offset + 2] = UInt8((seed * 11) & 0xFF)
                row[offset + 3] = 255
            }
        }
        return buffer
    }
}
