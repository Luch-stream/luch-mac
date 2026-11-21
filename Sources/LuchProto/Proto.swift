// Luch v0/v1 wire protocol constants and packing (see luch-android/PROTOCOL.md).
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum MediaKind: UInt8 {
    case video = 1
    case audio = 2
}

public struct PacketFlags: OptionSet {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let idr = PacketFlags(rawValue: 1 << 0)
    public static let config = PacketFlags(rawValue: 1 << 1)
    public static let parity = PacketFlags(rawValue: 1 << 2)
}

public enum Proto {
    public static let version: UInt32 = 0
    public static let receiverType = "_luch._tcp"
    public static let senderType = "_luchsrc._tcp"
    public static let controlPort: UInt16 = 47800
    public static let maxLine = 64 * 1024
    public static let headerSize = 24
    public static let shardSize = 1376
    public static let width = 1920
    public static let height = 1080
    public static let fps = 60
    public static let videoKbps = 20_000
    public static let audioBps = 128_000
    public static let audioFrameMs = 5
    public static let app = "luch/0.1 (macos)"

    /// 24-byte big-endian datagram header.
    public static func header(kind: MediaKind, flags: PacketFlags, shard: UInt16, shards: UInt16,
                              seq: UInt32, ptsUS: UInt32, frameLen: UInt32, hostLat: UInt16) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: headerSize)
        h[0] = kind.rawValue
        h[1] = flags.rawValue
        h.putBE16(2, shard)
        h.putBE16(4, shards)
        h.putBE16(6, 0) // parity shards: no FEC yet
        h.putBE32(8, seq)
        h.putBE32(12, ptsUS)
        h.putBE32(16, frameLen)
        h.putBE16(20, hostLat)
        h.putBE16(22, 0)
        return h
    }

    /// Splits one access unit into data shards (the last one is not padded: the receiver cuts to frameLen).
    public static func shards(_ frame: [UInt8], size: Int = shardSize) -> [ArraySlice<UInt8>] {
        guard !frame.isEmpty else { return [] }
        var out: [ArraySlice<UInt8>] = []
        var i = 0
        while i < frame.count {
            let end = min(i + size, frame.count)
            out.append(frame[i..<end])
            i = end
        }
        return out
    }

    /// 19-byte OpusHead (RFC 7845), 48 kHz stereo, as MediaCodec CSD-0 expects it.
    public static func opusHead(preSkip: UInt16 = 312) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: 19)
        h.replaceSubrange(0..<8, with: Array("OpusHead".utf8))
        h[8] = 1 // version
        h[9] = 2 // channels
        let ps = preSkip.littleEndian
        h[10] = UInt8(ps & 0xff)
        h[11] = UInt8(ps >> 8)
        h.putLE32(12, 48_000)
        h.putLE16(16, 0) // output gain
        h[18] = 0        // channel mapping family
        return h
    }
}

extension Array where Element == UInt8 {
    mutating func putBE16(_ at: Int, _ v: UInt16) {
        self[at] = UInt8(truncatingIfNeeded: v >> 8)
        self[at + 1] = UInt8(truncatingIfNeeded: v)
    }

    mutating func putBE32(_ at: Int, _ v: UInt32) {
        self[at] = UInt8(truncatingIfNeeded: v >> 24)
        self[at + 1] = UInt8(truncatingIfNeeded: v >> 16)
        self[at + 2] = UInt8(truncatingIfNeeded: v >> 8)
        self[at + 3] = UInt8(truncatingIfNeeded: v)
    }

    mutating func putLE16(_ at: Int, _ v: UInt16) {
        self[at] = UInt8(truncatingIfNeeded: v)
        self[at + 1] = UInt8(truncatingIfNeeded: v >> 8)
    }

    mutating func putLE32(_ at: Int, _ v: UInt32) {
        self[at] = UInt8(truncatingIfNeeded: v)
        self[at + 1] = UInt8(truncatingIfNeeded: v >> 8)
        self[at + 2] = UInt8(truncatingIfNeeded: v >> 16)
        self[at + 3] = UInt8(truncatingIfNeeded: v >> 24)
    }

    func be16(_ at: Int) -> UInt16 {
        UInt16(self[at]) << 8 | UInt16(self[at + 1])
    }

    func be32(_ at: Int) -> UInt32 {
        UInt32(self[at]) << 24 | UInt32(self[at + 1]) << 16 | UInt32(self[at + 2]) << 8 | UInt32(self[at + 3])
    }
}
