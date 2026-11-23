// The sender side of the protocol for iOS: discover a receiver, greet it, agree on the stream, and
// push datagrams. It is the same conversation luchd has, just with ReplayKit frames behind it.
// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import LuchProto

/// A receiver the phone can mirror to.
struct SendTarget: Identifiable, Equatable {
    let id: String
    let name: String
    let host: String
    let port: UInt16
    let model: String
}

final class SendSession: @unchecked Sendable {
    enum State: Equatable {
        case idle
        case connecting
        case waiting
        case streaming
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var stats: String = ""
    private(set) var target: SendTarget?

    var onState: ((State) -> Void)?

    /// Frames come from the encoder thread, commands from the UI; one lock keeps the sockets and
    /// the sequence counter sane without putting media on the main actor.
    private let lock = NSLock()
    private var control: Int32 = -1
    private var videoSocket: Int32 = -1
    private var audioSocket: Int32 = -1
    private var videoPort: UInt16 = 0
    private var audioPort: UInt16 = 0
    private var seq: UInt32 = 0
    private var readSource: DispatchSourceRead?
    private var lineBuffer = Data()

    var isStreaming: Bool { state == .streaming }

    // MARK: - handshake

    func start(to target: SendTarget, name: String, width: Int, height: Int, fps: Int) {
        lock.lock()
        defer { lock.unlock() }
        stopLocked()
        self.target = target
        set(.connecting)

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return fail("socket") }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = target.port.bigEndian
        guard inet_pton(AF_INET, target.host, &addr.sin_addr) == 1 else {
            close(fd)
            return fail("bad address \(target.host)")
        }
        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            return fail("cannot connect \(target.host):\(target.port)")
        }
        control = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.readOnce() }
        source.resume()
        readSource = source

        send([
            "t": "hello", "v": 0, "id": sendID, "name": name, "app": "luch-ios/0.1",
            "want": ["mirror"],
        ])
        pendingStart = (width, height, fps)
    }

    private var pendingStart: (width: Int, height: Int, fps: Int)?
    private let sendID = UUID().uuidString

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopLocked()
    }

    private func stopLocked() {
        if control >= 0 {
            send(["t": "stop"])
            send(["t": "bye"])
            close(control)
            control = -1
        }
        readSource?.cancel()
        readSource = nil
        if videoSocket >= 0 { close(videoSocket) }
        if audioSocket >= 0 { close(audioSocket) }
        videoSocket = -1
        audioSocket = -1
        lineBuffer.removeAll()
        pendingStart = nil
        set(.idle)
    }

    // MARK: - control channel

    private func readOnce() {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let count = recv(control, &buffer, buffer.count, 0)
        guard count > 0 else {
            stop()
            return
        }
        lineBuffer.append(contentsOf: buffer[0..<count])
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let line = lineBuffer[..<newline]
            lineBuffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { continue }
            handle(object)
        }
    }

    private func handle(_ message: [String: Any]) {
        switch message["t"] as? String {
        case "welcome":
            // Both codecs come from what the receiver says it can do — never from a constant:
            // its decoder list and its preferred codec, narrowed to what this encoder can produce.
            let decoders = message["decoders"] as? [String] ?? []
            negotiatedVideo = CodecChoice.video(from: message)
            let hw = message["hw"] as? [String: Any]
            let audioCodecs = hw?["audio"] as? [String] ?? []
            wantsAudio = audioCodecs.contains("audio/pcm") || decoders.contains("audio/pcm")
            if let start = pendingStart {
                var startMessage: [String: Any] = [
                    "t": "start", "mode": "mirror",
                    "video": [
                        "codec": negotiatedVideo == .avc ? "video/avc" : "video/hevc",
                        "width": start.width, "height": start.height, "fps": start.fps,
                    ],
                ]
                if wantsAudio {
                    startMessage["audio"] = [
                        "codec": "audio/pcm", "rate": 48_000, "channels": 2, "frame_ms": 5,
                    ]
                }
                send(startMessage)
            }
        case "ready":
            videoPort = UInt16(message["video_port"] as? Int ?? 0)
            audioPort = UInt16(message["audio_port"] as? Int ?? 0)
            guard let target else { return }
            videoSocket = Self.udpSocket(to: target.host, port: videoPort)
            audioSocket = Self.udpSocket(to: target.host, port: audioPort)
            set(.streaming)
        case "keyframe":
            wantKeyframe = true
        case "stop", "bye":
            stop()
        case "stats":
            let fps = message["fps"] as? Int ?? 0
            let decode = message["decode_ms"] as? Double ?? 0
            stats = "\(fps) fps · \(String(format: "%.1f", decode)) мс"
        default:
            break
        }
    }

    private func send(_ object: [String: Any]) {
        guard control >= 0, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        var line = data
        line.append(0x0A)
        _ = line.withUnsafeBytes { write(control, $0.baseAddress, $0.count) }
    }

    // MARK: - media

    /// Set when the receiver asks for a fresh IDR; the encoder reads and clears it.
    var wantKeyframe = false
    /// The receiver accepted PCM audio in its welcome.
    private(set) var wantsAudio = false
    /// The video codec both sides agreed on; the encoder configures itself from this.
    private(set) var negotiatedVideo: ScreenEncoder.Codec = .hevc

    func sendVideo(_ frame: [UInt8], ptsUS: UInt32, keyframe: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard videoSocket >= 0 else { return }
        send(frame: frame, over: videoSocket, kind: .video, ptsUS: ptsUS, keyframe: keyframe)
    }

    func sendAudio(_ frame: [UInt8], ptsUS: UInt32) {
        guard wantsAudio else { return }
        lock.lock()
        defer { lock.unlock() }
        guard audioSocket >= 0 else { return }
        send(frame: frame, over: audioSocket, kind: .audio, ptsUS: ptsUS, keyframe: false)
    }

    private func send(frame: [UInt8], over fd: Int32, kind: MediaKind, ptsUS: UInt32, keyframe: Bool) {
        var flags: PacketFlags = []
        if keyframe { flags.insert(.idr) }
        let shards = Proto.shards(frame)
        for (index, shard) in shards.enumerated() {
            var datagram = Proto.header(
                kind: kind, flags: flags, shard: UInt16(index), shards: UInt16(shards.count),
                seq: seq, ptsUS: ptsUS, frameLen: UInt32(frame.count), hostLat: 0)
            datagram.append(contentsOf: shard)
            _ = datagram.withUnsafeBytes { sendto(fd, $0.baseAddress, $0.count, 0, nil, 0) }
        }
        seq += 1
    }

    private static func udpSocket(to host: String, port: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return -1 }
        // Never block the capture thread: a datagram that cannot go now is dropped, the next one
        // will carry a newer picture anyway.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var size: Int32 = 2 << 20
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            close(fd)
            return -1
        }
        return fd
    }

    // MARK: - state

    private func fail(_ reason: String) {
        stop()
        set(.failed(reason))
    }

    private func set(_ next: State) {
        state = next
        let callback = onState
        DispatchQueue.main.async { callback?(next) }
    }
}
