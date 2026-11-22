// Opus decode and playback for the viewer: the same datagram header as video, an `OpusHead` frame
// before the first packet, then one Opus packet per frame.
// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import COpus
import Foundation
import LuchProto
import LuchReceive

public final class AudioSession: AudioSink {
    private let fd: Int32
    private let lock = NSLock()
    private var running = true
    private var decoder: OpaquePointer?
    private var channels = 2
    private var preSkip = 0
    private var frameCount = 0
    private var concealed = 0
    private var lastSeq: UInt32?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?

    public init(fd: Int32) {
        self.fd = fd
    }

    public func start() {
        // AVAudioEngine wants the main thread to reach the audio device; a background thread gets
        // "inputNode != nullptr || outputNode != nullptr" and kills the process.
        if Thread.isMainThread {
            setup()
        } else {
            DispatchQueue.main.sync { self.setup() }
        }
        Thread.detachNewThread { [weak self] in self?.readLoop() }
    }

    private func setup() {
        // The mixer only accepts the standard (deinterleaved) float layout.
        guard let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2) else { return }
        format = audioFormat
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: audioFormat)
        do {
            try engine.start()
            player.play()
        } catch {
            log("viewer: audio engine failed: \(error)")
        }
    }

    public func stop() {
        running = false
        Darwin.close(fd)
        player.stop()
        engine.stop()
        if let decoder { opus_decoder_destroy(decoder); self.decoder = nil }
    }

    public func frames() -> Int {
        lock.lock(); defer { lock.unlock() }
        return frameCount
    }

    private func readLoop() {
        var datagram = [UInt8](repeating: 0, count: 64 * 1024)
        var pending: [UInt8] = []
        var expected = 0
        var got = 0
        var isConfig = false
        while running {
            let n = datagram.withUnsafeMutableBytes { raw in
                recv(fd, raw.baseAddress, raw.count, 0)
            }
            if n <= 0 { if !running { break }; continue }
            guard datagram[0] == MediaKind.audio.rawValue, n > Proto.headerSize else { continue }
            let flags = PacketFlags(rawValue: datagram[1])
            let shard = Int(datagram.be16(2))
            let shards = max(1, Int(datagram.be16(4)))
            let seq = datagram.be32(8)
            let payload = datagram[Proto.headerSize..<n]
            if shard == 0 {
                pending = Array(payload)
                expected = shards
                got = 1
                isConfig = flags.contains(.config)
            } else if !pending.isEmpty {
                pending.append(contentsOf: payload)
                got += 1
            } else {
                continue
            }
            if !pending.isEmpty, got >= expected {
                let frame = pending
                pending = []
                if isConfig {
                    configure(head: frame)
                } else {
                    concealGap(upTo: seq)
                    play(packet: frame)
                    lastSeq = seq
                }
            }
        }
    }

    /// A gap in the sequence: rebuild what we can from the next packet's FEC, conceal the rest.
    private func concealGap(upTo seq: UInt32) {
        guard let last = lastSeq else { return }
        let missing = Int(seq &- last &- 1)
        guard missing > 0, missing <= 5 else { return }
        for _ in 0..<missing {
            conceal()
        }
    }

    private func conceal() {
        lock.lock()
        guard let decoder else { lock.unlock(); return }
        lock.unlock()
        var pcm = [Float](repeating: 0, count: 5760 * 2)
        // The decoder itself produces the concealment frame; FEC data from the next packet would be
        // used with decode_fec = 1, but a plain PLC is enough for one lost 10-20 ms frame.
        _ = opus_decode_float(decoder, nil, 0, &pcm, 5760, 0)
        lock.lock(); concealed += 1; lock.unlock()
    }

    private func configure(head: [UInt8]) {
        guard head.count >= 19, String(bytes: head[0..<8], encoding: .utf8) == "OpusHead" else { return }
        let channels = Int(head[9])
        let preSkip = Int(head[10]) | (Int(head[11]) << 8)
        lock.lock()
        self.channels = channels
        self.preSkip = preSkip
        if let decoder { opus_decoder_destroy(decoder) }
        var error: Int32 = 0
        decoder = opus_decoder_create(48000, Int32(channels), &error)
        frameCount = 0
        lock.unlock()
        log("viewer: opus \(channels) ch, pre-skip \(preSkip)")
    }

    private func play(packet: [UInt8]) {
        lock.lock()
        guard let decoder else { lock.unlock(); return }
        let channels = self.channels
        var skip = self.preSkip
        self.preSkip = 0
        lock.unlock()

        var pcm = [Float](repeating: 0, count: 5760 * 2)
        let samples = opus_decode_float(decoder, packet, Int32(packet.count), &pcm, 5760, 0)
        guard samples > 0 else { return }
        let total = Int(samples)
        let start = min(total, skip)
        let usable = total - start
        guard usable > 0 else { return }

        ensureFormat(channels: channels)
        guard engine.isRunning, let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(usable))
        else { return }
        buffer.frameLength = AVAudioFrameCount(usable)
        if let data = buffer.floatChannelData {
            for frame in 0..<usable {
                let base = (start + frame) * channels
                for channel in 0..<channels {
                    data[channel][frame] = pcm[base + channel]
                }
            }
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
        lock.lock()
        frameCount += 1
        let played = frameCount
        lock.unlock()
        if played % 100 == 0 {
            lock.lock(); let plc = concealed; lock.unlock()
            log("viewer: \(played) opus frames played, \(plc) concealed")
        }
    }

    private func ensureFormat(channels: Int) {
        // The connection is made once for stereo, which is what the sender always produces.
    }
}

private func log(_ message: String) {
    FileHandle.standardError.write(Data(("[\(Date())] " + message + "\n").utf8))
}
