// Local HTTPS identity for the browser receiver: a self-signed certificate for localhost, the
// loopback and the current LAN address. Kept across restarts, renewed when the address changes.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Network
import Security

public final class WebIdentity {
    /// The identity the TLS listener presents. Recreated by `renew(for:)` when the address changes.
    public private(set) var identity: sec_identity_t
    private let directory: URL
    private var names: [String]

    public static func load(directory: URL, ip: String?) throws -> WebIdentity {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var names = ["localhost", "127.0.0.1"]
        if let ip, !names.contains(ip) { names.append(ip) }
        let saved =
            (try? String(contentsOf: directory.appendingPathComponent("web-names.txt"), encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        let p12 = directory.appendingPathComponent("web-id.p12")
        let ca = directory.appendingPathComponent("ca-cert.pem")
        // An older build kept only the self-signed pair: without a CA there is nothing to install.
        if saved != names || !FileManager.default.fileExists(atPath: p12.path)
            || !FileManager.default.fileExists(atPath: ca.path)
        {
            names = names.filter { !saved.contains($0) } + saved
            try issue(directory: directory, names: names)
            try names.joined(separator: "\n").write(
                to: directory.appendingPathComponent("web-names.txt"), atomically: true, encoding: .utf8)
        }
        return WebIdentity(identity: try importIdentity(p12), directory: directory, names: names)
    }

    private init(identity: sec_identity_t, directory: URL, names: [String]) {
        self.identity = identity
        self.directory = directory
        self.names = names
    }

    /// The CA certificate a phone installs once, in PEM (Android and iOS both take it).
    public func caCertificatePEM() -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent("ca-cert.pem"))
    }

    /// A laptop may join a different network without restarting the app.
    public func renew(for ip: String?) throws {
        guard let ip, !names.contains(ip) else { return }
        names.append(ip)
        try WebIdentity.issue(directory: directory, names: names)
        try names.joined(separator: "\n").write(
            to: directory.appendingPathComponent("web-names.txt"), atomically: true, encoding: .utf8)
        identity = try WebIdentity.importIdentity(directory.appendingPathComponent("web-id.p12"))
    }

    /// openssl makes the certificate; Security only has to load it. No private API, and the same
    /// file works for a browser that wants to trust it once.
    private static func issue(directory: URL, names: [String]) throws {
        let cert = directory.appendingPathComponent("web-cert.pem")
        let key = directory.appendingPathComponent("web-key.pem")
        let p12 = directory.appendingPathComponent("web-id.p12")
        let san = names.map { $0.contains(":") ? "" : (isIP($0) ? "IP:\($0)" : "DNS:\($0)") }
            .filter { !$0.isEmpty }
        try run(
            "/usr/bin/openssl",
            [
                "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "3650", "-nodes",
                "-keyout", key.path, "-out", cert.path, "-subj", "/CN=Luch",
                "-addext", "subjectAltName=" + san.joined(separator: ","),
            ])
        try run(
            "/usr/bin/openssl",
            [
                "pkcs12", "-export", "-inkey", key.path, "-in", cert.path, "-out", p12.path,
                "-passout", "pass:luch", "-name", "luch",
                // Security reads the old 3DES/SHA1 containers; LibreSSL's RC2 default it does not.
                "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1",
            ])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12.path)
    }

    private static func isIP(_ value: String) -> Bool {
        var addr = in_addr()
        return value.withCString { inet_pton(AF_INET, $0, &addr) } == 1
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw WebError.certificate(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func importIdentity(_ url: URL) throws -> sec_identity_t {
        let data = try Data(contentsOf: url)
        var items: CFArray?
        // Security reports errSecDecode for a container it only partly understands (LibreSSL writes
        // one), yet hands back the identity and its chain: take them when they are there.
        _ = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase: "luch"] as CFDictionary, &items)
        guard let list = items as? [[String: Any]],
            let identity = list.first?[kSecImportItemIdentity as String]
        else { throw WebError.certificate("cannot load \(url.lastPathComponent)") }
        guard let made = sec_identity_create(identity as! SecIdentity) else {
            throw WebError.certificate("cannot use the identity")
        }
        return made
    }
}

public enum WebError: Error, LocalizedError {
    case certificate(String)
    case listener(String)
    case handshake(String)

    public var errorDescription: String? {
        switch self {
        case .certificate(let why): return "web certificate: \(why)"
        case .listener(let why): return "web listener: \(why)"
        case .handshake(let why): return "web socket handshake: \(why)"
        }
    }
}
