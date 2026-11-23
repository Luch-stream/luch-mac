// The receiver's presentation state: discovery, the live session, and the numbers the HUD shows.
// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import Foundation
import LuchReceive
import Observation
import UIKit

/// Frames go to whichever view is on screen right now: SwiftUI may recreate it, and the receiver
/// keeps a stable sink instead of a view that may already be gone.
final class VideoRelay: VideoSink {
    weak var view: VideoSurfaceView?
    func enqueue(_ sample: CMSampleBuffer) { view?.enqueue(sample) }
    func flush() { view?.flush() }
}

/// Owns the receiver and exposes only what the interface needs. Networking threads never touch the
/// published state directly: they hand values to the main actor, which is what SwiftUI observes.
@MainActor
@Observable
final class Viewer {
    enum Phase: Equatable {
        case waiting
        case streaming
        case ended
        case failed
    }

    private(set) var phase: Phase = .waiting
    /// The sender's name as the protocol reports it; a neutral label when it reports only a mode.
    private(set) var senderName = ""
    private(set) var fps: Double = 0
    private(set) var latencyMs: Double = 0
    private(set) var lostFrames = 0
    /// Senders this device can see right now, from mDNS. Mirrored here so the UI observes it.
    private(set) var senders: [SenderBrowser.Sender] = []

    @ObservationIgnored let relay = VideoRelay()
    /// Weak: SwiftUI owns the view, and a session must not keep a dismantled one alive.
    @ObservationIgnored private weak var surface: VideoSurfaceView?
    @ObservationIgnored private var audio: PcmSink?
    @ObservationIgnored private var receiver: Receiver?
    @ObservationIgnored let browser = SenderBrowser()
    @ObservationIgnored private var senderTask: Task<Void, Never>?
    /// A session exists but the interface may already be back on the waiting screen.
    @ObservationIgnored private var sessionActive = false

    // MARK: - lifecycle

    func start() {
        // First launch: find out how fast this phone decodes, so senders can pick the codec.
        DecoderBench.runIfNeeded()
        if senderTask == nil {
            senderTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for await list in self.browser.updates() {
                    self.senders = list
                    print("sender-browser: ui list \(list.count)")
                }
            }
        }
        browser.start()
        guard receiver == nil else { return }
        // Sockets and the Bonjour registration are slow; the first frame must not wait for them.
        // The receiver is built here (it needs the device name), but it listens on its own queue:
        // opening sockets and registering on Bonjour must never block the first frame.
        begin(deviceName: UIDevice.current.name)
    }

    private func begin(deviceName: String) {
        guard receiver == nil else { return }
        let receiver = Receiver(
            name: deviceName, sink: relay, audioCodecs: CodecSettings.audio.codecs,
            videoPreference: CodecSettings.video.codec)
        receiver.makeAudio = { [weak self] fd in
            let sink = PcmSink(fd: fd)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.audio = sink }
            }
            return sink
        }
        receiver.onSession = { [weak self] sender in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.sessionChanged(sender) }
            }
        }
        receiver.onStats = { [weak self] stats in
            let fps = stats.fps
            let decodeMs = stats.decodeMs
            let lost = stats.lost
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.statsChanged(fps: fps, decodeMs: decodeMs, lost: lost) }
            }
        }
        receiver.onError = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.failedToStart() }
            }
        }
        self.receiver = receiver
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try receiver.start()
            } catch {
                // The port or the Bonjour registration is unavailable; retrying recreates it.
                await MainActor.run { self?.phase = .failed }
            }
        }
    }

    /// The view only shows frames; the receiver lives independently, so a view that is not on
    /// screen yet does not stop the device from being discoverable.
    func attach(_ view: VideoSurfaceView) {
        surface = view
        relay.view = view
        view.onBroken = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receiver?.requestKeyframe() }
            }
        }
    }

    /// Called when SwiftUI tears the surface down. Only our own view is cleared: a newer view may
    /// already have attached while the old one is still being dismantled.
    func detach(_ view: VideoSurfaceView) {
        guard surface === view else { return }
        surface = nil
        if relay.view === view {
            relay.view = nil
        }
    }

    // MARK: - debug launch

    /// Fills the presentation state for a `-luchUI` launch. The receiver is never created, so the
    /// session, the network and the audio path stay untouched; the numbers are the plausible values
    /// the HUD shows during a real session.
    func applyDebugLaunch(_ state: UIDebugLaunch.State) {
        resetStats()
        switch state {
        case .waiting, .settings:
            phase = .waiting
        case .streaming, .streamingHidden:
            senderName = "MacBook Pro — iQqator"
            fps = 52
            latencyMs = 14
            phase = .streaming
        case .ended:
            phase = .ended
        case .error:
            phase = .failed
        }
    }

    // MARK: - actions

    func requestKeyframe() {
        receiver?.requestKeyframe()
    }

    /// "Отключиться": hide the picture and go back to discovery. The receiver stays advertised; it
    /// only ends the live session and tells the sender to stop, so no Bonjour re-registration races
    /// with a sender that is still connected.
    func disconnect() {
        let wasStreaming = sessionActive
        sessionActive = false
        relay.flush()
        surface = nil
        relay.view = nil
        resetStats()
        UIApplication.shared.isIdleTimerDisabled = false
        phase = .waiting
        if wasStreaming {
            receiver?.stopSession()
        }
    }

    /// "Искать снова": after a finished session the listener never stopped, so only the screen
    /// changes. After a failed start there is no receiver left, so build one.
    func searchAgain() {
        resetStats()
        phase = .waiting
        if receiver == nil {
            start()
        }
    }

    // MARK: - receiver callbacks (already on the main actor)

    private func sessionChanged(_ sender: String?) {
        if let sender {
            sessionActive = true
            senderName = Self.displayName(for: sender)
            resetStats()
            UIApplication.shared.isIdleTimerDisabled = true
            phase = .streaming
        } else {
            let wasStreaming = sessionActive
            sessionActive = false
            relay.flush()
            relay.view = nil
            surface = nil
            UIApplication.shared.isIdleTimerDisabled = false
            guard wasStreaming else { return }
            resetStats()
            phase = .ended
        }
    }

    private func statsChanged(fps: Double, decodeMs: Double, lost: Int) {
        guard sessionActive else { return }
        self.fps = fps
        latencyMs = decodeMs
        lostFrames += lost
    }

    private func failedToStart() {
        sessionActive = false
        UIApplication.shared.isIdleTimerDisabled = false
        resetStats()
        phase = .failed
    }

    private func resetStats() {
        fps = 0
        latencyMs = 0
        lostFrames = 0
    }

    /// The control channel carries the mirroring mode ("mirror"), not a device name, so show a
    /// human label rather than a protocol token when there is nothing better.
    private static func displayName(for sender: String) -> String {
        let name = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        let generic: Set<String> = ["", "mirror", "sender", "none"]
        return generic.contains(name.lowercased()) ? "Компьютер" : name
    }
}

#if DEBUG
extension Viewer {
    /// Previews need senders without waiting for mDNS; the setter is file-private, so the seed lives here.
    func seedPreviewSenders(_ names: [String]) {
        senders = names.map { SenderBrowser.Sender(id: $0, name: $0) }
    }

    func seedPreviewStreaming(sender: String, fps: Double = 60, latency: Double = 12) {
        phase = .streaming
        senderName = sender
        self.fps = fps
        latencyMs = latency
    }
}
#endif
