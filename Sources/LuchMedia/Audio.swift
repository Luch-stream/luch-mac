// System audio -> Opus: ScreenCaptureKit hands out float PCM in buffers of arbitrary length, the
// receiver wants one Opus packet per datagram with 5 ms frames. The ring buffer cuts exactly 240
// samples (48 kHz, stereo) and `OpusHead` carries the encoder's real pre-skip.
// SPDX-License-Identifier: GPL-3.0-or-later
import COpus
import Darwin
import CoreMedia
import Foundation
import LuchProto

public final class OpusAudio {
    /// (packet, capture time of the buffer this frame came from).
    public var onPacket: ((Data, CMTime) -> Void)?

    private var encoder: OpaquePointer?
    private var pending: [Float] = []
    private var framesEmitted: UInt64 = 0
    private var warnedFormat = false
    private var loggedFormat = false
    private var rmsSum: Double = 0
    private var rmsCount = 0
    public private(set) var preSkip: UInt16 = 312

    public let sampleRate: Int = 48_000
    public let channels: Int = 2
    public let frameMs: Int

    private var frameSamples: Int { sampleRate * frameMs / 1000 } // 240

    public init?(bitrate: Int = Proto.audioBps, frameMs: Int = Proto.audioFrameMs) {
        self.frameMs = frameMs
        var error: Int32 = 0
        guard let enc = opus_encoder_create(Int32(sampleRate), Int32(channels),
                                            Int32(OPUS_APPLICATION_RESTRICTED_LOWDELAY), &error) else {
            log("audio: opus_encoder_create failed: \(error)")
            return nil
        }
        self.encoder = enc
        _ = luch_opus_set_bitrate(enc, Int32(bitrate))
        _ = luch_opus_set_vbr(enc, 0)
        var lookahead: Int32 = 0
        _ = luch_opus_lookahead(enc, &lookahead)
        preSkip = UInt16(max(0, min(Int32(UInt16.max), lookahead)))
        log("audio: Opus \(sampleRate) Hz x\(channels), \(frameMs) ms frames, \(bitrate) bps CBR, pre-skip \(preSkip)")
    }

    deinit {
        if let encoder { opus_encoder_destroy(encoder) }
    }

    public var head: Data { Data(Proto.opusHead(preSkip: preSkip)) }

    /// Feeds one ScreenCaptureKit audio buffer.
    public func push(_ sampleBuffer: CMSampleBuffer) {
        guard encoder != nil, let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(format) else { return }
        let asbd = asbdPointer.pointee
        guard Int(asbd.mSampleRate) == sampleRate, Int(asbd.mChannelsPerFrame) == channels else {
            if !warnedFormat {
                warnedFormat = true
                log("audio: unexpected format \(asbd.mSampleRate) Hz x\(asbd.mChannelsPerFrame), skipping")
            }
            return
        }

        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return }
        let list = AudioBufferList.allocate(maximumBuffers: channels)
        defer { free(list.unsafeMutablePointer) }
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: channels),
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block)
        guard status == noErr else {
            log("audio: AudioBufferList failed: \(status)")
            return
        }

        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let packed = asbd.mFormatFlags & kAudioFormatFlagIsPacked != 0
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        if !loggedFormat {
            loggedFormat = true
            log("audio: fmt float=\(isFloat) packed=\(packed) noninterleaved=\(nonInterleaved) " +
                "bytesPerFrame=\(asbd.mBytesPerFrame) framesPerPacket=\(asbd.mFramesPerPacket) " +
                "buffers=\(list.count) ch=\(asbd.mChannelsPerFrame) rate=\(asbd.mSampleRate)")
        }
        guard let samples = interleaved(list, isFloat: isFloat, frames: frames) else { return }
        var sum = 0.0
        for sample in samples { sum += Double(sample * sample) }
        rmsSum += (samples.isEmpty ? 0 : (sum / Double(samples.count)).squareRoot())
        rmsCount += 1
        if rmsCount >= 100 {
            let rms = rmsSum / Double(rmsCount)
            log(String(format: "audio: rms %.3f (%.1f dBFS)", rms, 20 * log10(max(1e-6, rms))))
            rmsSum = 0
            rmsCount = 0
        }
        emit(samples, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    /// Cuts interleaved float samples into 5 ms packets. Exposed for tests.
    @discardableResult
    public func emit(_ samples: [Float], pts: CMTime) -> [Data] {
        guard let encoder else { return [] }
        pending.append(contentsOf: samples)
        var out: [Data] = []
        let need = frameSamples * channels
        var buffer = [UInt8](repeating: 0, count: 4000)
        while pending.count >= need {
            let written = pending.withUnsafeBufferPointer { pointer -> Int32 in
                buffer.withUnsafeMutableBufferPointer { dst in
                    guard let src = pointer.baseAddress, let out = dst.baseAddress else { return -1 }
                    return opus_encode_float(encoder, src, Int32(frameSamples), out, Int32(dst.count))
                }
            }
            pending.removeFirst(need)
            guard written > 0 else {
                log("audio: opus_encode_float failed: \(written)")
                continue
            }
            let packet = Data(buffer[0..<Int(written)])
            let framePTS = CMTimeAdd(pts, CMTime(value: CMTimeValue(framesEmitted * UInt64(frameMs)), timescale: 1000))
            framesEmitted += 1
            out.append(packet)
            onPacket?(packet, framePTS)
        }
        return out
    }

    private func interleaved(_ list: UnsafeMutableAudioBufferListPointer, isFloat: Bool, frames: Int) -> [Float]? {
        // Interleaved: one buffer with `channels` channels. Non-interleaved: one buffer per channel.
        if list.count == 1 {
            let buffer = list[0]
            guard let data = buffer.mData else { return nil }
            if isFloat {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
            }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
            let ints = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self), count: count)
            return ints.map { Float($0) / 32768.0 }
        }
        guard list.count >= channels, isFloat else {
            if !warnedFormat {
                warnedFormat = true
                log("audio: unsupported layout (\(list.count) buffers, float=\(isFloat))")
            }
            return nil
        }
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        for channel in 0..<channels {
            let buffer = list[channel]
            guard let data = buffer.mData else { return nil }
            let count = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
            let pointer = data.assumingMemoryBound(to: Float.self)
            for i in 0..<count {
                if channel == 0 { left[i] = pointer[i] } else { right[i] = pointer[i] }
            }
        }
        var out = [Float](repeating: 0, count: frames * channels)
        for i in 0..<frames {
            out[i * channels] = left[i]
            out[i * channels + 1] = right[i]
        }
        return out
    }
}
