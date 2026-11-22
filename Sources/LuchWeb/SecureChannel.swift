// Application-level encryption for the plain-HTTP page: the pairing code the TV shows becomes the
// key, every message after the handshake is AES-GCM sealed, and a nonce that must only grow stops
// replays. TLS is not needed, so no certificate has to be trusted on the device.
// SPDX-License-Identifier: GPL-3.0-or-later
import CommonCrypto
import CryptoKit
import Foundation

/// What both ends need from a socket, so an encrypted one can stand in for a plain one.
public protocol MessageSocket: AnyObject, Sendable {
    var onText: (([String: Any]) -> Void)? { get set }
    var onClosed: (() -> Void)? { get set }
    func send(_ message: [String: Any])
    func send(binary data: Data)
    func close()
}

public enum SecureChannelError: Error, LocalizedError {
    case short
    case replay
    case broken(String)

    public var errorDescription: String? {
        switch self {
        case .short: return "encrypted message is too short"
        case .replay: return "encrypted message reused a nonce"
        case .broken(let why): return "cannot decrypt: \(why)"
        }
    }
}

public final class SecureChannel: @unchecked Sendable {
    private let key: SymmetricKey
    private let lock = NSLock()
    private var sendCounter: UInt64 = 0
    private var lastReceived: UInt64?
    private let prefix: [UInt8]

    /// The pairing code is stretched with PBKDF2 the same way the page does it.
    public init(code: String, salt: Data, iterations: Int = 100_000) {
        var derived = [UInt8](repeating: 0, count: 32)
        let password = Array(code.utf8)
        salt.withUnsafeBytes { raw in
            _ = CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), password, password.count,
                raw.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                &derived, derived.count)
        }
        self.key = SymmetricKey(data: Data(derived))
        var random = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, 4, &random)
        self.prefix = random
    }

    public func seal(_ plain: Data) -> Data {
        lock.lock()
        let counter = sendCounter
        sendCounter += 1
        lock.unlock()
        var nonce = Data(prefix)
        nonce.append(contentsOf: withUnsafeBytes(of: counter.bigEndian) { Data($0) })
        guard let box = try? AES.GCM.seal(plain, using: key, nonce: try? AES.GCM.Nonce(data: nonce)),
            let combined = box.combined
        else {
            return Data()
        }
        // `combined` already carries the 12-byte nonce in front of the ciphertext.
        return combined
    }

    public func open(_ combined: Data) throws -> Data {
        guard combined.count > 12 + 16 else { throw SecureChannelError.short }
        let nonce = combined.prefix(12)
        var value: UInt64 = 0
        for byte in nonce.suffix(8) { value = value << 8 | UInt64(byte) }
        lock.lock()
        let replay = lastReceived.map { value <= $0 } ?? false
        if !replay { lastReceived = value }
        lock.unlock()
        if replay { throw SecureChannelError.replay }
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw SecureChannelError.broken(error.localizedDescription)
        }
    }
}

/// A socket whose payloads are sealed: the handshake goes out in the clear, everything after it is
/// encrypted by the time `activate()` is called.
public final class EncryptedSocket: MessageSocket, @unchecked Sendable {
    public var onText: (([String: Any]) -> Void)? {
        get { lock.withLock { textHandler } }
        set { lock.withLock { textHandler = newValue } }
    }
    public var onClosed: (() -> Void)? {
        get { lock.withLock { closedHandler } }
        set { lock.withLock { closedHandler = newValue } }
    }

    private let socket: WebSocketConnection
    private let lock = NSLock()
    private var channel: SecureChannel?
    private var textHandler: (([String: Any]) -> Void)?
    private var closedHandler: (() -> Void)?

    public init(socket: WebSocketConnection) {
        self.socket = socket
        socket.onText = { [weak self] message in
            guard let self else { return }
            guard let channel = lock.withLock({ self.channel }) else {
                self.onText?(message)  // the handshake itself
                return
            }
            guard let data = message["d"] as? String, let sealed = Data(base64Encoded: data),
                let plain = try? channel.open(sealed),
                let object = try? JSONSerialization.jsonObject(with: plain),
                let decoded = object as? [String: Any]
            else { return }
            self.onText?(decoded)
        }
        socket.onClosed = { [weak self] in self?.onClosed?() }
    }

    /// Called once the user accepted the pairing code.
    public func activate(_ channel: SecureChannel) {
        lock.withLock { self.channel = channel }
    }

    private func payload(_ data: Data) -> [String: Any]? {
        guard let channel = lock.withLock({ self.channel }) else { return nil }
        let sealed = channel.seal(data)
        return ["d": sealed.base64EncodedString()]
    }

    public func send(_ message: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: message), let wrapped = payload(data) {
            socket.send(wrapped)
        } else {
            socket.send(message)
        }
    }

    public func send(binary data: Data) {
        // Media goes as raw sealed bytes in a binary frame: no base64 between the two ends.
        guard let channel = lock.withLock({ self.channel }) else {
            socket.send(binary: data)
            return
        }
        socket.send(binary: channel.seal(data))
    }

    public func close() {
        socket.close()
    }
}
