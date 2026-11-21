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
    private var videoView: VideoView!
    private var statusItem: NSStatusItem!
    private var receiver: Receiver!
    private var acceptItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildWindow()
        buildMenu()

        videoView.onBroken = { [weak self] in self?.receiver?.requestKeyframe() }
        receiver = Receiver(name: Host.current().localizedName ?? "Mac", sink: videoView)
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
        videoView = VideoView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Luch — waiting for a sender"
        window.contentView = videoView
        window.backgroundColor = .black
        window.center()
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
            window.makeKeyAndOrderFront(nil)
            statusItem.button?.title = "Luch ●"
            statusItem.menu?.item(withTag: 1)?.title = "Mirroring \(sender)"
        } else {
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
