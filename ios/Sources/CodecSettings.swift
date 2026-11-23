// The codec choices a person can make in settings. "Auto" means the hardware order; anything else
// moves that codec to the front of what this device advertises or asks for.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum VideoPreference: String, CaseIterable, Identifiable {
    case auto
    case hevc
    case avc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .hevc: return "HEVC"
        case .avc: return "H.264"
        }
    }

    /// The MIME this choice asks for, or nil for the hardware order.
    var codec: String? {
        switch self {
        case .auto: return nil
        case .hevc: return "video/hevc"
        case .avc: return "video/avc"
        }
    }

    /// Only the codecs this device actually has.
    static var available: [VideoPreference] {
        var list: [VideoPreference] = [.auto]
        for codec in DeviceCapabilities.videoDecoders {
            switch codec {
            case "video/hevc": list.append(.hevc)
            case "video/avc": list.append(.avc)
            default: break
            }
        }
        return list
    }
}

enum AudioPreference: String, CaseIterable, Identifiable {
    case auto
    case pcm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .pcm: return "PCM"
        }
    }

    /// The audio codecs to advertise, best first.
    var codecs: [String] {
        switch self {
        case .auto: return DeviceCapabilities.audio
        case .pcm: return ["audio/pcm"]
        }
    }
}

/// Where the choices live. Read by the receiver when it starts and by the home screen's chips.
enum CodecSettings {
    private static let videoKey = "codec.video"
    private static let audioKey = "codec.audio"

    static var video: VideoPreference {
        get { VideoPreference(rawValue: UserDefaults.standard.string(forKey: videoKey) ?? "") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: videoKey) }
    }

    static var audio: AudioPreference {
        get { AudioPreference(rawValue: UserDefaults.standard.string(forKey: audioKey) ?? "") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: audioKey) }
    }
}
