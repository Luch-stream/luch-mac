// The browser receiver's server: one HTTPS listener that serves the page and upgrades /ws to a
// WebSocket, where a browser behaves like any other receiver.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import LuchProto
import Network

/// The address a browser on the local network should open: the first IPv4 of an up, non-loopback
/// interface. Discovery already finds receivers this way; here it names the page.
public func webAddress() -> String? {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return nil }
    defer { freeifaddrs(head) }
    var fallback: String?
    for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let flags = Int32(entry.pointee.ifa_flags)
        guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
        guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else {
            continue
        }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let name = entry.pointee.ifa_name.map { String(cString: $0) } ?? ""
        guard
            getnameinfo(
                addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
                NI_NUMERICHOST) == 0
        else { continue }
        let ip = String(cString: host)
        if name.hasPrefix("en") { return ip }
        fallback = fallback ?? ip
    }
    return fallback
}

public final class WebServer: @unchecked Sendable {
    /// Called on a background queue when a browser has completed the handshake and sent hello.
    public var onClient: ((WebSocketConnection) -> Void)?

    private var listener: NWListener?
    private var caListener: NWListener?
    private let queue = DispatchQueue(label: "luch.web.server")
    private var identity: WebIdentity?
    private let directory: URL

    public init(identityDirectory: URL) {
        self.directory = identityDirectory
    }

    /// Starts on `port`, renewing the certificate if the LAN address changed since the last run.
    public func start(port: UInt16 = Proto.webPort, ip: String?) throws {
        let dir = directory
        let identity = try WebIdentity.load(directory: dir, ip: ip)
        self.identity = identity
        self.ipAddress = ip ?? ""
        let caData = identity.caCertificatePEM() ?? Data()
        log("web: CA certificate \(caData.isEmpty ? "missing" : "\(caData.count) bytes")")
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity.identity)
        // The page needs a secure context for WebCodecs; the certificate is self-signed on purpose.
        sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, false)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                log("web: listener failed: \(error)")
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        log("web: listening on https://<this host>:\(port)/")
        startCertificateServer(ip: ip)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        caListener?.cancel()
        caListener = nil
    }

    /// Plain HTTP on :47802, because a phone cannot download a certificate it does not trust yet.
    private func startCertificateServer(ip: String?) {
        let plain = NWParameters.tcp
        plain.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: plain, on: NWEndpoint.Port(rawValue: Proto.caPort)!)
        else { return }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .main)
            self?.serveCertificate(connection, buffer: Data())
        }
        listener.start(queue: queue)
        caListener = listener
        if let ip { log("web: certificate page on http://\(ip):\(Proto.caPort)/") }
    }

    private func serveCertificate(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if done || error != nil {
                    connection.cancel()
                } else {
                    self.serveCertificate(connection, buffer: buffer)
                }
                return
            }
            let head = String(data: buffer[..<end.lowerBound], encoding: .utf8) ?? ""
            let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            var headers: [String: String] = [:]
            for line in head.split(separator: "\r\n").dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
            }
            // A TV has an old browser and cannot install certificates: the same page, over plain
            // HTTP, with MediaSource instead of WebCodecs.
            if path.hasPrefix("/ws"), headers["upgrade"]?.lowercased().contains("websocket") == true,
                let key = headers["sec-websocket-key"]
            {
                let response = """
                    HTTP/1.1 101 Switching Protocols\r
                    Upgrade: websocket\r
                    Connection: Upgrade\r
                    Sec-WebSocket-Accept: \(WebSocketConnection.accept(for: key))\r
                    \r

                    """
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
                let socket = WebSocketConnection(connection: connection)
                self.onClient?(socket)
                socket.start()
                return
            }
            let ca = self.identity?.caCertificatePEM() ?? Data()
            let body: Data
            var type = "text/html; charset=utf-8"
            if path.hasPrefix("/ca.crt"), !ca.isEmpty {
                body = ca
                type = "application/x-x509-ca-cert"
            } else if path.hasPrefix("/tv") {
                body = Data(WebPage.tv.utf8)
            } else {
                body = Data(WebServer.trustPage(ip: self.ipAddress).utf8)
            }
            let response = """
                HTTP/1.1 200 OK\r
                Content-Type: \(type)\r
                Content-Length: \(body.count)\r
                \(path.hasPrefix("/ca.crt") ? "Content-Disposition: attachment; filename=\"luch-ca.crt\"\r" : "")\r

                """
            var out = Data(response.utf8)
            out.append(body)
            connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private var ipAddress: String = ""

    private static func trustPage(ip: String) -> String {
        """
        <!doctype html><meta charset="utf-8"><title>Luch — доверие сертификату</title>
        <body style="font:16px system-ui;max-width:40em;margin:2em auto;padding:0 1em;line-height:1.5">
        <h1>Luch</h1>
        <p>Чтобы браузер открывал трансляцию по HTTPS, установите корневой сертификат Luch —
        один раз на устройстве.</p>
        <p><a href="/ca.crt" style="font-size:1.2em">Скачать сертификат luch-ca.crt</a></p>
        <h2>Android</h2>
        <ol><li>Скачайте файл по ссылке и откройте его.</li>
        <li>Настройки → Безопасность → Установка сертификата → Сертификат CA.</li>
        <li>Подтвердите предупреждение и вернитесь в браузер.</li></ol>
        <h2>iOS / iPadOS</h2>
        <ol><li>Скачайте файл и разрешите профиль.</li>
        <li>Настройки → Основные → VPN и управление устройством → установить профиль.</li>
        <li>Настройки → Основные → Об этом устройстве → Доверие сертификатам → включить Luch.</li></ol>
        <h2>macOS</h2>
        <p>Откройте файл luch-ca.crt, добавьте в связку «Система» и включите «Доверять всегда».</p>
        <p style="opacity:.6">Затем откройте <a href="https://\(ip):\(Proto.webPort)/">https://\(ip):\(Proto.webPort)/</a></p>
        </body>
        """
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, buffer: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if done || error != nil || buffer.count > 64 * 1024 {
                    connection.cancel()
                } else {
                    self.receiveRequest(connection, buffer: buffer)
                }
                return
            }
            let head = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
            let rest = buffer[headerEnd.upperBound...]
            let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
            let requestLine = lines.first.map(String.init) ?? ""
            let path = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
            }

            if path.hasPrefix("/ws"), headers["upgrade"]?.lowercased().contains("websocket") == true,
                let key = headers["sec-websocket-key"]
            {
                let accept = WebSocketConnection.accept(for: key)
                let response = """
                    HTTP/1.1 101 Switching Protocols\r
                    Upgrade: websocket\r
                    Connection: Upgrade\r
                    Sec-WebSocket-Accept: \(accept)\r
                    \r

                    """
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
                let socket = WebSocketConnection(connection: connection)
                if !rest.isEmpty {
                    socket.inject(Data(rest))
                }
                self.onClient?(socket)
                socket.start()
                return
            }

            let body = path.hasPrefix("/tv") ? Data(WebPage.tv.utf8) : Data(WebPage.html.utf8)
            let response = """
                HTTP/1.1 200 OK\r
                Content-Type: text/html; charset=utf-8\r
                Content-Length: \(body.count)\r
                Cache-Control: no-store\r
                Connection: close\r
                \r

                """
            var out = Data(response.utf8)
            out.append(body)
            connection.send(
                content: out,
                completion: .contentProcessed { _ in
                    connection.cancel()
                })
        }
    }
}
