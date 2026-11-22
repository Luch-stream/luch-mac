// Raw PCM for the LAN: no codec, no encoder latency, and every client can play it. The frames are
// the same length as Opus ones, so the transport does not care which one it carries.
// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import Foundation
import LuchProto

public final class PcmAudio {
    /// (payload, capture time of the buffer this frame came from).
    public var onPacket: ((Data, CMTime) -> Void)?

    public let sampleRate: Int = 48_000
    public let channels: Int = 2
    public let frameMs: Int

    private var pending: [Float] = []
    private var warnedFormat = false

    private var frameSamples: Int { sampleRate * frameMs / 1000 }

    public init(frameMs: Int = Proto.audioFrameMs) {
        self.frameMs = frameMs
    }

    public func push(_ sampleBuffer: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
            let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(format)
        else { return }
        let asbd = asbdPointer.pointee
        guard Int(asbd.mSampleRate) == sampleRate, Int(asbd.mChannelsPerFrame) == channels else {
            if !warnedFormat {
                warnedFormat = true
                log("audio: pcm got \(asbd.mSampleRate) Hz x\(asbd.mChannelsPerFrame), skipping")
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
        guard status == noErr else { return }

        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        var samples: [Float]
        if list.count == 1, let data = list[0].mData {
            let bytes = Int(list[0].mDataByteSize)
            if isFloat {
                let count = bytes / MemoryLayout<Float>.size
                samples = Array(
                    UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
            } else {
                let count = bytes / MemoryLayout<Int16>.size
                let ints = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self), count: count)
                samples = ints.map { Float($0) / 32768.0 }
            }
        } else {
            // Non-interleaved: one buffer per channel, left then right.
            var left = [Float](repeating: 0, count: frames)
            var right = [Float](repeating: 0, count: frames)
            for (channel, buffer) in list.enumerated() {
                guard let data = buffer.mData else { continue }
                let count = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
                let values = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)
                for index in 0..<count {
                    if channel == 0 { left[index] = values[index] } else { right[index] = values[index] }
                }
            }
            samples = [Float](repeating: 0, count: frames * channels)
            for index in 0..<frames {
                samples[index * channels] = left[index]
                samples[index * channels + 1] = right[index]
            }
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        pending.append(contentsOf: samples)
        let frameLength = frameSamples * channels
        while pending.count >= frameLength {
            let chunk = Array(pending.prefix(frameLength))
            pending.removeFirst(frameLength)
            var data = Data(capacity: frameLength * 2)
            for sample in chunk {
                let clamped = max(-1, min(1, sample))
                var value = Int16(clamped * 32767).littleEndian
                withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
            }
            onPacket?(data, pts)
        }
    }
}
