// What the engine needs from a transport: a way to send access units and control messages.
// UDP and the browser's WebSocket both satisfy it, so the session code does not care which.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// What a sink has done so far, for the stats line.
public struct MediaStats: Sendable {
    public var frames: UInt64
    public var bytes: UInt64
    public var latencySum: UInt64
    public init(frames: UInt64, bytes: UInt64, latencySum: UInt64) {
        self.frames = frames
        self.bytes = bytes
        self.latencySum = latencySum
    }
}

/// One media direction: shards an access unit and hands the datagrams to the wire.
public protocol MediaSink: AnyObject, Sendable {
    @discardableResult
    func send(frame: [UInt8], flags: PacketFlags, ptsUS: UInt32, hostLat: UInt16) -> Int
    func snapshot() -> MediaStats
}

/// The control channel: JSON messages both ways, with a one-way delay estimate.
public protocol ControlLink: AnyObject, Sendable {
    var rttMs: Double { get }
    /// Messages that arrive without being asked for: keyframe requests, the receiver's stats.
    var onEvent: (([String: Any]) -> Void)? { get set }
    @discardableResult func send(_ message: [String: Any]) -> Bool
    func bye()
    /// Blocks until a message of that type arrives (or the timeout).
    func waitFor(_ type: String, timeout: TimeInterval) -> [String: Any]?
}
