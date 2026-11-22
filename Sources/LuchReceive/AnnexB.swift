// Annex-B → AVCC and CMFormatDescription from the parameter sets, the reverse of what the sender
// does. AVSampleBufferDisplayLayer decodes compressed samples itself, so no VTDecompressionSession
// is needed here.
// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import Foundation
import VideoToolbox

public enum AnnexB {
    public enum Codec {
        case avc, hevc

        var parameterSetTypes: (vps: Bool, sps: Int, pps: Int) {
            switch self {
            case .avc: return (false, 7, 8)
            case .hevc: return (true, 33, 34)
            }
        }

        func nalType(_ byte: UInt8) -> Int {
            switch self {
            case .avc: return Int(byte & 0x1F)
            case .hevc: return Int((byte >> 1) & 0x3F)
            }
        }
    }

    /// Splits an Annex-B access unit into NAL units, start codes removed and trailing zeros trimmed.
    public static func nalUnits(_ data: [UInt8]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var start: Int?
        var i = 0
        while i + 2 < data.count {
            if data[i] == 0, data[i + 1] == 0, data[i + 2] == 1 {
                if let s = start { append(&out, data, s, i) }
                start = i + 3
                i += 3
            } else {
                i += 1
            }
        }
        if let s = start { append(&out, data, s, data.count) }
        return out
    }

    private static func append(_ out: inout [[UInt8]], _ data: [UInt8], _ start: Int, _ end: Int) {
        var e = end
        while e > start, data[e - 1] == 0 { e -= 1 }
        guard e > start else { return }
        out.append(Array(data[start..<e]))
    }

    /// Turns one access unit into an AVCC sample and collects its parameter sets.
    public static func avcc(_ data: [UInt8], codec: Codec) -> (sample: [UInt8], parameterSets: [[UInt8]]) {
        let nals = nalUnits(data)
        var sample: [UInt8] = []
        sample.reserveCapacity(data.count + nals.count * 4)
        var sets: [[UInt8]] = []
        let types = codec.parameterSetTypes
        for nal in nals {
            guard let first = nal.first else { continue }
            let type = codec.nalType(first)
            if type == types.sps || type == types.pps || (types.vps && type == 32) {
                sets.append(nal)
            }
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { sample.append(contentsOf: $0) }
            sample.append(contentsOf: nal)
        }
        return (sample, sets)
    }

    /// Builds the format description from SPS/PPS (and VPS for HEVC), ordered the way the system wants.
    public static func formatDescription(codec: Codec, parameterSets: [[UInt8]]) -> CMVideoFormatDescription?
    {
        let types = codec.parameterSetTypes
        func pick(_ type: Int) -> [UInt8]? {
            parameterSets.first { $0.first.map { codec.nalType($0) == type } ?? false }
        }
        var ordered: [[UInt8]] = []
        switch codec {
        case .avc:
            guard let sps = pick(types.sps), let pps = pick(types.pps) else { return nil }
            ordered = [sps, pps]
        case .hevc:
            guard let vps = pick(32), let sps = pick(33), let pps = pick(34) else { return nil }
            ordered = [vps, sps, pps]
        }
        // One allocation, so the pointers handed to CoreMedia stay valid for the whole call.
        var flat: [UInt8] = []
        var offsets: [Int] = []
        var sizes: [Int] = []
        for set in ordered {
            offsets.append(flat.count)
            sizes.append(set.count)
            flat.append(contentsOf: set)
        }
        var description: CMVideoFormatDescription?
        let status = flat.withUnsafeBufferPointer { buffer -> OSStatus in
            var pointers: [UnsafePointer<UInt8>] = offsets.map { buffer.baseAddress! + $0 }
            return pointers.withUnsafeBufferPointer { p in
                sizes.withUnsafeBufferPointer { s in
                    switch codec {
                    case .avc:
                        return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault, parameterSetCount: ordered.count,
                            parameterSetPointers: p.baseAddress!, parameterSetSizes: s.baseAddress!,
                            nalUnitHeaderLength: 4, formatDescriptionOut: &description)
                    case .hevc:
                        return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                            allocator: kCFAllocatorDefault, parameterSetCount: ordered.count,
                            parameterSetPointers: p.baseAddress!, parameterSetSizes: s.baseAddress!,
                            nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
                    }
                }
            }
        }
        return status == noErr ? description : nil
    }

    /// Wraps an AVCC sample in a sample buffer that the display layer shows immediately.
    public static func sampleBuffer(
        _ sample: [UInt8], format: CMVideoFormatDescription,
        pts: CMTime, timescale: CMTimeScale
    ) -> CMSampleBuffer? {
        guard !sample.isEmpty else { return nil }
        var block: CMBlockBuffer?
        guard
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: sample.count,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                dataLength: sample.count, flags: 0, blockBufferOut: &block) == noErr, let block
        else { return nil }
        let copied = sample.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: sample.count)
        }
        guard copied == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: timescale),
            presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var size = sample.count
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
            CFArrayGetCount(attachments) > 0
        {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sampleBuffer
    }
}
