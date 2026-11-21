// VideoToolbox encoder for H.264 and HEVC, plus the AVCC -> Annex-B conversion the receiver needs:
// parameter sets live in the format description, so they must be stamped in front of every IRAP.
// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import CoreVideo
import Foundation
import LuchProto
import VideoToolbox

public enum VideoCodec: String, CaseIterable {
    case h264 = "video/avc"
    case hevc = "video/hevc"

    public var cmType: CMVideoCodecType {
        switch self {
        case .h264: return CMVideoCodecType(kCMVideoCodecType_H264)
        case .hevc: return CMVideoCodecType(kCMVideoCodecType_HEVC)
        }
    }

    public var label: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        }
    }

    /// HEVC NAL unit type lives in the top 6 bits of the first header byte; H.264 in the low 5.
    public func nalType(_ nal: Data) -> UInt8? {
        guard let first = nal.first else { return nil }
        switch self {
        case .h264: return first & 0x1f
        case .hevc: return (first >> 1) & 0x3f
        }
    }

    public func isIRAP(_ nal: Data) -> Bool {
        guard let type = nalType(nal) else { return false }
        switch self {
        case .h264: return type == 5
        // BLA_W_LP 16 ... CRA 21; IDR_W_RADL 19 and IDR_N_LP 20 are what VideoToolbox emits.
        case .hevc: return (16...21).contains(type)
        }
    }
}

public enum VideoProfile: String {
    case baseline, main, high
}

public final class VideoEncoder {
    /// Called with one Annex-B access unit: (data, isIRAP, pts).
    public var onPacket: ((Data, Bool, CMTime) -> Void)?

    public let codec: VideoCodec
    private let width: Int
    private let height: Int
    private var session: VTCompressionSession?
    private var paramSets: [Data] = []
    private var nalLengthSize: Int32 = 4
    private var packets = 0

    /// Is there a hardware (or any) encoder for this codec at this size on this machine?
    public static func supports(_ codec: VideoCodec, width: Int, height: Int) -> Bool {
        var encoderID: CFString?
        var properties: CFDictionary?
        let status = VTCopySupportedPropertyDictionaryForEncoder(
            width: Int32(width), height: Int32(height), codecType: codec.cmType,
            encoderSpecification: nil, encoderIDOut: &encoderID, supportedPropertiesOut: &properties)
        return status == noErr
    }

    /// Hardware decode for this codec on this machine (AV1 on M4 is decode-only, VP9 is software).
    public static func hardwareDecodeSupported(_ codec: VideoCodec) -> Bool {
        VTIsHardwareDecodeSupported(codec.cmType)
    }

    public init?(codec: VideoCodec, width: Int, height: Int, fps: Int, kbps: Int, profile: VideoProfile? = nil) {
        self.codec = codec
        self.width = width
        self.height = height

        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]

        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width), height: Int32(height),
            codecType: codec.cmType,
            encoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created)
        guard status == noErr, let session = created else {
            log("encoder: VTCompressionSessionCreate(\(codec.label)) failed: \(status)")
            return nil
        }
        self.session = session

        // Sunshine-style low-latency settings, as close as VideoToolbox exposes them.
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 600 as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 600 as CFNumber)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        set(kVTCompressionPropertyKey_AverageBitRate, (kbps * 1000) as CFNumber)
        // [bytes per second, seconds]; VideoToolbox has no one-frame VBV, this is the closest control.
        set(kVTCompressionPropertyKey_DataRateLimits, [kbps * 125, 1] as CFArray)
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)

        switch codec {
        case .h264:
            set(kVTCompressionPropertyKey_AllowOpenGOP, kCFBooleanFalse)
            let level: CFString
            switch profile ?? .high {
            case .baseline: level = kVTProfileLevel_H264_Baseline_AutoLevel
            case .main: level = kVTProfileLevel_H264_Main_AutoLevel
            case .high: level = kVTProfileLevel_H264_High_AutoLevel
            }
            set(kVTCompressionPropertyKey_ProfileLevel, level)
            log("encoder: H.264 \(profile?.rawValue ?? "high") \(width)x\(height)@\(fps) \(kbps) kbps")
        case .hevc:
            set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
            log("encoder: HEVC main \(width)x\(height)@\(fps) \(kbps) kbps")
        }

        let prepared = VTCompressionSessionPrepareToEncodeFrames(session)
        if prepared != noErr {
            log("encoder: prepare failed: \(prepared)")
            return nil
        }
    }

    deinit {
        if let session { VTCompressionSessionInvalidate(session) }
    }

    private func set(_ key: CFString, _ value: CFTypeRef?) {
        guard let session, let value else { return }
        let status = VTSessionSetProperty(session, key: key, value: value)
        if status != noErr {
            log("encoder: set \(key) failed: \(status)")
        }
    }

    public func encode(_ buffer: CVPixelBuffer, pts: CMTime, forceIDR: Bool) {
        guard let session else { return }
        var props: [CFString: Any] = [:]
        if forceIDR {
            props[kVTEncodeFrameOptionKey_ForceKeyFrame] = true
        }
        var flagsOut = VTEncodeInfoFlags()
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: buffer, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: props.isEmpty ? nil : (props as CFDictionary), infoFlagsOut: &flagsOut
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else { return }
            self?.emit(sampleBuffer)
        }
        if status != noErr {
            log("encoder: encode failed: \(status)")
        }
    }

    private func emit(_ sampleBuffer: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        if paramSets.isEmpty {
            extractParameterSets(format)
        }
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return }
        var avcc = Data(count: length)
        let copyStatus = avcc.withUnsafeMutableBytes { raw -> OSStatus in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            log("encoder: block copy failed: \(copyStatus)")
            return
        }

        // VideoToolbox does not always attach kCMSampleAttachmentKey_NotSync, so take the truth from the
        // bitstream itself: an access unit that contains an IRAP NAL is a key frame.
        let nals = Self.nalUnits(avcc, nalLengthSize: nalLengthSize)
        let isIRAP = nals.contains { codec.isIRAP($0) }
        let annexB = Self.annexB(nals: nals, paramSets: paramSets, isIDR: isIRAP)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        packets += 1
        if isIRAP {
            log("encoder: \(codec.label) key frame #\(packets) \(annexB.count) bytes, parameter sets \(paramSets.count)")
        }
        onPacket?(annexB, isIRAP, pts)
    }

    private func extractParameterSets(_ format: CMFormatDescription) {
        var count = 0
        let first: OSStatus
        switch codec {
        case .h264:
            first = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLengthSize)
        case .hevc:
            first = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLengthSize)
        }
        guard first == noErr, count > 0 else {
            log("encoder: no \(codec.label) parameter sets (\(first))")
            return
        }
        for i in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status: OSStatus
            switch codec {
            case .h264:
                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: i, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            case .hevc:
                status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: i, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            }
            if status == noErr, let pointer, size > 0 {
                paramSets.append(Data(bytes: pointer, count: size))
            }
        }
        log("encoder: \(codec.label) parameter sets: \(paramSets.map { $0.count }) bytes, NAL length size \(nalLengthSize)")
    }

    /// Splits a length-prefixed (AVCC) buffer into raw NAL units.
    public static func nalUnits(_ avcc: Data, nalLengthSize: Int32) -> [Data] {
        let prefix = max(1, Int(nalLengthSize))
        let bytes = [UInt8](avcc)
        var out: [Data] = []
        var i = 0
        while i + prefix <= bytes.count {
            var length = 0
            for k in 0..<prefix {
                length = (length << 8) | Int(bytes[i + k])
            }
            i += prefix
            guard length > 0, i + length <= bytes.count else { break }
            out.append(Data(bytes[i..<(i + length)]))
            i += length
        }
        return out
    }

    /// Writes Annex-B start codes and prepends the parameter sets before an IRAP (the receiver
    /// configures its decoder without csd-0, so VPS/SPS/PPS or SPS/PPS must travel in-band).
    public static func annexB(nals: [Data], paramSets: [Data], isIDR: Bool) -> Data {
        let startCode: [UInt8] = [0, 0, 0, 1]
        var out = Data(capacity: 64 + nals.reduce(0) { $0 + $1.count + 4 })
        if isIDR {
            for ps in paramSets {
                out.append(contentsOf: startCode)
                out.append(ps)
            }
        }
        for nal in nals where !nal.isEmpty {
            out.append(contentsOf: startCode)
            out.append(nal)
        }
        return out
    }

    public static func annexB(_ avcc: Data, nalLengthSize: Int32, paramSets: [Data], isIDR: Bool) -> Data {
        annexB(nals: nalUnits(avcc, nalLengthSize: nalLengthSize), paramSets: paramSets, isIDR: isIDR)
    }

    public var parameterSetCount: Int { paramSets.count }
}
