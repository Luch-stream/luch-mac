// The macOS receiver: announces itself as `_luch._tcp`, speaks the JSON control channel, and runs one
// mirror session at a time.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import LuchProto
import VideoToolbox
import dnssd

public final class Receiver {
    public let name: String
    public let id: String
    public var accepting = true

    /// Called when a session starts or ends, for the window title and the menu.
    public var onSession: ((String?) -> Void)?
    public var onStats: ((VideoSession.Stats) -> Void)?
    public var onError: ((String) -> Void)?

    private let sink: VideoSink
    private let server: ControlServer

    public init(name: String, sink: VideoSink) {
        self.name = name
        self.id = ReceiveCaps.identifier()
        self.sink = sink
        self.server = ControlServer(name: name, id: id, sink: sink)
        server.owner = self
    }

    public func start() throws {
        try server.start()
    }

    public func stop() {
        server.stop()
    }

    /// The picture broke on our side: ask the sender for a keyframe.
    public func requestKeyframe() {
        server.requestKeyframe()
    }

    func sessionStarted(_ sender: String) { onSession?(sender) }
    func sessionEnded() { onSession?(nil) }
    func failed(_ message: String) { onError?(message) }
}

/// One control connection from a sender.
final class Control {
    let fd: Int32
    private let lock = NSLock()
    var mirroredID: String?

    init(fd: Int32) { self.fd = fd }

    func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            log("viewer: could not serialise \(object.keys)")
            return
        }
        var line = data
        line.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        _ = line.withUnsafeBytes { raw in
            Darwin.send(fd, raw.baseAddress, raw.count, MSG_NOSIGNAL)
        }
    }

    func close() { Darwin.close(fd) }
}

final class ControlServer {
    weak var owner: Receiver?

    private let name: String
    private let id: String
    private let sink: VideoSink
    private var listenFD: Int32 = -1
    private var running = true
    private var session: VideoSession?
    private var audio: AudioSession?
    private var current: Control?
    private var statsThread: Thread?
    private var idleSeconds = 0
    private var askedKeyframe = false
    private var registerRef: DNSServiceRef?

    init(name: String, id: String, sink: VideoSink) {
        self.name = name
        self.id = id
        self.sink = sink
    }

    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = LuchProto.Proto.controlPort.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        var bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 {
            addr.sin_port = 0
            bound = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let port = actual.sin_port.bigEndian
        listenFD = fd
        log("viewer: listening on control port \(port)")
        advertise(port: port)
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        running = false
        endSession()
        if listenFD >= 0 { Darwin.close(listenFD); listenFD = -1 }
        if let ref = registerRef { DNSServiceRefDeallocate(ref); registerRef = nil }
    }

    // MARK: - discovery

    private func advertise(port: UInt16) {
        var txt: [UInt8] = []
        let entries = ["v=\(LuchProto.Proto.version)", "id=\(id)", "name=\(name)", "model=\(ReceiveCaps.model())",
                       "dec=\(VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) ? "hevc,avc" : "avc")"]
        for entry in entries {
            let bytes = Array(entry.utf8)
            txt.append(UInt8(bytes.count))
            txt.append(contentsOf: bytes)
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let error = txt.withUnsafeBufferPointer { buffer in
            DNSServiceRegister(&registerRef, 0, 0, name, Proto.receiverType, nil, nil,
                               port.bigEndian, UInt16(buffer.count), buffer.baseAddress,
                               { _, flags, err, regName, regType, _, ctx in
                                   let text = regName.map { String(cString: $0) } ?? "?"
                                   let kind = regType.map { String(cString: $0) } ?? "?"
                                   log("viewer: bonjour reply err=\(err) name=\(text) type=\(kind) ctx=\(ctx != nil)")
                               }, context)
        }
        if error != kDNSServiceErr_NoError {
            log("viewer: bonjour register failed: \(error)")
        } else if let ref = registerRef {
            log("viewer: advertised \(Proto.receiverType) as \(name) on port \(port)")
            DispatchQueue.global(qos: .utility).async {
                _ = DNSServiceProcessResult(ref)
            }
        }
    }

    // MARK: - connections

    private func acceptLoop() {
        while running, listenFD >= 0 {
            var addr = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listenFD, $0, &length)
                }
            }
            guard client >= 0 else { continue }
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            let control = Control(fd: client)
            Thread.detachNewThread { [weak self] in self?.serve(control) }
        }
    }

    private func serve(_ control: Control) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while running {
            let n = recv(control.fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            pending.append(contentsOf: buffer[0..<n])
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
                else { continue }
                if !handle(object, control) { control.close(); return }
            }
        }
        if current === control { endSession() }
        control.close()
    }

    /// Returns false when the connection should close.
    private func handle(_ message: [String: Any], _ control: Control) -> Bool {
        switch message["t"] as? String {
        case "hello":
            let sender = message["name"] as? String ?? "sender"
            log("viewer: hello from \(sender)")
            let welcome = ReceiveCaps.welcome(name: name, id: id, accepting: owner?.accepting ?? true)
            log("viewer: welcome with \(welcome["bench"] ?? "no bench")")
            control.send(welcome)
        case "start":
            let video = message["video"] as? [String: Any] ?? [:]
            let codecText = video["codec"] as? String ?? "video/avc"
            let width = (video["width"] as? NSNumber)?.intValue ?? 1920
            let height = (video["height"] as? NSNumber)?.intValue ?? 1080
            let fps = (video["fps"] as? NSNumber)?.intValue ?? 60
            endSession()
            do {
                let session = try VideoSession(width: width, height: height, fps: fps,
                                               codec: codecText == "video/hevc" ? .hevc : .avc, sink: sink)
                session.onNeedsKeyframe = { [weak control] in control?.send(["t": "keyframe"]) }
                self.session = session
                self.current = control
                control.mirroredID = message["mode"] as? String
                control.send(["t": "ready", "video_port": Int(session.videoPort),
                              "audio_port": Int(session.audioPort)])
                session.start()
                if session.audioSocket >= 0 {
                    let audio = AudioSession(fd: session.audioSocket)
                    audio.start()
                    self.audio = audio
                }
                startStats()
                owner?.sessionStarted(senderName(from: control))
                log("viewer: start \(width)x\(height)@\(fps) \(codecText)")
            } catch {
                control.send(["t": "error", "code": "start_failed", "detail": "\(error)"])
                owner?.failed("could not open the media sockets")
                return false
            }
        case "ping":
            control.send(["t": "pong"])
        case "stop":
            if current === control { endSession() }
        case "bye":
            if current === control { endSession() }
            return false
        default:
            break
        }
        return true
    }

    private func senderName(from control: Control) -> String {
        control.mirroredID ?? "sender"
    }

    func requestKeyframe() {
        current?.send(["t": "keyframe"])
    }

    // MARK: - session

    private func startStats() {
        guard statsThread == nil else { return }
        let thread = Thread { [weak self] in
            while self?.running == true, let server = self, server.session != nil {
                Thread.sleep(forTimeInterval: 1)
                guard let session = server.session, let control = server.current else { break }
                let stats = session.takeStats()
                server.owner?.onStats?(stats)

                // Silence watchdog: ask for a keyframe first, give up only after ten quiet seconds.
                if stats.fps == 0 {
                    server.idleSeconds += 1
                    if server.idleSeconds == 5, !server.askedKeyframe {
                        server.askedKeyframe = true
                        control.send(["t": "keyframe"])
                        log("viewer: quiet for 5 s, asked for a keyframe")
                    }
                    if server.idleSeconds >= 10 {
                        log("viewer: the sender went quiet, ending the session")
                        server.endSession()
                        return
                    }
                } else {
                    server.idleSeconds = 0
                    server.askedKeyframe = false
                }
                if stats.fps > 0, stats.decodeMs > 0 {
                    // Remember what this Mac really measured, so the next welcome carries a benchmark.
                    UserDefaults.standard.set(stats.decodeMs, forKey: "decode.\(session.codecMime)")
                }
                control.send(["t": "stats", "decode_ms": (stats.decodeMs * 10).rounded() / 10,
                              "fps": Int(stats.fps), "lost": stats.lost, "dropped": stats.dropped,
                              "decoder": stats.decoder])
            }
            self?.statsThread = nil
        }
        statsThread = thread
        thread.start()
    }

    private func endSession() {
        audio?.stop()
        audio = nil
        session?.stop()
        session = nil
        current = nil
        owner?.sessionEnded()
    }
}

private func log(_ message: String) {
    FileHandle.standardError.write(Data(("[\(Date())] " + message + "\n").utf8))
}
