// UDP media sender: 24-byte header, 1376-byte shards, socket pinned to the discovery interface,
// DSCP marking, and a short pause every 16 shards so a large IDR does not overflow the Wi-Fi queue.
// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import LuchProto

public final class UdpSender {
    public let kind: MediaKind
    private let fd: Int32
    private let lock = NSLock()
    private var seq: UInt32 = 0
    private var bytesSent: UInt64 = 0
    private var framesSent: UInt64 = 0
    private var latencySum: UInt64 = 0
    private var warned = false

    public struct Snapshot {
        public var frames: UInt64
        public var bytes: UInt64
        public var latencySum: UInt64
    }

    private init(kind: MediaKind, fd: Int32) {
        self.kind = kind
        self.fd = fd
    }

    /// Opens and connects the socket; nil on any failure (details are logged).
    public static func open(kind: MediaKind, ip: String, port: UInt16, interfaceIndex: UInt32, dscp: Int32) -> UdpSender? {
        let label = kind == .video ? "video" : "audio"
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else {
            log("udp \(label): socket() failed: \(errnoString())")
            return nil
        }

        func fail(_ why: String) -> UdpSender? {
            log("udp \(label): \(why)")
            close(s)
            return nil
        }

        var sndbuf: Int32 = 1 << 20
        setsockopt(s, SOL_SOCKET, SO_SNDBUF, &sndbuf, socklen_t(MemoryLayout<Int32>.size))

        if interfaceIndex != 0 {
            var idx = interfaceIndex
            if setsockopt(s, IPPROTO_IP, IP_BOUND_IF, &idx, socklen_t(MemoryLayout<UInt32>.size)) != 0 {
                log("udp \(label): IP_BOUND_IF(\(interfaceIndex)) failed: \(errnoString())")
            }
        }
        // Same marking as Linux: DSCP<<2 in IP_TOS (CS5 video, CS6 audio).
        var tos = dscp << 2
        if setsockopt(s, IPPROTO_IP, IP_TOS, &tos, socklen_t(MemoryLayout<Int32>.size)) != 0 {
            log("udp \(label): IP_TOS(\(tos)) failed: \(errnoString())")
        }

        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &dest.sin_addr) == 1 else {
            return fail("\(ip) is not an IPv4 address")
        }
        let rc = withUnsafePointer(to: &dest) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(s, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 {
            return fail("connect \(ip):\(port) failed: \(errnoString())")
        }
        log("udp \(label): \(ip):\(port) ifindex=\(interfaceIndex) dscp=\(dscp)")
        return UdpSender(kind: kind, fd: s)
    }

    /// Sends one access unit, sharded. Returns the number of datagrams written.
    @discardableResult
    public func send(frame: [UInt8], flags: PacketFlags, ptsUS: UInt32, hostLat: UInt16) -> Int {
        guard !frame.isEmpty else { return 0 }
        let chunks = Proto.shards(frame)
        let shards = UInt16(chunks.count)

        lock.lock()
        let sq = seq
        seq &+= 1
        lock.unlock()

        var packet = [UInt8]()
        packet.reserveCapacity(Proto.headerSize + Proto.shardSize)
        var ok = 0
        for (i, chunk) in chunks.enumerated() {
            // Straight from the encoder thread, like luchd: no queue between encode and send.
            if i > 0 && i % 16 == 0 {
                usleep(250)
            }
            packet.removeAll(keepingCapacity: true)
            packet.append(contentsOf: Proto.header(kind: kind, flags: flags, shard: UInt16(i), shards: shards,
                                                   seq: sq, ptsUS: ptsUS, frameLen: UInt32(frame.count), hostLat: hostLat))
            packet.append(contentsOf: chunk)
            let n = packet.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            if n < 0 {
                if !warned {
                    warned = true
                    log("udp \(kind == .video ? "video" : "audio") send failed: \(errnoString())")
                }
            } else {
                ok += 1
            }
        }

        lock.lock()
        bytesSent &+= UInt64(frame.count)
        framesSent &+= 1
        latencySum &+= UInt64(hostLat)
        lock.unlock()
        return ok
    }

    public func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(frames: framesSent, bytes: bytesSent, latencySum: latencySum)
    }
}
