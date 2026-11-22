// Audio on iOS: raw PCM from the sender, pulled by the audio thread through a ring buffer, so the
// sound never depends on how evenly the packets happened to arrive.
// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Darwin
import LuchProto
import LuchReceive

final class PcmSink: AudioSink, @unchecked Sendable {
    private let fd: Int32
    private let sampleRate = 48_000.0
    private let channels = 2
    private var engine: AVAudioEngine?
    private var source: AVAudioSourceNode?
    private var running = true

    private let lock = NSLock()
    private var ring: [Float] = []
    private var readIndex = 0
    private var underruns = 0
    private var played = 0
    private var appended = 0

    /// Counters for the on-screen status line: what arrived, what was rendered, what was missing.
    var counters: (appended: Int, played: Int, underruns: Int, queued: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (appended, played, underruns, (ring.count - readIndex) / 2)
    }

    /// Height of the ring: enough to ride out Wi-Fi jitter without adding a visible delay.
    private let ringLimit = 48_000 * 2 / 4  // a quarter of a second of stereo samples

    init(fd: Int32) {
        self.fd = fd
        ring.reserveCapacity(ringLimit * 2)
    }

    func start() {
        // The engine must be built on the main thread; a background thread kills the process.
        let setup = {
            // Without a session the engine has no proper output route, and the sound arrives as clicks.
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try? session.setPreferredIOBufferDuration(0.005)
            try? session.setActive(true)
            guard let format = AVAudioFormat(standardFormatWithSampleRate: self.sampleRate, channels: 2)
            else { return }
            let engine = AVAudioEngine()
            let source = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
                guard let self else { return noErr }
                let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
                self.lock.lock()
                for frame in 0..<Int(frameCount) {
                    let left: Float
                    let right: Float
                    if self.readIndex + 1 < self.ring.count {
                        left = self.ring[self.readIndex]
                        right = self.ring[self.readIndex + 1]
                        self.readIndex += 2
                    } else {
                        left = 0
                        right = 0
                        self.underruns += 1
                    }
                    self.played += 1
                    for (channel, buffer) in buffers.enumerated() {
                        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                        data[frame] = channel == 0 ? left : right
                    }
                }
                // Reclaim what has been played.
                if self.readIndex > 8192 {
                    self.ring.removeFirst(self.readIndex)
                    self.readIndex = 0
                }
                self.lock.unlock()
                return noErr
            }
            engine.attach(source)
            engine.connect(source, to: engine.mainMixerNode, format: format)
            do {
                try engine.start()
            } catch {
                NSLog("Luch PCM: engine failed: %@", error.localizedDescription)
            }
            self.engine = engine
            self.source = source
        }
        if Thread.isMainThread { setup() } else { DispatchQueue.main.sync(execute: setup) }
        Thread.detachNewThread { [weak self] in self?.readLoop() }
    }

    func stop() {
        running = false
        close(fd)
        DispatchQueue.main.async {
            self.source.map { self.engine?.detach($0) }
            self.engine?.stop()
        }
    }

    /// A PCM frame is bigger than one datagram, so the shards are joined before anything is played.
    private var partial: [UInt32: [UInt16: [UInt8]]] = [:]

    private func readLoop() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while running {
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            guard n > Proto.headerSize else {
                if n <= 0 { break }
                continue
            }
            let shard = UInt16(buffer[2]) << 8 | UInt16(buffer[3])
            let shards = UInt16(buffer[4]) << 8 | UInt16(buffer[5])
            let seq = UInt32(buffer[8]) << 24 | UInt32(buffer[9]) << 16 | UInt32(buffer[10]) << 8 | UInt32(buffer[11])
            let payload = Array(buffer[Proto.headerSize..<n])
            guard shards > 0 else { continue }
            if shards == 1 {
                append(payload)
                continue
            }
            partial[seq, default: [:]][shard] = payload
            if partial[seq]?.count == Int(shards) {
                var frame: [UInt8] = []
                for index in 0..<Int(shards) {
                    if let part = partial[seq]?[UInt16(index)] { frame.append(contentsOf: part) }
                }
                partial[seq] = nil
                if partial.count > 32 { partial.removeAll() }
                append(frame)
            }
        }
    }

    private func append(_ int16: [UInt8]) {
        let frames = int16.count / 4
        guard frames > 0 else { return }
        lock.lock()
        appended += frames
        for index in 0..<frames {
            let left = Int16(bitPattern: UInt16(int16[index * 4]) | UInt16(int16[index * 4 + 1]) << 8)
            let right = Int16(bitPattern: UInt16(int16[index * 4 + 2]) | UInt16(int16[index * 4 + 3]) << 8)
            ring.append(Float(left) / 32768.0)
            ring.append(Float(right) / 32768.0)
        }
        // A lagging ring would turn into delay, so the oldest samples go first.
        if ring.count - readIndex > ringLimit { underruns += 1; readIndex = max(0, ring.count - ringLimit) }
        lock.unlock()
    }
}
