// The browser as a receiver: its control channel and media sinks ride the same WebSocket.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import LuchNet
import LuchProto

public final class WebClient: @unchecked Sendable {
    public let id: String
    public let name: String
    public let model: String
    public let socket: WebSocketConnection
    /// What the page reported about its screen: the sender plans the frame size from it.
    public let display: (width: Int, height: Int)
    public let welcome: [String: Any]

    public init(socket: WebSocketConnection, hello: [String: Any]) {
        self.socket = socket
        let ua = hello["name"] as? String ?? "Web"
        let model = hello["model"] as? String ?? "browser"
        self.id = "web-\(UUID().uuidString.prefix(8))"
        self.name = "Web · \(model.isEmpty ? ua : model)"
        self.model = model
        let screen = hello["display"] as? [String: Any] ?? [:]
        self.display = (
            width: (screen["width"] as? NSNumber)?.intValue ?? 1920,
            height: (screen["height"] as? NSNumber)?.intValue ?? 1080
        )
        // Browsers: H.264 everywhere, and the page told us how big it wants the picture.
        self.welcome = [
            "t": "welcome", "v": Int(Proto.version),
            "id": "web", "name": Host.current().localizedName ?? "Mac", "app": Proto.app,
            "bench": ["prefer": "video/avc"],
            "hw": [
                "display": [
                    "type": "tv",
                    "current": "\(display.width)x\(display.height)@60",
                    "modes": ["\(display.width)x\(display.height)@60"],
                ],
                "video": ["video/avc": ["max": "1920x1080", "decoder": "webcodecs", "1080p60": true]],
            ],
        ]
    }

    public var receiver: Receiver {
        Receiver(
            id: id, name: name, model: model, address: "127.0.0.1", interfaceName: "lo0",
            interfaceIndex: 0, port: Proto.webPort, service: "web")
    }
}

/// Control over the socket: JSON text frames both ways, with a mailbox for the ones we wait on.
public final class WebControl: ControlLink, @unchecked Sendable {
    private let client: WebClient
    private let lock = NSLock()
    private var inbox: [[String: Any]] = []
    private let arrived = DispatchSemaphore(value: 0)

    public init(client: WebClient) {
        self.client = client
        client.socket.onText = { [weak self] message in
            guard let self else { return }
            lock.lock()
            inbox.append(message)
            lock.unlock()
            arrived.signal()
            self.onEvent?(message)
        }
    }

    public var rttMs: Double { 0 }
    public var onEvent: (([String: Any]) -> Void)?

    @discardableResult
    public func send(_ message: [String: Any]) -> Bool {
        client.socket.send(message)
        return true
    }

    public func bye() {
        client.socket.send(["t": "bye"])
        client.socket.close()
    }

    public func waitFor(_ type: String, timeout: TimeInterval) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            if let index = inbox.firstIndex(where: { ($0["t"] as? String) == type }) {
                let message = inbox.remove(at: index)
                lock.unlock()
                return message
            }
            lock.unlock()
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { break }
            _ = arrived.wait(timeout: .now() + min(left, 0.2))
        }
        return nil
    }
}

/// Media over the socket: the very same datagrams the UDP path writes, one per binary frame.
public final class WebMediaSink: MediaSink, @unchecked Sendable {
    private let client: WebClient
    private let kind: MediaKind
    private let lock = NSLock()
    private var seq: UInt32 = 0
    private var framesSent: UInt64 = 0
    private var bytesSent: UInt64 = 0
    private var latencySum: UInt64 = 0

    public init(client: WebClient, kind: MediaKind) {
        self.client = client
        self.kind = kind
    }

    @discardableResult
    public func send(frame: [UInt8], flags: PacketFlags, ptsUS: UInt32, hostLat: UInt16) -> Int {
        guard !frame.isEmpty else { return 0 }
        let chunks = Proto.shards(frame)
        let shards = UInt16(chunks.count)
        lock.lock()
        let sq = seq
        seq &+= 1
        lock.unlock()

        var packet = [UInt8]()
        packet.reserveCapacity(Proto.headerSize + Proto.shardSize)
        var sent = 0
        for (index, chunk) in chunks.enumerated() {
            packet.removeAll(keepingCapacity: true)
            packet.append(
                contentsOf: Proto.header(
                    kind: kind, flags: flags, shard: UInt16(index), shards: shards,
                    seq: sq, ptsUS: ptsUS, frameLen: UInt32(frame.count), hostLat: hostLat))
            packet.append(contentsOf: chunk)
            client.socket.send(binary: Data(packet))
            sent += 1
        }
        lock.lock()
        framesSent += 1
        bytesSent += UInt64(frame.count)
        latencySum += UInt64(hostLat)
        lock.unlock()
        return sent
    }

    public func snapshot() -> MediaStats {
        lock.lock()
        defer { lock.unlock() }
        return MediaStats(frames: framesSent, bytes: bytesSent, latencySum: latencySum)
    }
}
