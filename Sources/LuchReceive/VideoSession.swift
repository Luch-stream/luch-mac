// The receiving half of a mirror session: two UDP sockets, shard reassembly, and one sample buffer per
// access unit. The display layer does the decoding.
// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import Foundation
import LuchProto

public protocol VideoSink: AnyObject {
    func enqueue(_ sample: CMSampleBuffer)
    /// The picture is broken: flush and wait for a keyframe.
    func flush()
}

public final class VideoSession {
    public let videoPort: UInt16
    public let audioPort: UInt16
    public private(set) var decoderName = "VideoToolbox"

    public var onNeedsKeyframe: (() -> Void)?

    private let sink: VideoSink
    private let width: Int
    private let height: Int
    private let fps: Int
    private let codec: AnnexB.Codec
    /// The MIME type this session decodes, for the benchmark memory.
    public var codecMime: String { codec == .hevc ? "video/hevc" : "video/avc" }

    private var videoFD: Int32 = -1
    private var audioFD: Int32 = -1
    /// The audio socket, handed to the audio session so it can read it.
    var audioSocket: Int32 { audioFD }
    private var running = true

    private let decoder = VideoDecoder()
    private var format: CMVideoFormatDescription?
    private var lastParameterSets: [[UInt8]] = []
    private var needKeyframe = true

    private var buffer: [UInt8] = []
    private var frameSeq: UInt32 = 0
    private var frameLen = 0
    private var expectedShards = 0
    private var gotShards = 0
    private var frameIsIDR = false
    private var frameStart: UInt64 = 0

    private let lock = NSLock()
    private var framesIn = 0
    private var lostCount = 0
    private var droppedCount = 0
    private var decodeMsSum: Double = 0
    private var decodeSamples = 0
    private var datagrams = 0
    private var completed = 0

    public init(width: Int, height: Int, fps: Int, codec: AnnexB.Codec, sink: VideoSink) throws {
        self.width = width
        self.height = height
        self.fps = fps
        self.codec = codec
        self.sink = sink
        let video = try VideoSession.openSocket()
        self.videoFD = video.fd
        self.videoPort = video.port
        let audio = try Self.openSocket()
        self.audioFD = audio.fd
        self.audioPort = audio.port
        decoder.onDecoded = { [weak self] image in self?.sink.enqueue(image) }
        decoder.onDecodeTime = { [weak self] ms in
            guard let self, ms >= 0 else { return }
            self.lock.lock()
            self.decodeMsSum += ms
            self.decodeSamples += 1
            self.lock.unlock()
        }
    }

    public struct Stats {
        public var decodeMs: Double
        public var fps: Double
        public var lost: Int
        public var dropped: Int
        public var decoder: String
    }

    /// Counters for the last second, then reset, so the sender sees the live picture.
    public func takeStats() -> Stats {
        lock.lock()
        let frames = framesIn
        let sum = decodeMsSum
        let samples = decodeSamples
        let lost = lostCount
        let dropped = droppedCount
        framesIn = 0
        lostCount = 0
        droppedCount = 0
        decodeMsSum = 0
        decodeSamples = 0
        lock.unlock()
        let ms = samples > 0 ? sum / Double(samples) : 0
        return Stats(decodeMs: ms, fps: Double(frames), lost: lost, dropped: dropped, decoder: decoderName)
    }

    public func start() {
        onNeedsKeyframe?()  // the sender should start with an IDR
        Thread.detachNewThread { [weak self] in self?.readLoop() }
    }

    public func stop() {
        running = false
        decoder.reset()
        if videoFD >= 0 {
            close(videoFD)
            videoFD = -1
        }
        if audioFD >= 0 {
            close(audioFD)
            audioFD = -1
        }
    }

    // MARK: - sockets

    private static func openSocket() throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var size: Int32 = 4 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        // Fixed ports, as the Linux receiver does, so a firewall can be opened for them; the
        // numbers are a preference, an ephemeral port is still the fallback.
        var ports: [UInt16] = [0]
        if ProcessInfo.processInfo.environment["LUCH_FIXED_MEDIA_PORTS"] == "1" {
            ports = [47802, 47803, 0]
        }
        var bound: Int32 = -1
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_ANY
        for port in ports {
            addr.sin_port = port.bigEndian
            bound = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bound == 0 { break }
        }
        guard bound == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            close(fd)
            throw POSIXError(.EIO)
        }
        return (fd, actual.sin_port.bigEndian)
    }

    // MARK: - receive

    private func readLoop() {
        var datagram = [UInt8](repeating: 0, count: 64 * 1024)
        while running, videoFD >= 0 {
            let n = datagram.withUnsafeMutableBytes { raw in
                recv(videoFD, raw.baseAddress, raw.count, 0)
            }
            if n <= 0 {
                if !running { break }
                continue
            }
            handle(datagram, count: n)
        }
    }

    private func handle(_ bytes: [UInt8], count: Int) {
        guard count > Proto.headerSize else { return }
        guard bytes[0] == MediaKind.video.rawValue else { return }
        let flags = PacketFlags(rawValue: bytes[1])
        let shard = Int(bytes.be16(2))
        let shards = Int(bytes.be16(4))
        let seq = bytes.be32(8)
        let length = Int(bytes.be32(16))
        let payload = bytes[Proto.headerSize..<count]

        if shard == 0 {
            if !buffer.isEmpty { incomplete() }
            buffer = Array(payload)
            frameSeq = seq
            frameLen = length
            expectedShards = max(1, shards)
            gotShards = 1
            frameIsIDR = flags.contains(.idr)
            frameStart = DispatchTime.now().uptimeNanoseconds
        } else if !buffer.isEmpty, seq == frameSeq {
            buffer.append(contentsOf: payload)
            gotShards += 1
        } else {
            return
        }
        if !buffer.isEmpty, gotShards >= expectedShards || buffer.count >= frameLen {
            complete()
        }
    }

    private func incomplete() {
        lock.lock()
        lostCount += 1
        lock.unlock()
        buffer = []
        if !needKeyframe {
            needKeyframe = true
            sink.flush()
            onNeedsKeyframe?()
        }
    }

    private func complete() {
        let data = buffer
        buffer = []
        let isIDR = frameIsIDR
        let started = frameStart
        if needKeyframe && !isIDR {
            lock.lock()
            droppedCount += 1
            lock.unlock()

            return
        }
        let (sample, sets) = AnnexB.avcc(data, codec: codec)
        if !sets.isEmpty, sets != lastParameterSets {
            if let description = AnnexB.formatDescription(codec: codec, parameterSets: sets) {
                format = description
                lastParameterSets = sets
            }
        }
        guard let format,
            let sampleBuffer = AnnexB.sampleBuffer(
                sample, format: format,
                pts: CMTime(
                    value: CMTimeValue(DispatchTime.now().uptimeNanoseconds / 1000),
                    timescale: 1_000_000),
                timescale: CMTimeScale(max(1, fps)))
        else {
            lock.lock()
            droppedCount += 1
            lock.unlock()
            return
        }
        decoder.decode(sampleBuffer, format: format)
        completed += 1
        needKeyframe = false
        lock.lock()
        framesIn += 1
        lock.unlock()
    }
}

extension Array where Element == UInt8 {
    public func be16(_ offset: Int) -> UInt16 {
        (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    public func be32(_ offset: Int) -> UInt32 {
        (UInt32(self[offset]) << 24) | (UInt32(self[offset + 1]) << 16)
            | (UInt32(self[offset + 2]) << 8) | UInt32(self[offset + 3])
    }
}
