// Слой, в который приходят уже декодированные кадры.
// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import LuchReceive
import SwiftUI
import UIKit

/// `enqueue` comes from the decoder thread while `flush` comes from the main actor when a session
/// ends. AVSampleBufferDisplayLayer is not safe for those two at once, so both run on one serial
/// queue; the debug counters are read through the same queue.
final class VideoSurfaceView: UIView, @preconcurrency VideoSink {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let layerQueue = DispatchQueue(label: "dev.luch.video-surface")
    private var enqueuedCount = 0
    private var status = ""
    var onBroken: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = bounds
        layerQueue.sync {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            displayLayer.frame = bounds
            CATransaction.commit()
        }
    }

    var enqueued: Int { layerQueue.sync { enqueuedCount } }
    var lastStatus: String { layerQueue.sync { status } }
    var displayLayerFrame: CGRect { layerQueue.sync { displayLayer.frame } }

    func enqueue(_ sample: CMSampleBuffer) {
        var broke = false
        layerQueue.sync {
            enqueuedCount += 1
            status =
                displayLayer.status == .failed
                ? "failed" : (displayLayer.status == .rendering ? "render" : "wait")
            if displayLayer.status == .failed {
                displayLayer.flush()
                broke = true
            }
            displayLayer.enqueue(sample)
        }
        // Never call back into the app while the layer queue is held: the handler hops to main.
        if broke { onBroken?() }
    }

    func flush() {
        layerQueue.sync { displayLayer.flush() }
    }
}

struct VideoSurface: UIViewRepresentable {
    let onReady: (VideoSurfaceView) -> Void
    var onDismantle: (VideoSurfaceView) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismantle: onDismantle)
    }

    func makeUIView(context: Context) -> VideoSurfaceView {
        let view = VideoSurfaceView()
        onReady(view)
        return view
    }

    func updateUIView(_ view: VideoSurfaceView, context: Context) {}

    static func dismantleUIView(_ view: VideoSurfaceView, coordinator: Coordinator) {
        view.onBroken = nil
        coordinator.onDismantle(view)
    }

    final class Coordinator {
        let onDismantle: (VideoSurfaceView) -> Void

        init(onDismantle: @escaping (VideoSurfaceView) -> Void) {
            self.onDismantle = onDismantle
        }
    }
}
