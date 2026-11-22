// The broadcast extension: ReplayKit hands it the screen, the encoder turns it into frames and the
// sender pushes them. It asks the app where to send through a loopback socket, so no App Group and
// no extra entitlement is needed for a local build.
// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import ReplayKit
import VideoToolbox

final class SampleHandler: RPBroadcastSampleHandler {
    private var encoder: ScreenEncoder?
    private var session: SendSession?
    private var started = false
    private var target: SendTarget?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        // The size comes from the first frame: hardcoding it would letterbox or crop on any other
        // device. Only the destination is known up front.
        guard let config = Self.fetchConfig() else {
            finish(reason: "Приложение Luch не выбрало приёмник")
            return
        }
        self.target = SendTarget(
            id: config.host, name: config.name, host: config.host, port: config.port, model: "")
        started = true
    }

    /// Built on the first frame, when the real capture size is known.
    private func startEncoding(width: Int, height: Int) {
        guard let target, encoder == nil else { return }
        // A capture above 1080p is downscaled by the encoder's own limit: 1920 wide is enough for
        // a mirror and keeps the phone cool.
        let scale = min(1.0, 1920.0 / Double(width))
        let outWidth = max(2, Int((Double(width) * scale) / 2) * 2)
        let outHeight = max(2, Int((Double(height) * scale) / 2) * 2)
        guard let encoder = ScreenEncoder(width: outWidth, height: outHeight, fps: 60, bitrate: 12_000_000)
        else {
            finish(reason: "Энкодер недоступен")
            return
        }
        let session = SendSession()
        encoder.onFrame = { [weak session] frame, pts, keyframe in
            session?.sendVideo(frame, ptsUS: pts, keyframe: keyframe)
        }
        session.start(to: target, name: "iPhone", width: outWidth, height: outHeight, fps: 60)
        self.encoder = encoder
        self.session = session
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard started, sampleBufferType == .video else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if encoder == nil {
            startEncoding(
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer))
        }
        guard let encoder else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        encoder.encode(pixelBuffer, ptsUS: UInt32(max(0, pts.seconds * 1_000_000)))
    }

    override func broadcastFinished() {
        encoder?.invalidate()
        encoder = nil
        session?.stop()
        session = nil
        started = false
    }

    private func finish(reason: String) {
        let error = NSError(
            domain: "dev.luch.broadcast", code: 1,
            userInfo: [NSLocalizedDescriptionKey: reason])
        finishBroadcastWithError(error)
    }

    /// The app answers with one JSON line: where to send the picture.
    private static func fetchConfig() -> (host: String, port: UInt16, name: String)? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(47_899).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = recv(fd, &buffer, buffer.count, 0)
        guard count > 0,
            let object = try? JSONSerialization.jsonObject(with: Data(buffer[0..<count]))
                as? [String: Any],
            let host = object["host"] as? String,
            let port = object["port"] as? Int, port > 0
        else { return nil }
        return (host, UInt16(port), object["name"] as? String ?? "receiver")
    }
}
