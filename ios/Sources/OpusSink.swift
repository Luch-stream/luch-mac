// Opus on iOS: the sender that has no PCM — an Android or Linux one — sends Opus packets, and this
// decodes them straight into the same ring buffer the PCM path uses. No transcode: one decode, play.
// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Darwin
import LuchProto
import LuchReceive

final class OpusSink: AudioSink, @unchecked Sendable {
    private let fd: Int32
    private var engine: AVAudioEngine?
    private var source: AVAudioSourceNode?
    private var running = true

    private let lock = NSLock()
    private var ring: [Float] = []
    private var readIndex = 0
    private var played = 0
    private var appended = 0
    private var underruns = 0

    private var decoder: OpaquePointer?
    private var channels = 2
    private var preSkip = 0
    private var targetMs = 60
    private var ringLimit: Int { 48_000 * 2 * targetMs / 1000 }
    private var started = false

    var counters: (appended: Int, played: Int, underruns: Int, queued: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (appended, played, underruns, (ring.count - readIndex) / 2)
    }

    init(fd: Int32) {
        self.fd = fd
        ring.reserveCapacity(ringLimit * 2)
    }

    func start() {
        let setup = {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? session.setPreferredIOBufferDuration(0.005)
            try? session.setActive(true)
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)
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
                if self.readIndex > 8192 {
                    self.ring.removeFirst(self.readIndex)
                    self.readIndex = 0
                }
                self.lock.unlock()
                return noErr
            }
            engine.attach(source)
            engine.connect(source, to: engine.mainMixerNode, format: format)
            self.engine = engine
            self.source = source
        }
        if Thread.isMainThread { setup() } else { DispatchQueue.main.sync(execute: setup) }
        Thread.detachNewThread { [weak self] in self?.readLoop() }
    }

    func stop() {
        running = false
        Darwin.close(fd)
        if let decoder { opus_decoder_destroy(decoder) }
        decoder = nil
        DispatchQueue.main.async {
            self.source.map { self.engine?.detach($0) }
            self.engine?.stop()
        }
    }

    // MARK: - socket

    private var partial: [UInt32: [UInt16: [UInt8]]] = [:]

    private func readLoop() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while running {
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            guard n > Proto.headerSize else {
                if n <= 0 { break }
                continue
            }
            let flags = PacketFlags(rawValue: buffer[1])
            let shard = UInt16(buffer[2]) << 8 | UInt16(buffer[3])
            let shards = UInt16(buffer[4]) << 8 | UInt16(buffer[5])
            let seq = UInt32(buffer[8]) << 24 | UInt32(buffer[9]) << 16
                | UInt32(buffer[10]) << 8 | UInt32(buffer[11])
            let payload = Array(buffer[Proto.headerSize..<n])
            guard shards > 0 else { continue }
            if shards == 1 {
                accept(payload, flags: flags)
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
                accept(frame, flags: flags)
            }
        }
    }

    private func accept(_ packet: [UInt8], flags: PacketFlags) {
        if flags.contains(.config) {
            configure(head: packet)
            return
        }
        play(packet: packet)
    }

    // MARK: - opus

    private func configure(head: [UInt8]) {
        guard head.count >= 19, String(bytes: head[0..<8], encoding: .utf8) == "OpusHead" else { return }
        let channels = max(1, min(2, Int(head[9])))
        let preSkip = Int(head[10]) | (Int(head[11]) << 8)
        lock.lock()
        self.channels = channels
        self.preSkip = preSkip
        if let decoder { opus_decoder_destroy(decoder) }
        var error: Int32 = 0
        decoder = opus_decoder_create(48_000, Int32(channels), &error)
        lock.unlock()
    }

    private func play(packet: [UInt8]) {
        lock.lock()
        guard let decoder else {
            lock.unlock()
            return
        }
        let channels = self.channels
        var skip = self.preSkip
        self.preSkip = 0
        lock.unlock()

        var pcm = [Float](repeating: 0, count: 5760 * 2)
        let samples = opus_decode_float(decoder, packet, Int32(packet.count), &pcm, 5760, 0)
        guard samples > 0 else { return }
        let total = Int(samples)
        let start = min(total, skip)

        lock.lock()
        appended += max(0, total - start)
        for frame in start..<total {
            for channel in 0..<2 {
                let index = frame * channels + min(channel, channels - 1)
                ring.append(pcm[index])
            }
        }
        if ring.count - readIndex > ringLimit {
            underruns += 1
            readIndex = max(0, ring.count - ringLimit)
        }
        lock.unlock()

        startIfNeeded()
    }

    private func startIfNeeded() {
        guard !started, let engine else { return }
        started = true
        let go = {
            do { try engine.start() } catch {
                NSLog("Luch Opus: engine failed: %@", error.localizedDescription)
            }
        }
        if Thread.isMainThread { go() } else { DispatchQueue.main.async(execute: go) }
    }
}
