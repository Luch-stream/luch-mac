// The app answers the broadcast extension with the receiver it should stream to. A loopback
// socket instead of an App Group: it needs no entitlement and works for a local build.
// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

final class ConfigServer {
    static let port: UInt16 = 47_899

    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    var target: SendTarget?
    /// The last line the extension sent back, shown on the send card.
    private(set) var status: String = ""
    var onStatus: ((String) -> Void)?

    private func announce(_ text: String) {
        DispatchQueue.main.async {
            self.status = text
            self.onStatus?(text)
        }
    }

    func start() {
        guard fd < 0 else { return }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = ConfigServer.port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            close(fd)
            announce("конфиг: порт 47899 занят")
            return
        }
        announce("конфиг: слушаю 127.0.0.1:47899")
        self.fd = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in self?.accept() }
        source.resume()
        self.source = source
    }

    private func accept() {
        var client = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let socket = withUnsafeMutablePointer(to: &client) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.accept(fd, $0, &length)
            }
        }
        guard socket >= 0 else { return }
        NSLog("Luch config: extension asked, target=\(target?.host ?? "nil")")
        defer { close(socket) }
        guard let target,
            let data = try? JSONSerialization.data(withJSONObject: [
                "host": target.host, "port": Int(target.port), "name": target.name,
            ])
        else { return }
        _ = data.withUnsafeBytes { write(socket, $0.baseAddress, $0.count) }
        // The extension keeps the line open and reports what it is doing.
        var buffer = [UInt8](repeating: 0, count: 2048)
        let count = recv(socket, &buffer, buffer.count, 0)
        if count > 0, let text = String(bytes: buffer[0..<count], encoding: .utf8) {
            let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                self.status = line
                self.onStatus?(line)
            }
        }
    }
}
