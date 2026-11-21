// Menu bar UI for Luch on macOS: receiver list, mirror/stop, live latency, quality and login item.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreGraphics
import LuchEngine
import ScreenCaptureKit
import LuchLocal
import LuchMedia
import LuchNet
import LuchProto
import ServiceManagement

final class Preferences {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    var bitrate: Int {
        get { (defaults.object(forKey: "bitrate") as? NSNumber)?.intValue ?? Proto.videoKbps }
        set { defaults.set(newValue, forKey: "bitrate") }
    }

    var audio: Bool {
        get { (defaults.object(forKey: "audio") as? NSNumber)?.boolValue ?? true }
        set { defaults.set(newValue, forKey: "audio") }
    }

    var display: Int? {
        get { (defaults.object(forKey: "display") as? NSNumber)?.intValue }
        set {
            if let newValue { defaults.set(newValue, forKey: "display") }
            else { defaults.removeObject(forKey: "display") }
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        logFile = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("luch-app.log").path
        log("app: launched, bundle \(Bundle.main.bundleURL.lastPathComponent)")

        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "dot.radiowaves.left.and.right",
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
            return ["receivers": receivers.map { receiver in
                ["id": receiver.id, "name": receiver.name, "model": receiver.model,
                 "address": receiver.address, "iface": receiver.interfaceName,
                 "port": Int(receiver.port),
                 "mirroring": engine != nil && currentReceiverID == receiver.id]
            }]
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
        if let profile = request["profile"] as? String, let value = VideoProfile(rawValue: profile) {
            self.profileOverride = value
        }
            let wanted = (request["id"] as? String) ?? (request["name"] as? String)
            let match = receivers.first { $0.id == wanted || $0.name == wanted }
                ?? (receivers.count == 1 ? receivers[0] : nil)
            guard let receiver = match else { return ["error": "receiver not found"] }
            startMirror(receiver)
            return ["ok": true, "receiver": receiver.name]
        case "warmth":
            let value: Double
            if let number = request["value"] as? NSNumber { value = number.doubleValue }
            else if let text = request["value"] as? String, let parsed = Double(text) { value = parsed }
            else { return ["error": "warmth expects a number 0...1"] }
            let warmth = min(1, max(0, value))
            Preferences.shared.warmth = warmth
            engine?.warmth = warmth     // live: the next frame is already warmer
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
        var out: [String: Any] = ["est_ms": stats.estMs, "host_ms": stats.hostMs,
                                  "rtt_ms": stats.rttMs, "fps": stats.fps, "mbps": stats.mbps,
                                  "audio": stats.audioPackets]
        if let decode = stats.decodeMs { out["decode_ms"] = decode }
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
            let mirror = NSMenuItem(title: "Mirror Screen", action: #selector(mirrorScreen(_:)), keyEquivalent: "")
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

        let audio = NSMenuItem(title: "Audio", action: #selector(toggleAudio), keyEquivalent: "")
        audio.target = self
        audio.state = Preferences.shared.audio ? .on : .off
        menu.addItem(audio)

        // One row: label, slider, percentage. A bare NSSlider as the item view sits crooked in a menu.
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        let label = NSTextField(labelWithString: "Warm")
        label.font = .menuFont(ofSize: 13)
        label.frame = NSRect(x: 22, y: 5, width: 44, height: 16)
        row.addSubview(label)

        let slider = NSSlider(value: Preferences.shared.warmth, minValue: 0, maxValue: 1, target: self,
                              action: #selector(warmthChanged(_:)))
        slider.isContinuous = true
        slider.controlSize = .small
        slider.frame = NSRect(x: 70, y: 4, width: 148, height: 18)
        row.addSubview(slider)

        let percent = NSTextField(labelWithString: String(format: "%d%%", Int((Preferences.shared.warmth * 100).rounded())))
        percent.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        percent.textColor = .secondaryLabelColor
        percent.frame = NSRect(x: 222, y: 5, width: 32, height: 16)
        row.addSubview(percent)
        warmPercent = percent

        let warmItem = NSMenuItem()
        warmItem.view = row
        // Tucked into a submenu: the top level stays short, and the row gets the full width it needs.
        let warmParent = NSMenuItem(title: "Warm picture", action: nil, keyEquivalent: "")
        let warmMenu = NSMenu()
        warmMenu.addItem(warmItem)
        warmParent.submenu = warmMenu
        menu.addItem(warmParent)

        let quality = NSMenuItem(title: "Quality", action: nil, keyEquivalent: "")
        let qualityMenu = NSMenu()
        for preset in QualityPreset.allCases {
            // Warn about the cost, do not silently change the user's choice.
            let onBattery = engine?.deviceOnBattery ?? false
            let hint = onBattery && preset != .low ? " — drains the battery faster" : ""
            _ = preset
            let item = NSMenuItem(title: preset.label + hint, action: #selector(setPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.rawValue
            item.state = Preferences.shared.preset == preset.rawValue ? .on : .off
            qualityMenu.addItem(item)
        }
        quality.submenu = qualityMenu
        menu.addItem(quality)

        let size = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for mode in SizeMode.allCases {
            let item = NSMenuItem(title: mode.rawValue, action: #selector(setSizeMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = Preferences.shared.sizeMode == mode.rawValue ? .on : .off
            sizeMenu.addItem(item)
        }
        size.submenu = sizeMenu
        menu.addItem(size)

        let codec = NSMenuItem(title: "Codec", action: nil, keyEquivalent: "")
        let codecMenu = NSMenu()
        for choice in CodecChoice.allCases {
            let item = NSMenuItem(title: choice.rawValue.uppercased(), action: #selector(setCodec(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.rawValue
            item.state = Preferences.shared.codec == choice.rawValue ? .on : .off
            codecMenu.addItem(item)
        }
        codec.submenu = codecMenu
        menu.addItem(codec)

        let bitrate = NSMenuItem(title: "Bitrate", action: nil, keyEquivalent: "")
        let bitrateMenu = NSMenu()
        for kbps in [10_000, 20_000, 30_000] {
            let item = NSMenuItem(title: "\(kbps / 1000) Mbit/s", action: #selector(setBitrate(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kbps
            item.state = Preferences.shared.bitrate == kbps ? .on : .off
            bitrateMenu.addItem(item)
        }
        bitrate.submenu = bitrateMenu
        menu.addItem(bitrate)

        let display = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        let main = NSMenuItem(title: "Main display", action: #selector(setDisplay(_:)), keyEquivalent: "")
        main.target = self
        main.representedObject = -1
        main.state = Preferences.shared.display == nil ? .on : .off
        displayMenu.addItem(main)
        for (index, screen) in NSScreen.screens.enumerated() {
            let item = NSMenuItem(title: screen.localizedName, action: #selector(setDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = index
            item.state = Preferences.shared.display == index ? .on : .off
            displayMenu.addItem(item)
        }
        display.submenu = displayMenu
        menu.addItem(display)

        menu.addItem(.separator())

        let launch = NSMenuItem(title: "Mirror on launch", action: #selector(toggleMirrorOnLaunch), keyEquivalent: "")
        launch.target = self
        launch.state = Preferences.shared.mirrorOnLaunch ? .on : .off
        menu.addItem(launch)

        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Luch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        if let headroom = stats.thermalHeadroom {
            // Warn, never throttle on its own: the user decides whether to drop the quality.
            line += headroom < 0.3 ? String(format: " · 🔥 %.2f", headroom)
                                   : String(format: " · 🌡%.2f", headroom)
        }
        line += String(format: " · %.0f fps", stats.fps)
        if line != statsLine {
            statsLine = line
            statsItem?.title = line
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
        options.bitrate = Preferences.shared.bitrate
        options.audio = Preferences.shared.audio
        options.display = Preferences.shared.display
        options.codec = codecOverride ?? (CodecChoice(rawValue: Preferences.shared.codec) ?? .auto)
        options.sizeMode = sizeModeOverride ?? (SizeMode(rawValue: Preferences.shared.sizeMode) ?? .fit)
        options.preset = presetOverride ?? (QualityPreset.parse(Preferences.shared.preset) ?? .balanced)
        options.warmth = Preferences.shared.warmth
        if let frameMs = frameMsOverride { options.audioFrameMs = frameMs }
        options.profile = profileOverride
        let engine = Engine(options: options)
        engine.onStats = { [weak self] stats in
            DispatchQueue.main.async { self?.apply(stats) }
        }
        engine.onStopped = { [weak self] reason in
            DispatchQueue.main.async {
                guard let self, self.engine == nil else { return } // replaced by a newer session
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
        if let headroom = stats.thermalHeadroom {
            // Warn, never throttle on its own: the user decides whether to drop the quality.
            line += headroom < 0.3 ? String(format: " · 🔥 %.2f", headroom)
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
        log("app: setting changed while streaming, restarting (engine=\(engine != nil), receiver=\(receiver.name))")
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
