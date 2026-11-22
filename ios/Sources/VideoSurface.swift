// Слой, в который приходят уже декодированные кадры.
// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import LuchReceive
import SwiftUI
import UIKit

final class VideoSurfaceView: UIView, @preconcurrency VideoSink {
    private let displayLayer = AVSampleBufferDisplayLayer()
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    var enqueued = 0
    var lastStatus = ""
    var displayLayerFrame: CGRect { displayLayer.frame }

    func enqueue(_ sample: CMSampleBuffer) {
        enqueued += 1
        lastStatus = displayLayer.status == .failed ? "failed" : (displayLayer.status == .rendering ? "render" : "wait")
        if displayLayer.status == .failed {
            displayLayer.flush()
            onBroken?()
        }
        displayLayer.enqueue(sample)
    }

    func flush() {
        displayLayer.flush()
    }
}

struct VideoSurface: UIViewRepresentable {
    let onReady: (VideoSurfaceView) -> Void

    func makeUIView(context: Context) -> VideoSurfaceView {
        let view = VideoSurfaceView()
        onReady(view)
        return view
    }

    func updateUIView(_ view: VideoSurfaceView, context: Context) {}
}
