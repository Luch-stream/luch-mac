// The latency pattern: a full-screen timer with millisecond digits, a frame counter and a QR that
// identifies the session. A camera filming this screen and the receiver at 240 fps gives the real
// photon-to-photon latency, instead of a guess from the sending side.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreImage
import LuchProto

final class LatencyWindow {
    private var window: NSWindow?
    private var view: LatencyView?
    private var timer: Timer?
    private var escapeMonitor: Any?
    private let start = Date()
    private var frames = 0

    var isVisible: Bool { window != nil }

    func show(on screen: NSScreen?) {
        close()
        guard let target = screen ?? NSScreen.main else { return }
        // A normal window: the person must always be able to close it, even while it covers the screen.
        let window = NSWindow(
            contentRect: target.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Luch — latency test (Esc closes)"
        window.level = .normal
        window.backgroundColor = .black
        window.isOpaque = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.collectionBehavior = [.canJoinAllSpaces]
        let view = LatencyView(frame: NSRect(origin: .zero, size: target.frame.size))
        view.sessionText = Protokoll.sessionID
        view.qr = LatencyWindow.qrCode(Protokoll.sessionID)
        view.onEscape = { [weak self] in self?.close() }
        window.contentView = view
        window.setFrame(target.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
        self.view = view

        // 120 Hz: one tick per display refresh, so the digits move as fast as the picture can.
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            guard let self, let view = self.view else { return }
            self.frames += 1
            view.elapsed = Date().timeIntervalSince(self.start)
            view.frameNumber = self.frames
            view.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // Esc must always work, whatever has focus: a local monitor sees the key before the window does.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible, event.keyCode == 53 else { return event }
            self.close()
            return nil
        }
    }

    func close() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
        window = nil
        view = nil
    }

    private static func qrCode(_ text: String) -> NSImage? {
        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(Data(text.utf8), forKey: "inputMessage")
        filter?.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter?.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 240, height: 240))
    }
}

enum Protokoll {
    /// Identifies this sender in the recording, so a report can name the hardware it measured.
    static let sessionID: String = {
        if let saved = UserDefaults.standard.string(forKey: "latency.session") { return saved }
        let made = "luch-\(UUID().uuidString.prefix(8))"
        UserDefaults.standard.set(made, forKey: "latency.session")
        return made
    }()
}

final class LatencyView: NSView {
    var onEscape: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // Esc
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    var elapsed: TimeInterval = 0
    var frameNumber = 0
    var sessionText = ""
    var qr: NSImage?

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        let width = bounds.width

        // Milliseconds matter: the camera sees a different value on each screen.
        let total = elapsed
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        let seconds = Int(total) % 60
        let millis = Int((total - floor(total)) * 1000)
        let clock = String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, millis)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: width * 0.11, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let text = NSAttributedString(string: clock, attributes: attributes)
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: bounds.height * 0.58))

        let sub: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: width * 0.03, weight: .medium),
            .foregroundColor: NSColor(white: 0.75, alpha: 1),
        ]
        NSAttributedString(string: "frame \(frameNumber) · \(sessionText)", attributes: sub)
            .draw(at: NSPoint(x: width * 0.03, y: bounds.height * 0.08))

        // A border that flips every frame: counting the flips in the recording dates a frame exactly.
        let flip = frameNumber % 2 == 0
        (flip ? NSColor.white : NSColor(white: 0.25, alpha: 1)).setFill()
        NSRect(x: 0, y: 0, width: width * 0.02, height: bounds.height).fill()

        qr?.draw(in: NSRect(x: width * 0.03, y: bounds.height * 0.72, width: 220, height: 220))
    }
}
