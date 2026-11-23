// ReplayKit hands audio as CMSampleBuffers of float samples; the wire wants 48 kHz stereo Int16 in
// 5 ms frames, which is what the receivers without an Opus decoder can play.
// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import Foundation

final class PcmFramer {
    /// (payload, pts in microseconds)
    var onFrame: (([UInt8], UInt32) -> Void)?

    private let sampleRate = 48_000
    private let channels = 2
    private let frameMs = 5
    private var pending: [Float] = []

    private var frameSamples: Int { sampleRate * frameMs / 1000 }

    func push(_ sampleBuffer: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
            let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(format)
        else { return }
        let asbd = asbdPointer.pointee
        guard Int(asbd.mSampleRate) == sampleRate, Int(asbd.mChannelsPerFrame) == channels else {
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
        var samples: [Float] = []
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
            var channelsData = [[Float]](repeating: [], count: channels)
            for (channel, buffer) in list.enumerated() where channel < channels {
                guard let data = buffer.mData else { continue }
                if isFloat {
                    let count = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
                    channelsData[channel] = Array(
                        UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
                } else {
                    let count = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size)
                    let ints = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self), count: count)
                    channelsData[channel] = ints.map { Float($0) / 32768.0 }
                }
            }
            for index in 0..<frames {
                for channel in 0..<channels {
                    samples.append(channel < channelsData[channel].count ? channelsData[channel][index] : 0)
                }
            }
        }

        let seconds = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let ptsUS: UInt32 = seconds.isFinite && seconds > 0
            ? UInt32(min(Double(UInt32.max), seconds * 1_000_000)) : 0

        pending.append(contentsOf: samples)
        let length = frameSamples * channels
        while pending.count >= length {
            let chunk = Array(pending.prefix(length))
            pending.removeFirst(length)
            var data = Data(capacity: length * 2)
            for sample in chunk {
                var value = Int16(max(-1, min(1, sample)) * 32767).littleEndian
                withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
            }
            onFrame?([UInt8](data), ptsUS)
        }
    }
}
