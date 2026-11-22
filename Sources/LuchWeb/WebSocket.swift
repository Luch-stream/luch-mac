// A server-side WebSocket: the handshake and the frames, over one Network connection.
// The Network framework only speaks WebSocket as a client, so the server side is done by hand.
// SPDX-License-Identifier: GPL-3.0-or-later
import CommonCrypto
import Foundation
import Network

public final class WebSocketConnection: MessageSocket, @unchecked Sendable {
    public var onText: (([String: Any]) -> Void)?
    public var onClosed: (() -> Void)?

    private let connection: NWConnection
    private var buffer = Data()
    private let queue = DispatchQueue(label: "luch.web.socket")
    private var closed = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    /// The `Sec-WebSocket-Accept` value for the client's key.
    static func accept(for key: String) -> String {
        let magic = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        let data = Data(magic.utf8)
        data.withUnsafeBytes { raw in
            _ = CC_SHA1(raw.baseAddress, CC_LONG(data.count), &digest)
        }
        return Data(digest).base64EncodedString()
    }

    public func start() {
        receive()
    }

    /// Bytes that arrived together with the handshake request.
    func inject(_ data: Data) {
        buffer.append(data)
        drain()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] data, _, done, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drain()
            }
            if done || error != nil {
                self.finish()
                return
            }
            self.receive()
        }
    }

    private func drain() {
        while let frame = nextFrame() {
            switch frame.opcode {
            case 0x1:
                if let object = try? JSONSerialization.jsonObject(with: frame.payload),
                    let message = object as? [String: Any]
                {
                    onText?(message)
                }
            case 0x2:
                break  // media flows one way; a browser has nothing to send us
            case 0x8:
                finish()
                return
            case 0x9:
                write(opcode: 0xA, payload: frame.payload)
            default:
                break
            }
        }
    }

    private func nextFrame() -> (opcode: UInt8, payload: Data)? {
        guard buffer.count >= 2 else { return nil }
        let bytes = [UInt8](buffer)
        let opcode = bytes[0] & 0x0F
        let masked = bytes[1] & 0x80 != 0
        var length = Int(bytes[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[2]) << 8 | Int(bytes[3])
            offset = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            var value = 0
            for index in 2..<10 { value = value << 8 | Int(bytes[index]) }
            length = value
            offset = 10
        }
        let maskSize = masked ? 4 : 0
        guard bytes.count >= offset + maskSize + length else { return nil }
        var payload = Data(bytes[(offset + maskSize)..<(offset + maskSize + length)])
        if masked {
            let mask = Array(bytes[offset..<(offset + 4)])
            payload = Data(payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        }
        buffer.removeFirst(offset + maskSize + length)
        return (opcode, payload)
    }

    public func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        write(opcode: 0x1, payload: data)
    }

    public func send(binary data: Data) {
        write(opcode: 0x2, payload: data)
    }

    public func close() {
        write(opcode: 0x8, payload: Data())
        connection.cancel()
        finish()
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        onClosed?()
    }

    private func write(opcode: UInt8, payload: Data) {
        guard !closed else { return }
        var frame = Data([0x80 | opcode])
        let size = payload.count
        if size < 126 {
            frame.append(UInt8(size))
        } else if size <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8(size >> 8))
            frame.append(UInt8(size & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((size >> shift) & 0xFF))
            }
        }
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }
}
