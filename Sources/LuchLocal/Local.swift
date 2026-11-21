// Local control API, the macOS stand-in for luch-linux's D-Bus interface: one Unix socket, JSON per
// line, request then response. `luchctl` is a thin client over it.
// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import LuchProto

public func defaultSocketPath() -> String {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Luch", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("control.sock").path
}

public final class LocalServer {
    public var handler: (([String: Any]) -> [String: Any])?
    private let path: String
    private var listenFD: Int32 = -1
    private var running = false
    private let queue = DispatchQueue(label: "luch.local.server")

    public init(path: String = defaultSocketPath()) {
        self.path = path
    }

    public func start() throws {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalError.socket(errnoString()) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPath = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxPath else {
            close(fd)
            throw LocalError.socket("socket path too long")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxPath) { destination in
                _ = strcpy(destination, path)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else {
            close(fd)
            throw LocalError.socket("bind \(path): \(errnoString())")
        }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else {
            close(fd)
            throw LocalError.socket("listen: \(errnoString())")
        }
        listenFD = fd
        running = true
        queue.async { [weak self] in self?.acceptLoop() }
        log("local: listening on \(path)")
    }

    public func stop() {
        running = false
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(path)
        log("local: stopped")
    }

    private func acceptLoop() {
        while running {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                if running { log("local: accept: \(errnoString())") }
                return
            }
            Thread.detachNewThread { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while running {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<Int(n)])
            while let newline = buffer.firstIndex(of: 0x0a) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard !line.isEmpty else { continue }
                let request = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] ?? [:]
                let response = handler?(request) ?? ["error": "no handler"]
                guard var data = try? JSONSerialization.data(withJSONObject: response) else { continue }
                data.append(0x0a)
                data.withUnsafeBytes { raw in
                    var sent = 0
                    while sent < raw.count {
                        let written = send(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                        if written <= 0 { return }
                        sent += written
                    }
                }
            }
            if buffer.count > Proto.maxLine { return }
        }
    }
}

public enum LocalError: Error, LocalizedError {
    case socket(String)
    case notRunning

    public var errorDescription: String? {
        switch self {
        case let .socket(why): return "local socket: \(why)"
        case .notRunning: return "Luch.app is not running (no control socket)"
        }
    }
}

public enum LocalClient {
    /// Sends one request and returns the response, or throws when the app is not running.
    public static func request(_ request: [String: Any], timeout: TimeInterval = 10) throws -> [String: Any] {
        let path = defaultSocketPath()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalError.socket(errnoString()) }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPath = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxPath else { throw LocalError.socket("socket path too long") }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxPath) { destination in
                _ = strcpy(destination, path)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard connected == 0 else { throw LocalError.notRunning }

        var timeval = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeval, socklen_t(MemoryLayout<timeval>.size))

        guard var data = try? JSONSerialization.data(withJSONObject: request) else {
            throw LocalError.socket("cannot encode request")
        }
        data.append(0x0a)
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let written = send(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                if written <= 0 { return }
                sent += written
            }
        }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { throw LocalError.socket("no response") }
            buffer.append(contentsOf: chunk[0..<Int(n)])
            if let newline = buffer.firstIndex(of: 0x0a) {
                let line = buffer[buffer.startIndex..<newline]
                return (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] ?? [:]
            }
        }
    }
}
