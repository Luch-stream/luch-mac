// Luch Viewer — the Mac as a receiver: a window with the incoming picture and a menu bar item.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AVFoundation
import LuchReceive

final class VideoView: NSView, VideoSink {
    private let displayLayer = AVSampleBufferDisplayLayer()
    var onBroken: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.isOpaque = true
    }

    required init?(coder: NSCoder) { nil }

    override func makeBackingLayer() -> CALayer { displayLayer }

    private let snapshot = Snapshot()
    private var firstSample = true
    private var enqueued = 0

    func enqueue(_ sample: CMSampleBuffer) {
        if firstSample {
            firstSample = false
            FileHandle.standardError.write(Data("viewer: first sample enqueued\n".utf8))
        }
        enqueued += 1
        if enqueued % 60 == 0 {
            let status = displayLayer.status.rawValue
            let error = displayLayer.error?.localizedDescription ?? "none"
            FileHandle.standardError.write(Data("viewer: \(enqueued) samples, layer status \(status) (\(error))\n".utf8))
        }
        snapshot.maybeSave(sample)
        if displayLayer.status == .failed {
            displayLayer.flush()
            onBroken?()
        }
        displayLayer.enqueue(sample)
    }

    func flush() {
        FileHandle.standardError.write(Data("viewer: flush (waiting for a keyframe)\n".utf8))
        displayLayer.flush()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var container: NSView!
    private var videoView: VideoView!
    private var statsLabel: NSTextField!
    private var statsItem: NSMenuItem!
    private var topItem: NSMenuItem!
    private var statusItem: NSStatusItem!
    private var receiver: Receiver!
    private var acceptItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildWindow()
        buildMenu()

        videoView.onBroken = { [weak self] in self?.receiver?.requestKeyframe() }
        receiver = Receiver(name: Host.current().localizedName ?? "Mac", sink: videoView)
        receiver.onStats = { [weak self] stats in
            DispatchQueue.main.async {
                guard let label = self?.statsLabel else { return }
                label.stringValue = String(format: "%@  %.0f fps · dec %.1f ms · lost %d · dropped %d",
                                           label.isHidden ? "" : "", stats.fps, stats.decodeMs,
                                           stats.lost, stats.dropped)
            }
        }
        receiver.onSession = { [weak self] sender in
            DispatchQueue.main.async {
                self?.update(sender: sender)
            }
        }
        receiver.onError = { message in
            FileHandle.standardError.write(Data(("viewer: \(message)\n").utf8))
        }
        do {
            try receiver.start()
        } catch {
            present(error: "Could not start receiving: \(error.localizedDescription)")
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - UI

    private func buildWindow() {
        container = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        videoView = VideoView(frame: container.bounds)
        videoView.autoresizingMask = [.width, .height]
        container.addSubview(videoView)

        statsLabel = NSTextField(labelWithString: "")
        statsLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        statsLabel.textColor = .white
        statsLabel.wantsLayer = true
        statsLabel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        statsLabel.frame = NSRect(x: 16, y: container.bounds.height - 34, width: 420, height: 20)
        statsLabel.autoresizingMask = [.minYMargin, .width]
        statsLabel.isHidden = true
        container.addSubview(statsLabel)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Luch — waiting for a sender"
        window.contentView = container
        window.backgroundColor = .black
        window.center()
        window.setFrameAutosaveName("LuchViewerWindow")
        window.makeKeyAndOrderFront(nil)
        window.orderOut(nil)
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Luch"

        let menu = NSMenu()
        let status = NSMenuItem(title: "Waiting for a sender", action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.tag = 1
        menu.addItem(status)

        acceptItem = NSMenuItem(title: "Accept senders", action: #selector(toggleAccept), keyEquivalent: "")
        acceptItem.state = .on
        acceptItem.target = self
        menu.addItem(acceptItem)

        topItem = NSMenuItem(title: "Always on top", action: #selector(toggleTop), keyEquivalent: "t")
        topItem.target = self
        topItem.state = UserDefaults.standard.bool(forKey: "alwaysOnTop") ? .on : .off
        if topItem.state == .on { window.level = .floating }
        menu.addItem(topItem)

        statsItem = NSMenuItem(title: "Show stats", action: #selector(toggleStats), keyEquivalent: "s")
        statsItem.target = self
        statsItem.state = .off
        menu.addItem(statsItem)

        let full = NSMenuItem(title: "Toggle full screen", action: #selector(toggleFullScreen), keyEquivalent: "f")
        full.target = self
        menu.addItem(full)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Luch Viewer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func update(sender: String?) {
        if let sender {
            window.title = "Luch — \(sender)"
            NSApp.requestUserAttention(.informationalRequest)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            statusItem.button?.title = "Luch ●"
            statusItem.menu?.item(withTag: 1)?.title = "Mirroring \(sender)"
        } else {
            window.title = "Luch — waiting for a sender"
            statusItem.button?.title = "Luch"
            statusItem.menu?.item(withTag: 1)?.title = receiver?.accepting == true ? "Waiting for a sender" : "Not accepting"
        }
    }

    @objc private func toggleAccept() {
        receiver.accepting.toggle()
        acceptItem.state = receiver.accepting ? .on : .off
        if receiver.accepting {
            statusItem.menu?.item(withTag: 1)?.title = "Waiting for a sender"
        }
    }

    @objc private func toggleTop() {
        let on = !UserDefaults.standard.bool(forKey: "alwaysOnTop")
        UserDefaults.standard.set(on, forKey: "alwaysOnTop")
        topItem.state = on ? .on : .off
        window.level = on ? .floating : .normal
    }

    @objc private func toggleStats() {
        statsLabel.isHidden.toggle()
        statsItem.state = statsLabel.isHidden ? .off : .on
    }

    @objc private func toggleFullScreen() {
        window.toggleFullScreen(nil)
    }

    private func present(error: String) {
        let alert = NSAlert()
        alert.messageText = "Luch Viewer"
        alert.informativeText = error
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
