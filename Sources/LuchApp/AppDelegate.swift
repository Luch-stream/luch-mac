// Menu bar UI for Luch on macOS: receiver list, mirror/stop, live latency, quality and login item.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreGraphics
import LuchEngine
import LuchLocal
import LuchMedia
import LuchNet
import LuchProto
import ScreenCaptureKit
import ServiceManagement

final class Preferences: @unchecked Sendable {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    var bitrate: Int {
        get { (defaults.object(forKey: "bitrate") as? NSNumber)?.intValue ?? Proto.videoKbps }
        set { defaults.set(newValue, forKey: "bitrate") }
    }

    /// Frame rate the stream is planned for; the heat policy may lower it.
    var fps: Int {
        get { (defaults.object(forKey: "fps") as? NSNumber)?.intValue ?? Proto.fps }
        set { defaults.set(newValue, forKey: "fps") }
    }

    /// Whether the receiver's heat is watched at all; off also hides the warning.
    var trackHeat: Bool {
        get { (defaults.object(forKey: "trackHeat") as? NSNumber)?.boolValue ?? true }
        set { defaults.set(newValue, forKey: "trackHeat") }
    }

    /// What to do when the receiver says it is too hot: warn | bitrate | quality | fps | both.
    var hotPolicy: String {
        get { defaults.string(forKey: "hotPolicy") ?? "warn" }
        set { defaults.set(newValue, forKey: "hotPolicy") }
    }

    /// Put the settings back once the receiver cools down.
    var restoreWhenCool: Bool {
        get { (defaults.object(forKey: "restoreWhenCool") as? NSNumber)?.boolValue ?? false }
        set { defaults.set(newValue, forKey: "restoreWhenCool") }
    }

    var audio: Bool {
        get { (defaults.object(forKey: "audio") as? NSNumber)?.boolValue ?? true }
        set { defaults.set(newValue, forKey: "audio") }
    }

    var display: Int? {
        get { (defaults.object(forKey: "display") as? NSNumber)?.intValue }
        set {
            if let newValue {
                defaults.set(newValue, forKey: "display")
            } else {
                defaults.removeObject(forKey: "display")
            }
        }
    }

    var codec: String {
        get { defaults.string(forKey: "codec") ?? CodecChoice.auto.rawValue }
        set { defaults.set(newValue, forKey: "codec") }
    }

    /// Continuous 0...1; the old off/soft/strong strings are migrated on read.
    var warmth: Double {
        get {
            if defaults.object(forKey: "warmthLevel") != nil { return defaults.double(forKey: "warmthLevel") }
            switch defaults.string(forKey: "warmth") ?? "off" {
            case "soft": return 0.35
            case "strong": return 0.7
            default: return 0
            }
        }
        set { defaults.set(min(1, max(0, newValue)), forKey: "warmthLevel") }
    }

    var audioFrameMs: Int {
        get { defaults.object(forKey: "audioFrameMs") as? Int ?? 20 }
        set { defaults.set(newValue, forKey: "audioFrameMs") }
    }

    var audioFEC: Bool {
        get { defaults.object(forKey: "audioFec") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "audioFec") }
    }

    var audioBitrate: Int {
        get { defaults.object(forKey: "audioBitrate") as? Int ?? 128_000 }
        set { defaults.set(newValue, forKey: "audioBitrate") }
    }

    var preset: String {
        get { defaults.string(forKey: "quality") ?? QualityPreset.auto.rawValue }
        set { defaults.set(newValue, forKey: "quality") }
    }

    var sizeMode: String {
        get { defaults.string(forKey: "sizeMode") ?? SizeMode.fit.rawValue }
        set { defaults.set(newValue, forKey: "sizeMode") }
    }

    var mirrorOnLaunch: Bool {
        get { (defaults.object(forKey: "mirrorOnLaunch") as? NSNumber)?.boolValue ?? false }
        set { defaults.set(newValue, forKey: "mirrorOnLaunch") }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let discovery = Discovery()
    private var engine: Engine?
    private var state = "Idle"
    private var statsLine = "Not streaming"
    private var statsItem: NSMenuItem?
    private var timer: Timer?
    private var receivers: [Receiver] = []
    private var pendingMenuRefresh = false
    private var server: LocalServer?
    private var currentReceiverID: String?
    private var currentReceiver: Receiver?
    private weak var warmPercent: NSTextField?
    /// Set from `luchctl mirror --frame-ms N`, for A/B testing the audio buffer without a rebuild.
    private var frameMsOverride: Int?
    private var profileOverride: VideoProfile?
    /// Codec asked for by `luchctl --codec` for this session only; the menu changes the default.
    private var codecOverride: CodecChoice?
    /// Size mode asked for by `luchctl --size-mode` for this session only.
    private var sizeModeOverride: SizeMode?
    private var presetOverride: QualityPreset?
    private var audioBitrateOverride: Int?
    private var bitrateOverride: Int?
    private var fpsOverride: Int?
    /// What the heat policy changed for this session, and what it was before.
    private var hotPreset: QualityPreset?
    private var hotBitrate: Int?
    private var hotFps: Int?
    private var hotApplied = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        logFile =
            Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("luch-app.log").path
        log("app: launched, bundle \(Bundle.main.bundleURL.lastPathComponent)")

        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "dot.radiowaves.left.and.right",
            accessibilityDescription: "Luch")
        statusItem.button?.toolTip = "Luch"
        statusItem.menu = menu

        discovery.onUpdate = { [weak self] in
            DispatchQueue.main.async { self?.refreshReceivers() }
        }
        discovery.start()
        let identity = senderIdentity()
        discovery.publish(name: identity.name, id: identity.id)
        startLocalServer()

        rebuildMenu()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }

        if Preferences.shared.mirrorOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.mirrorIfSingle() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine?.stop(reason: "quit")
    }

    // MARK: - local API (luchctl)

    private func startLocalServer() {
        let server = LocalServer()
        server.handler = { [weak self] request in
            guard let self else { return ["error": "app is shutting down"] }
            var response: [String: Any] = [:]
            // The socket thread must not touch AppKit state directly.
            DispatchQueue.main.sync { response = self.handleLocal(request) }
            return response
        }
        do {
            try server.start()
            self.server = server
        } catch {
            log("app: local server failed: \(error.localizedDescription)")
        }
    }

    private func handleLocal(_ request: [String: Any]) -> [String: Any] {
        switch request["cmd"] as? String ?? "" {
        case "ping":
            return ["ok": true]
        case "receivers":
            return [
                "receivers": receivers.map { receiver in
                    [
                        "id": receiver.id, "name": receiver.name, "model": receiver.model,
                        "address": receiver.address, "iface": receiver.interfaceName,
                        "port": Int(receiver.port),
                        "mirroring": engine != nil && currentReceiverID == receiver.id,
                    ]
                }
            ]
        case "state":
            return ["state": state, "streaming": engine != nil, "stats": statsDictionary()]
        case "stats":
            return ["stats": statsDictionary()]
        case "mirror":
            if let frameMs = (request["frame_ms"] as? NSNumber)?.intValue { frameMsOverride = frameMs }
            if let codec = request["codec"] as? String, let value = CodecChoice(rawValue: codec) {
                codecOverride = value
            }
            if let mode = request["size_mode"] as? String, let value = SizeMode(rawValue: mode) {
                sizeModeOverride = value
            }
            if let preset = request["preset"] as? String, let value = QualityPreset.parse(preset) {
                presetOverride = value
            }
            if let text = request["audio_bitrate"] as? String, let kbps = Int(text) {
                audioBitrateOverride = kbps * 1000
            }
            if let profile = request["profile"] as? String, let value = VideoProfile(rawValue: profile) {
                self.profileOverride = value
            }
            let wanted = (request["id"] as? String) ?? (request["name"] as? String)
            // Address too: two receivers can share a display name (the Mac viewer and a phone).
            let match =
                receivers.first { $0.id == wanted || $0.name == wanted || $0.address == wanted }
                ?? (receivers.count == 1 ? receivers[0] : nil)
            guard let receiver = match else { return ["error": "receiver not found"] }
            startMirror(receiver)
            return ["ok": true, "receiver": receiver.name]
        case "warmth":
            let value: Double
            if let number = request["value"] as? NSNumber {
                value = number.doubleValue
            } else if let text = request["value"] as? String, let parsed = Double(text) {
                value = parsed
            } else {
                return ["error": "warmth expects a number 0...1"]
            }
            let warmth = min(1, max(0, value))
            Preferences.shared.warmth = warmth
            engine?.warmth = warmth  // live: the next frame is already warmer
            rebuildMenu()
            return ["ok": true, "warmth": warmth]
        case "stop":
            stopMirror()
            return ["ok": true]
        default:
            return ["error": "unknown command"]
        }
    }

    private func statsDictionary() -> [String: Any] {
        guard let stats = engine?.lastStats else { return [:] }
        var out: [String: Any] = [
            "est_ms": stats.estMs, "host_ms": stats.hostMs,
            "rtt_ms": stats.rttMs, "fps": stats.fps, "mbps": stats.mbps,
            "audio": stats.audioPackets,
        ]
        if let decode = stats.decodeMs { out["decode_ms"] = decode }
        if let battery = stats.battery { out["battery"] = battery }
        if let charging = stats.charging { out["charging"] = charging }
        if let thermal = stats.thermal { out["thermal"] = thermal }
        if let headroom = stats.thermalHeadroom, Preferences.shared.trackHeat {
            out["thermal_headroom"] = headroom
        }
        return out
    }

    // MARK: - menu

    private func refreshReceivers() {
        receivers = discovery.all()
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        if receivers.isEmpty {
            let item = NSMenuItem(title: "No receivers found", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        for (index, receiver) in receivers.enumerated() {
            let item = NSMenuItem(title: receiver.name, action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            let mirror = NSMenuItem(
                title: "Mirror Screen", action: #selector(mirrorScreen(_:)), keyEquivalent: "")
            mirror.target = self
            mirror.representedObject = index
            submenu.addItem(mirror)
            let stop = NSMenuItem(title: "Stop", action: #selector(stopMirror), keyEquivalent: "")
            stop.target = self
            stop.isEnabled = engine != nil
            submenu.addItem(stop)
            item.submenu = submenu
            if index == 0 { item.image = NSImage(systemSymbolName: "tv", accessibilityDescription: nil) }
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let stats = NSMenuItem(title: statsLine, action: nil, keyEquivalent: "")
        stats.isEnabled = false
        statsItem = stats
        menu.addItem(stats)

        let stateItem = NSMenuItem(title: state, action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)

        menu.addItem(.separator())

        // Video ▸ — one level deep: a header, then the choices, no nested menus.
        func header(_ title: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }

        let video = NSMenuItem(title: "Video", action: nil, keyEquivalent: "")
        let videoMenu = NSMenu()

        videoMenu.addItem(header("Quality"))
        for preset in QualityPreset.allCases {
            let onBattery = engine?.deviceOnBattery ?? false
            let hint = onBattery && preset != .low ? " — drains the battery faster" : ""
            let item = NSMenuItem(
                title: "   " + preset.label + hint,
                action: #selector(setPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.rawValue
            item.state = Preferences.shared.preset == preset.rawValue ? .on : .off
            videoMenu.addItem(item)
        }

        videoMenu.addItem(.separator())
        videoMenu.addItem(header("Size"))
        for mode in SizeMode.allCases {
            let item = NSMenuItem(
                title: "   " + mode.rawValue.capitalized,
                action: #selector(setSizeMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = Preferences.shared.sizeMode == mode.rawValue ? .on : .off
            videoMenu.addItem(item)
        }

        videoMenu.addItem(.separator())
        videoMenu.addItem(header("Codec"))
        for choice in CodecChoice.allCases {
            let label: String
            switch choice {
            case .auto: label = "Auto"
            case .h264: label = "H.264"
            case .hevc: label = "HEVC"
            }
            let item = NSMenuItem(title: "   " + label, action: #selector(setCodec(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.rawValue
            item.state = Preferences.shared.codec == choice.rawValue ? .on : .off
            videoMenu.addItem(item)
        }

        videoMenu.addItem(.separator())
        videoMenu.addItem(header("Bitrate"))
        let videoAuto = NSMenuItem(title: "   Auto", action: #selector(setBitrate(_:)), keyEquivalent: "")
        videoAuto.target = self
        videoAuto.representedObject = 0
        videoAuto.state = Preferences.shared.bitrate == 0 ? .on : .off
        videoMenu.addItem(videoAuto)
        for kbps in [10_000, 20_000, 30_000] {
            let item = NSMenuItem(
                title: "   \(kbps / 1000) Mbit/s",
                action: #selector(setBitrate(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kbps
            item.state = Preferences.shared.bitrate == kbps ? .on : .off
            videoMenu.addItem(item)
        }

        videoMenu.addItem(.separator())
        // Same shape as the other groups: a header, then the slider row itself.
        videoMenu.addItem(header("Warm picture"))
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        let slider = NSSlider(
            value: Preferences.shared.warmth, minValue: 0, maxValue: 1, target: self,
            action: #selector(warmthChanged(_:)))
        slider.isContinuous = true
        slider.controlSize = .small
        slider.frame = NSRect(x: 30, y: 4, width: 186, height: 18)
        row.addSubview(slider)

        let percent = NSTextField(
            labelWithString: String(format: "%d%%", Int((Preferences.shared.warmth * 100).rounded())))
        percent.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        percent.textColor = .secondaryLabelColor
        percent.frame = NSRect(x: 222, y: 5, width: 32, height: 16)
        row.addSubview(percent)
        warmPercent = percent

        let warmItem = NSMenuItem()
        warmItem.view = row
        videoMenu.addItem(warmItem)

        videoMenu.addItem(.separator())
        videoMenu.addItem(header("Display"))
        let main = NSMenuItem(title: "   Main display", action: #selector(setDisplay(_:)), keyEquivalent: "")
        main.target = self
        main.representedObject = -1
        main.state = Preferences.shared.display == nil ? .on : .off
        videoMenu.addItem(main)
        for (index, screen) in NSScreen.screens.enumerated() {
            let item = NSMenuItem(
                title: "   " + screen.localizedName,
                action: #selector(setDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = index
            item.state = Preferences.shared.display == index ? .on : .off
            videoMenu.addItem(item)
        }

        video.submenu = videoMenu
        menu.addItem(video)

        // Audio ▸ — same rule: one level.
        let audioGroup = NSMenuItem(title: "Audio", action: nil, keyEquivalent: "")
        let audioGroupMenu = NSMenu()

        let sound = NSMenuItem(title: "Sound", action: #selector(toggleAudio), keyEquivalent: "")
        sound.target = self
        sound.state = Preferences.shared.audio ? .on : .off
        audioGroupMenu.addItem(sound)

        audioGroupMenu.addItem(.separator())
        audioGroupMenu.addItem(header("Bitrate"))
        let audioAuto = NSMenuItem(
            title: "   Auto", action: #selector(setAudioBitrate(_:)), keyEquivalent: "")
        audioAuto.target = self
        audioAuto.representedObject = 0
        audioAuto.state = Preferences.shared.audioBitrate == 0 ? .on : .off
        audioGroupMenu.addItem(audioAuto)
        for kbps in [64, 96, 128, 192] {
            let item = NSMenuItem(
                title: "   \(kbps) kbit/s",
                action: #selector(setAudioBitrate(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kbps * 1000
            item.state = Preferences.shared.audioBitrate == kbps * 1000 ? .on : .off
            audioGroupMenu.addItem(item)
        }

        audioGroupMenu.addItem(.separator())
        audioGroupMenu.addItem(header("Frame size"))
        for ms in [10, 20] {
            let item = NSMenuItem(
                title: "   \(ms) ms", action: #selector(setAudioFrameMs(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ms
            item.state = Preferences.shared.audioFrameMs == ms ? .on : .off
            audioGroupMenu.addItem(item)
        }

        audioGroupMenu.addItem(.separator())
        let fec = NSMenuItem(title: "In-band FEC", action: #selector(toggleAudioFEC), keyEquivalent: "")
        fec.target = self
        fec.state = Preferences.shared.audioFEC ? .on : .off
        audioGroupMenu.addItem(fec)

        audioGroup.submenu = audioGroupMenu
        menu.addItem(audioGroup)

        // Receiver heat ▸
        let heat = NSMenuItem(title: "Receiver heat", action: nil, keyEquivalent: "")
        let heatMenu = NSMenu()
        let auto = NSMenuItem(
            title: "Track receiver heat: Auto", action: #selector(setTrackHeat(_:)), keyEquivalent: "")
        auto.target = self
        auto.representedObject = true
        auto.state = Preferences.shared.trackHeat ? .on : .off
        heatMenu.addItem(auto)
        let off = NSMenuItem(
            title: "Track receiver heat: Off", action: #selector(setTrackHeat(_:)), keyEquivalent: "")
        off.target = self
        off.representedObject = false
        off.state = Preferences.shared.trackHeat ? .off : .on
        heatMenu.addItem(off)

        heatMenu.addItem(.separator())
        for (value, label) in [
            ("warn", "Warn only"), ("bitrate", "Lower bitrate"),
            ("quality", "Lower quality"), ("fps", "Lower fps"),
            ("both", "Bitrate + fps"),
        ] {
            let item = NSMenuItem(
                title: "When hot: " + label, action: #selector(setHotPolicy(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = Preferences.shared.hotPolicy == value ? .on : .off
            heatMenu.addItem(item)
        }

        heatMenu.addItem(.separator())
        let restore = NSMenuItem(
            title: "Restore quality when cool", action: #selector(toggleRestoreWhenCool), keyEquivalent: "")
        restore.target = self
        restore.state = Preferences.shared.restoreWhenCool ? .on : .off
        heatMenu.addItem(restore)

        heat.submenu = heatMenu
        menu.addItem(heat)

        menu.addItem(.separator())

        let launch = NSMenuItem(
            title: "Mirror on launch", action: #selector(toggleMirrorOnLaunch), keyEquivalent: "")
        launch.target = self
        launch.state = Preferences.shared.mirrorOnLaunch ? .on : .off
        menu.addItem(launch)

        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit Luch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func tick() {
        guard let stats = engine?.lastStats else {
            if engine == nil && statsLine != "Not streaming" {
                statsLine = "Not streaming"
                statsItem?.title = statsLine
            }
            return
        }
        var line = String(format: "≈ %.0f ms · host %.1f · rtt %.1f", stats.estMs, stats.hostMs, stats.rttMs)
        if let decode = stats.decodeMs { line += String(format: " · dec %.1f", decode) }
        if let battery = stats.battery {
            line += " · 📱\(battery)%"
            if stats.charging == true { line += "⚡" }
        }
        if let thermal = stats.thermal, thermal != "none" { line += " · \(thermal)" }
        if let headroom = stats.thermalHeadroom, Preferences.shared.trackHeat {
            // Warn, never throttle on its own: the user decides whether to drop the quality.
            line +=
                headroom < 0.3
                ? String(format: " · 🔥 %.2f", headroom)
                : String(format: " · 🌡%.2f", headroom)
        }
        line += String(format: " · %.0f fps", stats.fps)
        if line != statsLine {
            statsLine = line
            statsItem?.title = line
        }
    }

    // MARK: - receiver heat

    /// The receiver crossed the hot line (or came back). Acts only if the user asked for it, and only
    /// when the receiver actually has a thermal sensor to trust.
    private func receiverHot(_ hot: Bool, headroom: Double) {
        guard Preferences.shared.trackHeat, engine?.caps?.hasThermal == true else { return }
        if hot {
            guard !hotApplied, Preferences.shared.hotPolicy != "warn" else { return }
            hotApplied = true
            let policy = Preferences.shared.hotPolicy
            if policy == "bitrate" || policy == "both" {
                let now = Preferences.shared.bitrate
                hotBitrate = max(3_000, Int(Double(now) * 0.6 / 1000) * 1000)
            }
            if policy == "quality" {
                hotPreset = Self.stepDown(QualityPreset.parse(Preferences.shared.preset) ?? .balanced)
            }
            if policy == "fps" || policy == "both" { hotFps = 30 }
            state = String(format: "Receiver is hot (%.2f) — applying heat policy", headroom)
            rebuildMenu()
            if let receiver = currentReceiver { startMirror(receiver) }
        } else if hotApplied, Preferences.shared.restoreWhenCool {
            hotApplied = false
            hotPreset = nil
            hotBitrate = nil
            hotFps = nil
            state = "Receiver is cool again — settings restored"
            rebuildMenu()
            if let receiver = currentReceiver { startMirror(receiver) }
        }
    }

    private static func stepDown(_ preset: QualityPreset) -> QualityPreset {
        switch preset {
        case .auto, .low: return .low
        case .balanced: return .low
        case .high: return .balanced
        case .max: return .high
        }
    }

    // MARK: - actions

    @objc private func mirrorScreen(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int, index < receivers.count else { return }
        startMirror(receivers[index])
    }

    @objc private func mirrorIfSingle() {
        guard engine == nil, receivers.count == 1 else { return }
        startMirror(receivers[0])
    }

    private func startMirror(_ receiver: Receiver) {
        // Switching sessions: let the receiver close the previous one first, otherwise it tears
        // down the new session a few hundred ms after start.
        if let old = engine {
            engine = nil
            currentReceiverID = nil
            state = "Switching…"
            rebuildMenu()
            DispatchQueue.global(qos: .userInitiated).async {
                old.stop(reason: "switch")
                Thread.sleep(forTimeInterval: 0.8)
                DispatchQueue.main.async { [weak self] in self?.beginMirror(receiver) }
            }
            return
        }
        beginMirror(receiver)
    }

    private func beginMirror(_ receiver: Receiver) {
        if !CGPreflightScreenCaptureAccess() {
            // The system dialog only comes forward for a regular, active app; a background
            // accessory app gets an immediate "declined" with no window at all.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            _ = CGRequestScreenCaptureAccess()
            if !CGPreflightScreenCaptureAccess() {
                // Second system path: ScreenCaptureKit itself triggers the prompt on modern macOS.
                let ready = DispatchSemaphore(value: 0)
                SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { _, _ in
                    ready.signal()
                }
                _ = ready.wait(timeout: .now() + 5)
            }
            NSApp.setActivationPolicy(.accessory)
            if !CGPreflightScreenCaptureAccess() {
                state = "Screen Recording permission required"
                rebuildMenu()
                return
            }
        }

        stopMirror()
        var options = MirrorOptions()
        options.bitrate = bitrateOverride ?? hotBitrate ?? Preferences.shared.bitrate
        options.audio = Preferences.shared.audio
        options.display = Preferences.shared.display
        options.codec = codecOverride ?? (CodecChoice(rawValue: Preferences.shared.codec) ?? .auto)
        options.sizeMode = sizeModeOverride ?? (SizeMode(rawValue: Preferences.shared.sizeMode) ?? .fit)
        options.preset =
            presetOverride ?? hotPreset ?? (QualityPreset.parse(Preferences.shared.preset) ?? .balanced)
        options.fps = fpsOverride ?? hotFps ?? Preferences.shared.fps
        options.audioBitrate = audioBitrateOverride ?? Preferences.shared.audioBitrate
        options.audioFrameMs = Preferences.shared.audioFrameMs
        options.audioFEC = Preferences.shared.audioFEC
        options.warmth = Preferences.shared.warmth
        if let frameMs = frameMsOverride { options.audioFrameMs = frameMs }
        options.profile = profileOverride
        let engine = Engine(options: options)
        engine.onStats = { [weak self] stats in
            DispatchQueue.main.async { self?.apply(stats) }
        }
        engine.onHot = { [weak self] hot, headroom in
            DispatchQueue.main.async { self?.receiverHot(hot, headroom: headroom) }
        }
        engine.onStopped = { [weak self] reason in
            DispatchQueue.main.async {
                guard let self, self.engine == nil else { return }  // replaced by a newer session
                self.currentReceiverID = nil
                self.state = "Idle (\(reason))"
                self.statsLine = "Not streaming"
                self.statsItem?.title = self.statsLine
                self.rebuildMenu()
            }
        }
        self.engine = engine
        currentReceiverID = receiver.id
        currentReceiver = receiver
        state = "Connecting to \(receiver.name)…"
        rebuildMenu()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try engine.start(receiver: receiver)
                let codec = engine.plan?.codec.label ?? ""
                let batteryNote = engine.deviceOnBattery ? " · 🔋 on battery" : ""
                DispatchQueue.main.async {
                    self?.state = "Mirroring to \(receiver.name) · \(codec)\(batteryNote)"
                    self?.rebuildMenu()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.state = "Error: \(error.localizedDescription)"
                    self?.engine = nil
                    self?.rebuildMenu()
                }
            }
        }
    }

    private func apply(_ stats: SessionStats) {
        var line = String(format: "≈ %.0f ms · host %.1f · rtt %.1f", stats.estMs, stats.hostMs, stats.rttMs)
        if let decode = stats.decodeMs { line += String(format: " · dec %.1f", decode) }
        if let battery = stats.battery {
            line += " · 📱\(battery)%"
            if stats.charging == true { line += "⚡" }
        }
        if let thermal = stats.thermal, thermal != "none" { line += " · \(thermal)" }
        if let headroom = stats.thermalHeadroom, Preferences.shared.trackHeat {
            // Warn, never throttle on its own: the user decides whether to drop the quality.
            line +=
                headroom < 0.3
                ? String(format: " · 🔥 %.2f", headroom)
                : String(format: " · 🌡%.2f", headroom)
        }
        line += String(format: " · %.0f fps", stats.fps)
        statsLine = line
        statsItem?.title = line
    }

    @objc private func stopMirror() {
        guard let engine else { return }
        self.engine = nil
        currentReceiverID = nil
        currentReceiver = nil
        state = "Stopping…"
        statsLine = "Not streaming"
        rebuildMenu()
        DispatchQueue.global(qos: .userInitiated).async {
            engine.stop(reason: "menu")
            DispatchQueue.main.async { [weak self] in
                self?.state = "Idle"
                self?.rebuildMenu()
            }
        }
    }

    @objc private func toggleAudio() {
        Preferences.shared.audio.toggle()
        log("app: menu audio -> \(Preferences.shared.audio)")
        restartIfStreaming()
    }

    /// Colour temperature applies live: no restart, no menu rebuild — the next frame is already warmer.
    @objc private func warmthChanged(_ sender: NSSlider) {
        let warmth = min(1, max(0, sender.doubleValue))
        Preferences.shared.warmth = warmth
        engine?.warmth = warmth
        warmPercent?.stringValue = String(format: "%d%%", Int((warmth * 100).rounded()))
    }

    @objc private func setAudioFrameMs(_ sender: NSMenuItem) {
        guard let ms = sender.representedObject as? Int else { return }
        log("app: menu audio frame -> \(ms) ms")
        Preferences.shared.audioFrameMs = ms
        restartIfStreaming()
    }

    @objc private func setTrackHeat(_ sender: NSMenuItem) {
        guard let on = sender.representedObject as? Bool else { return }
        Preferences.shared.trackHeat = on
        rebuildMenu()
    }

    @objc private func setHotPolicy(_ sender: NSMenuItem) {
        guard let policy = sender.representedObject as? String else { return }
        Preferences.shared.hotPolicy = policy
        rebuildMenu()
    }

    @objc private func toggleRestoreWhenCool() {
        Preferences.shared.restoreWhenCool.toggle()
        rebuildMenu()
    }

    @objc private func toggleAudioFEC() {
        Preferences.shared.audioFEC.toggle()
        log("app: menu audio fec -> \(Preferences.shared.audioFEC)")
        restartIfStreaming()
    }

    @objc private func setAudioBitrate(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Int else { return }
        log("app: menu audio bitrate -> \(value)")
        Preferences.shared.audioBitrate = value
        restartIfStreaming()
    }

    @objc private func setPreset(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        log("app: menu quality -> \(raw)")
        presetOverride = nil
        Preferences.shared.preset = raw
        restartIfStreaming()
    }

    @objc private func setSizeMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        log("app: menu size -> \(raw)")
        sizeModeOverride = nil
        Preferences.shared.sizeMode = raw
        restartIfStreaming()
    }

    @objc private func setCodec(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        log("app: menu codec -> \(raw)")
        codecOverride = nil
        Preferences.shared.codec = raw
        restartIfStreaming()
    }

    @objc private func setBitrate(_ sender: NSMenuItem) {
        guard let kbps = sender.representedObject as? Int else { return }
        log("app: menu bitrate -> \(kbps)")
        Preferences.shared.bitrate = kbps
        restartIfStreaming()
    }

    @objc private func setDisplay(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        log("app: menu display -> \(index)")
        Preferences.shared.display = index < 0 ? nil : index
        restartIfStreaming()
    }

    /// A setting changed while streaming: apply it now instead of waiting for the next Mirror.
    private func restartIfStreaming() {
        guard let receiver = currentReceiver, engine != nil else {
            rebuildMenu()
            return
        }
        log(
            "app: setting changed while streaming, restarting (engine=\(engine != nil), receiver=\(receiver.name))"
        )
        startMirror(receiver)
    }

    @objc private func toggleMirrorOnLaunch() {
        Preferences.shared.mirrorOnLaunch.toggle()
        rebuildMenu()
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            state = "Login item: \(error.localizedDescription)"
            log("app: login item failed: \(error.localizedDescription)")
        }
        rebuildMenu()
    }
}
