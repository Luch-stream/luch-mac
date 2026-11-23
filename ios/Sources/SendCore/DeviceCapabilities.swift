// What this device can actually decode and encode, in one place: the receiver advertises these in
// its welcome and the home screen shows them as chips, so the two can never disagree.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import VideoToolbox

enum DeviceCapabilities {
    /// No Opus decoder on this side, so raw PCM is what a sender may send us.
    static let audio = ["audio/pcm"]

    /// Video decoders VideoToolbox runs here, best first.
    static var videoDecoders: [String] {
        var list = ["video/avc"]
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) {
            list.insert("video/hevc", at: 0)
        }
        return list
    }

    /// What the sender half can produce: HEVC when the encoder has it, H.264 otherwise.
    static var videoEncoders: [String] {
        VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
            ? ["video/hevc", "video/avc"] : ["video/avc"]
    }

    /// Short labels for the status chips.
    static func labels(for codecs: [String]) -> [String] {
        codecs.map { codec in
            switch codec {
            case "video/hevc": return "HEVC"
            case "video/avc": return "H.264"
            case "audio/pcm": return "PCM"
            case "audio/opus": return "Opus"
            default: return codec
            }
        }
    }
}
