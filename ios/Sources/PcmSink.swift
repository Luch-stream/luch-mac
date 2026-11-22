// Audio on iOS: the sender gives this device raw PCM, so playback is a buffer into AVAudioEngine
// with no codec in the path.
// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Darwin
import LuchProto
import LuchReceive

final class PcmSink: AudioSink, @unchecked Sendable {
    private let fd: Int32
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var running = true
    private let lock = NSLock()
    private var framed = 0

    init(fd: Int32) {
        self.fd = fd
    }

    func start() {
        // The engine has to be reached from the main thread; a background thread kills the process.
        let setup = {
            guard let pcm = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else { return }
            self.format = pcm
            self.engine.attach(self.player)
            self.engine.connect(self.player, to: self.engine.mainMixerNode, format: pcm)
            do {
                try self.engine.start()
                self.player.play()
            } catch {
                NSLog("Luch PCM: engine failed: %@", error.localizedDescription)
            }
        }
        if Thread.isMainThread { setup() } else { DispatchQueue.main.sync(execute: setup) }
        Thread.detachNewThread { [weak self] in self?.readLoop() }
    }

    func stop() {
        running = false
        close(fd)
        DispatchQueue.main.async {
            self.player.stop()
            self.engine.stop()
        }
    }

    private func readLoop() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while running {
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            guard n > Proto.headerSize else {
                if n <= 0 { break }
                continue
            }
            // 24-byte header, then the payload this frame's length says.
            let length = Int(buffer[16]) << 24 | Int(buffer[17]) << 16 | Int(buffer[18]) << 8 | Int(buffer[19])
            let start = Proto.headerSize
            let end = min(n, start + max(0, length))
            guard end > start else { continue }
            let payload = Array(buffer[start..<end])
            play(payload)
        }
    }

    private func play(_ pcmInt16: [UInt8]) {
        guard let format else { return }
        let frames = pcmInt16.count / 4  // two channels of two bytes
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard let channel = buffer.floatChannelData else { return }
        for index in 0..<frames {
            let left = Int16(bitPattern: UInt16(pcmInt16[index * 4]) | UInt16(pcmInt16[index * 4 + 1]) << 8)
            let right = Int16(bitPattern: UInt16(pcmInt16[index * 4 + 2]) | UInt16(pcmInt16[index * 4 + 3]) << 8)
            channel[0][index] = Float(left) / 32768.0
            channel[1][index] = Float(right) / 32768.0
        }
        lock.lock()
        framed += 1
        lock.unlock()
        player.scheduleBuffer(buffer, completionHandler: nil)
    }
}
