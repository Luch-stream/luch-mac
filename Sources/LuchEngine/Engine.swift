// One mirroring session: control handshake, capture, video + audio pipes, keepalive, stats.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreGraphics
import CoreMedia
import Darwin
import Foundation
import LuchMedia
import LuchNet
import LuchProto

public enum CodecChoice: String, CaseIterable {
    case auto, h264, hevc
}

/// A quality preset bundles the stream height (and, later, bitrate and fps) under one name.
/// The size mode picks the aspect ratio; the preset picks how many pixels that aspect gets.
public enum QualityPreset: String, CaseIterable {
    /// Whatever the client itself reports as its render size.
    case auto, low, balanced, high, max

    public var height: Int {
        switch self {
        case .auto: return 1080
        case .low: return 720
        case .balanced: return 1080
        case .high: return 1440
        case .max: return 2160
        }
    }

    /// Shown in the menu and in the plan line.
    public var label: String {
        switch self {
        case .auto: return "Auto · client's screen"
        case .low: return "Low · 720p"
        case .balanced: return "Balanced · 1080p"
        case .high: return "High · 2K"
        case .max: return "Max · 4K"
        }
    }

    public var short: String {
        switch self {
        case .auto: return "auto"
        case .low: return "720p"
        case .balanced: return "1080p"
        case .high: return "2k"
        case .max: return "4k"
        }
    }

    /// Accepts "low", "balanced", "high", "max" and the plain resolution names.
    public static func parse(_ text: String) -> QualityPreset? {
        let key = text.lowercased()
        for preset in allCases where preset.rawValue == key || preset.short == key { return preset }
        if key == "1440p" { return .high }
        if key == "2160p" { return .max }
        return nil
    }
}

/// Whose geometry wins when the client's screen differs from the Mac's.
public enum SizeMode: String, CaseIterable {
    /// The Mac's own panel: the client fits it with bars.
    case source
    /// The client's screen: the Mac crops to its aspect, the picture fills it.
    case client
    /// The Mac's aspect scaled into the client's pixels: no distortion, no wasted pixels.
    case fit
    /// Half-way between the two aspects: less cropping than `client`, fewer bars than `source`.
    case average
}

public struct MirrorOptions {
    public var width = Proto.width
    public var height = Proto.height
    public var fps = Proto.fps
    public var bitrate = Proto.videoKbps
    public var display: Int?
    public var audio = true
    // 20 ms measured best on a real Android receiver: 5 ms and 10 ms crackled because the
    // receiver's AudioTrack buffer (~4 frames) underruns on Wi-Fi jitter.
    public var audioFrameMs = 20
    public var codec: CodecChoice = .auto
    public var fit: FitMode = .crop
    public var profile: VideoProfile?
    public var weights = CodecWeights()
    public var sizeMode: SizeMode = .fit
    public var preset: QualityPreset = .auto
    /// `--size WxH` on the command line overrides the quality preset.
    public var explicitSize = false
    /// 0 = untouched, 1 = strong night mode.
    public var warmth: Double = 0
    public var seconds: Double = 0
    public var synthetic = false
    public init() {}
}

public struct SessionStats {
    public var fps: Double
    public var mbps: Double
    public var hostMs: Double
    public var rttMs: Double
    public var decodeMs: Double?
    public var audioPackets: UInt64
    public var estMs: Double
    /// Optional device state the receiver sends only when it changes (battery, charging, thermal).
    public var battery: Int?
    public var charging: Bool?
    public var thermal: String?
    /// 1 = cool, below ~0.3 = throttling soon.
    public var thermalHeadroom: Double?
}

public enum EngineError: Error, LocalizedError {
    case cannotConnect(String)
    case noWelcome
    case noReady
    case socket
    case encoder

    public var errorDescription: String? {
        switch self {
        case let .cannotConnect(what): return "cannot connect: \(what)"
        case .noWelcome: return "receiver did not answer hello"
        case .noReady: return "receiver did not answer start"
        case .socket: return "cannot open the media socket"
        case .encoder: return "cannot create the video encoder"
        }
    }
}

/// macOS shows its own dialog here; there is no custom UI and no "open Settings for me" shortcut.
public func ensureScreenRecording(wait: Bool) -> Bool {
    if CGPreflightScreenCaptureAccess() { return true }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    if CGRequestScreenCaptureAccess() { return true }
    guard wait else { return false }
    log("waiting for the system Screen Recording dialog (up to 180 s)…")
    let deadline = Date().addingTimeInterval(180)
    while Date() < deadline {
        if CGPreflightScreenCaptureAccess() {
            log("screen recording: granted")
            return true
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    return false
}

/// Stable sender identity, `~/Library/Application Support/Luch/id`.
public func senderIdentity() -> (id: String, name: String) {
    let fm = FileManager.default
    let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Luch", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("id")
    if let s = try? String(contentsOf: file, encoding: .utf8), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return (s.trimmingCharacters(in: .whitespacesAndNewlines), hostName())
    }
    let id = UUID().uuidString
    try? (id + "\n").write(to: file, atomically: true, encoding: .utf8)
    return (id, hostName())
}

public func hostName() -> String {
    let n = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    return n.split(separator: ".").first.map(String.init) ?? "mac"
}

final class Flag {
    private var value = false
    private let lock = NSLock()
    func set() { lock.lock(); value = true; lock.unlock() }
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; let v = value; value = false; return v }
}

public final class Engine {
    public private(set) var options: MirrorOptions
    /// CLI exits the process on stop; the menu-bar app will keep running instead.
    public var terminateOnStop = false
    /// Set by `run()` only: the engine then owns the main run loop and may stop it.
    public var ownsRunLoop = false
    public private(set) var streaming = false
    public private(set) var lastStats: SessionStats?
    public private(set) var plan: CodecPlan?
    /// True when the client said it runs on its own battery; drives the menu's suggestion.
    public private(set) var deviceOnBattery = false
    /// Colour temperature of the outgoing picture; can be changed while streaming.
    /// 0 = untouched, 1 = strong night mode.
    public var warmth: Double = 0
    public var onStats: ((SessionStats) -> Void)?
    /// The session ended on its own (receiver bye, capture error, socket loss).
    public var onStopped: ((String) -> Void)?
    public private(set) var receiver: Receiver?

    private var control: ControlChannel?
    private var videoTx: UdpSender?
    private var audioTx: UdpSender?
    private var encoder: VideoEncoder?
    private var audio: OpusAudio?
    private var capture: ScreenCapture?
    private var statsTimer: DispatchSourceTimer?
    private var keepaliveTimer: DispatchSourceTimer?
    private var syntheticTimer: DispatchSourceTimer?
    private var running = false
    private var stopping = false

    private let wantIDR = Flag()
    private let needHead = Flag()
    private var lastAU: (data: Data, flags: PacketFlags, hostLat: UInt16)?
    private var lastSentAt = Date.distantPast
    private var basePTS: CMTime?
    private var receiverStats: [String: Any] = [:]
    /// Device fields are event-driven on the receiver: they arrive only when something changes.
    private var deviceBattery: Int?
    private var deviceCharging: Bool?
    private var deviceThermal: String?
    private var deviceHeadroom: Double?
    private var lastFrames: UInt64 = 0
    private var lastBytes: UInt64 = 0
    private var lastLatency: UInt64 = 0
    private var audioFrames: UInt64 = 0

    public init(options: MirrorOptions) {
        self.options = options
    }

    deinit { stopTimers() }

    // MARK: - lifecycle

    public func start(receiver r: Receiver) throws {
        self.receiver = r
        warmth = options.warmth
        let identity = senderIdentity()

        guard let ctl = ControlChannel.open(ip: r.address, port: r.port, interfaceIndex: r.interfaceIndex) else {
            throw EngineError.cannotConnect("\(r.address):\(r.port)")
        }
        control = ctl
        ctl.onEvent = { [weak self] msg in self?.handle(msg) }

        ctl.send(["t": "hello", "v": Int(Proto.version), "id": identity.id, "name": identity.name,
                  "app": Proto.app, "want": ["mirror"]])
        guard let welcome = ctl.waitFor("welcome", timeout: 5) else { throw EngineError.noWelcome }
        guard let caps = ReceiverCaps(welcome: welcome) else { throw EngineError.noWelcome }
        log(caps.describe())
        let plan = CodecPlanner.plan(caps: caps, receiverID: r.id, options: options)
        self.plan = plan
        deviceOnBattery = caps.onBattery
        log("plan: \(plan.codec.label) \(plan.width)x\(plan.height)@\(plan.fps) audio=\(plan.audio) — \(plan.reason)")

        var start: [String: Any] = ["t": "start", "mode": "mirror",
                                    "video": ["codec": plan.codec.rawValue, "width": plan.width,
                                              "height": plan.height, "fps": plan.fps,
                                              // Ask the receiver to run the decoder at full operating rate:
                                              // without it MediaCodec pipelines ~5 frames at 60 fps.
                                              "operating_rate": true]]
        if plan.audio {
            start["audio"] = ["codec": "audio/opus", "rate": 48_000, "channels": 2,
                              "frame_ms": options.audioFrameMs]
        }
        ctl.send(start)
        guard let ready = ctl.waitFor("ready", timeout: 5) else { throw EngineError.noReady }
        guard let videoPort = (ready["video_port"] as? NSNumber)?.uint16Value, videoPort > 0 else {
            throw EngineError.noReady
        }
        log("ready: video port \(videoPort), audio port \(ready["audio_port"] ?? 0)")

        guard let vtx = UdpSender.open(kind: .video, ip: r.address, port: videoPort,
                                       interfaceIndex: r.interfaceIndex, dscp: 40) else {
            throw EngineError.socket
        }
        videoTx = vtx
        if plan.audio, let audioPort = (ready["audio_port"] as? NSNumber)?.uint16Value, audioPort > 0 {
            audioTx = UdpSender.open(kind: .audio, ip: r.address, port: audioPort,
                                     interfaceIndex: r.interfaceIndex, dscp: 48)
        } else if plan.audio {
            log("audio: receiver gave no audio port, continuing without sound")
        }

        guard let encoder = VideoEncoder(codec: plan.codec, width: plan.width, height: plan.height,
                                         fps: plan.fps, kbps: options.bitrate, profile: options.profile) else {
            throw EngineError.encoder
        }
        self.encoder = encoder
        wireVideo(encoder)

        if audioTx != nil {
            audio = OpusAudio(frameMs: options.audioFrameMs)
            wireAudio()
        }

        running = true
        streaming = true
        try startMedia()
        startTimers()
        log("streaming; Ctrl-C to stop")
    }

    public func run() {
        ownsRunLoop = true
        // A receiver may close the control channel between our `stop` and `bye`; without this the
        // write raises SIGPIPE and kills the process instead of returning EPIPE.
        signal(SIGPIPE, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler { [weak self] in self?.stop(reason: "SIGINT") }
        sigint.resume()
        if options.seconds > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + options.seconds) { [weak self] in
                self?.stop(reason: "timer \(self?.options.seconds ?? 0) s")
            }
        }
        RunLoop.main.run()
        sigint.cancel()
    }

    public func stop(reason: String) {
        guard running, !stopping else { return }
        stopping = true
        log("finishing: \(reason)")
        control?.send(["t": "stop"])
        control?.bye()
        stopTimers()
        let done = DispatchSemaphore(value: 0)
        let capture = self.capture
        Task {
            await capture?.stop()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
        running = false
        streaming = false
        log("done")
        onStopped?(reason)
        if terminateOnStop { exit(0) }
        if ownsRunLoop { CFRunLoopStop(CFRunLoopGetMain()) }
    }

    // MARK: - wiring

    private func wireVideo(_ encoder: VideoEncoder) {
        encoder.onPacket = { [weak self] data, idr, pts in
            guard let self, let tx = self.videoTx else { return }
            if idr { self.needHead.set() }
            let flags: PacketFlags = idr ? .idr : []
            let hostLat = self.hostLatency(pts)
            tx.send(frame: [UInt8](data), flags: flags, ptsUS: self.relativeUS(pts), hostLat: hostLat)
            self.lastAU = (data, flags, hostLat)
            self.lastSentAt = Date()
        }
    }

    private func wireAudio() {
        guard let audio else { return }
        audio.onPacket = { [weak self] data, pts in
            guard let self, let tx = self.audioTx else { return }
            if self.needHead.take() {
                tx.send(frame: [UInt8](audio.head), flags: .config, ptsUS: self.relativeUS(pts), hostLat: 0)
            }
            tx.send(frame: [UInt8](data), flags: [], ptsUS: self.relativeUS(pts), hostLat: self.hostLatency(pts))
            self.audioFrames += 1
        }
    }

    private func startMedia() throws {
        if options.synthetic {
            var index = 0
            let queue = DispatchQueue(label: "luch.synthetic", qos: .userInteractive)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / Double(options.fps))
            timer.setEventHandler { [weak self] in
                guard let self, let encoder = self.encoder else { return }
                let p = self.plan
                guard let buffer = SyntheticFrame.make(width: p?.width ?? self.options.width,
                                                       height: p?.height ?? self.options.height, index: index) else { return }
                index += 1
                let pts = CMClockGetTime(CMClockGetHostTimeClock())
                if self.basePTS == nil { self.basePTS = pts }
                encoder.encode(buffer, pts: pts, forceIDR: self.wantIDR.take())
            }
            timer.resume()
            syntheticTimer = timer
            log("source: synthetic frames (no screen capture, no audio)")
            return
        }

        let capture = ScreenCapture()
        self.capture = capture
        capture.onFrame = { [weak self] buffer, pts in
            guard let self, let encoder = self.encoder else { return }
            if self.basePTS == nil { self.basePTS = pts }
            WarmFilter.apply(buffer, strength: self.warmth)
            encoder.encode(buffer, pts: pts, forceIDR: self.wantIDR.take())
        }
        capture.onAudio = { [weak self] sampleBuffer in
            self?.audio?.push(sampleBuffer)
        }
        capture.onStop = { [weak self] why in
            self?.stop(reason: "capture: \(why)")
        }

        let started = DispatchSemaphore(value: 0)
        var failure: Error?
        let audio = (plan?.audio ?? options.audio) && audioTx != nil
        Task {
            do {
                let p = self.plan
                try await capture.start(displayIndex: options.display,
                                        width: p?.width ?? options.width,
                                        height: p?.height ?? options.height,
                                        fps: p?.fps ?? options.fps, audio: audio, fit: options.fit)
            } catch {
                failure = error
            }
            started.signal()
        }
        started.wait()
        if let failure {
            log("capture failed: \(failure.localizedDescription)")
            self.capture = nil
            control?.send(["t": "stop"])
            throw failure
        }
    }

    // MARK: - events

    private func handle(_ msg: [String: Any]) {
        switch msg["t"] as? String ?? "" {
        case "keyframe":
            log("<- keyframe request")
            wantIDR.set()
        case "stats":
            receiverStats = msg
            if let battery = (msg["battery"] as? NSNumber)?.intValue { deviceBattery = battery }
            if let charging = msg["charging"] as? NSNumber { deviceCharging = charging.boolValue }
            if let thermal = msg["thermal"] as? String { deviceThermal = thermal }
            if let headroom = (msg["thermal_headroom"] as? NSNumber)?.doubleValue { deviceHeadroom = headroom }
        case "error":
            log("<- error: \(msg)")
        case "stop", "bye":
            log("<- \(msg["t"] as? String ?? "")")
            stop(reason: "receiver stopped")
        default:
            break
        }
    }

    // MARK: - timers

    private func startTimers() {
        let stats = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "luch.stats"))
        stats.schedule(deadline: .now() + 1, repeating: 1)
        stats.setEventHandler { [weak self] in self?.reportStats() }
        stats.resume()
        statsTimer = stats

        let keepalive = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "luch.keepalive"))
        keepalive.schedule(deadline: .now() + 0.1, repeating: 0.1)
        keepalive.setEventHandler { [weak self] in self?.keepalive() }
        keepalive.resume()
        keepaliveTimer = keepalive
    }

    private func stopTimers() {
        statsTimer?.cancel(); statsTimer = nil
        keepaliveTimer?.cancel(); keepaliveTimer = nil
        syntheticTimer?.cancel(); syntheticTimer = nil
    }

    private func reportStats() {
        guard let tx = videoTx else { return }
        let snap = tx.snapshot()
        let df = snap.frames - lastFrames
        let db = snap.bytes - lastBytes
        let dl = snap.latencySum - lastLatency
        lastFrames = snap.frames
        lastBytes = snap.bytes
        lastLatency = snap.latencySum
        let hostMs = df > 0 ? Double(dl) / Double(df) / 10.0 : 0
        let mbps = Double(db) * 8 / 1e6
        let decodeMs = (receiverStats["decode_ms"] as? NSNumber)?.doubleValue
        var line = String(format: "stats: %.0f fps, %.1f Mbit/s, host %.1f ms, rtt %.1f ms",
                          Double(df), mbps, hostMs, control?.rttMs ?? 0)
        if let decodeMs {
            line += String(format: ", receiver decode %.1f ms", decodeMs)
            // Remember it: a real session outranks the receiver's own benchmark next time.
            if let receiver, let codec = plan?.codec {
                CodecMemory.shared.record(receiverID: receiver.id, codec: codec, ms: decodeMs)
            }
        }
        line += ", audio \(audioFrames) pkt"
        if let battery = deviceBattery {
            line += ", receiver battery \(battery)%"
            if let charging = deviceCharging, charging { line += " (charging)" }
        }
        if let thermal = deviceThermal, thermal != "none" { line += ", thermal \(thermal)" }
        if let headroom = deviceHeadroom {
            line += String(format: ", headroom %.2f", headroom)
            if headroom < 0.3 { line += " (hot: 720p or 30 fps would help)" }
        }
        log(line)
        let snapshot = SessionStats(fps: Double(df), mbps: mbps, hostMs: hostMs,
                                    rttMs: control?.rttMs ?? 0, decodeMs: decodeMs,
                                    audioPackets: audioFrames,
                                    estMs: hostMs + (control?.rttMs ?? 0) / 2 + (decodeMs ?? 0),
                                    battery: deviceBattery, charging: deviceCharging,
                                    thermal: deviceThermal, thermalHeadroom: deviceHeadroom)
        lastStats = snapshot
        onStats?(snapshot)
        control?.send(["t": "sender_stats", "rtt_ms": ((control?.rttMs ?? 0) * 10).rounded() / 10,
                       "host_ms": (hostMs * 10).rounded() / 10, "fps": df, "mbps": (mbps * 10).rounded() / 10,
                       "encoder": encoder?.codec == .hevc ? "hevc_videotoolbox" : "h264_videotoolbox",
                       "res": "\(plan?.width ?? options.width)x\(plan?.height ?? options.height)"])
    }

    /// ScreenCaptureKit is change-driven: on a still desktop it delivers ~1 fps, and if it goes fully
    /// quiet the receiver ends the session after 15 s without a single video packet. So repeat the last
    /// access unit: P-frames at 2 fps, an IDR more slowly (it is large, but still well inside the limit).
    /// The original capture-to-send latency travels with it, so the receiver's average stays honest.
    private func keepalive() {
        guard let last = lastAU, let tx = videoTx else { return }
        let idle = Date().timeIntervalSince(lastSentAt)
        let interval = Self.keepaliveInterval(isIDR: last.flags.contains(.idr))
        guard idle > interval else { return }
        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        tx.send(frame: [UInt8](last.data), flags: last.flags, ptsUS: relativeUS(pts), hostLat: last.hostLat)
        lastSentAt = Date()
    }

    /// The receiver ends a session after 15 s without a video packet (`SILENCE_MS` in MirrorSession),
    /// so both intervals must stay well below that. An IDR is large, hence the slower repeat.
    public static func keepaliveInterval(isIDR: Bool) -> TimeInterval {
        isIDR ? 5.0 : 0.5
    }

    // MARK: - time

    private func relativeUS(_ pts: CMTime) -> UInt32 {
        guard let base = basePTS else { return 0 }
        let us = (CMTimeGetSeconds(pts) - CMTimeGetSeconds(base)) * 1_000_000
        return UInt32(truncatingIfNeeded: max(0, Int64(us)))
    }

    private func hostLatency(_ pts: CMTime) -> UInt16 {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let us = max(0, (CMTimeGetSeconds(now) - CMTimeGetSeconds(pts)) * 1_000_000)
        return UInt16(min(Double(UInt16.max), us / 100))
    }
}
