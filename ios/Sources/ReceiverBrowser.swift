// Receivers on the local network, for the Send half: browse _luch._tcp, resolve each service to an
// address, and hand the UI a list it can mirror to.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Network

@MainActor
final class ReceiverBrowser: NSObject, NetServiceDelegate {
    private var browser: NWBrowser?
    private var services: [String: NetService] = [:]
    private var resolved: [String: SendTarget] = [:]
    private var listeners: [UUID: AsyncStream<[SendTarget]>.Continuation] = [:]

    func updates() -> AsyncStream<[SendTarget]> {
        AsyncStream { continuation in
            let id = UUID()
            listeners[id] = continuation
            continuation.yield(sorted())
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.listeners[id] = nil }
            }
        }
    }

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: "_luch._tcp.", domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let names = results.compactMap { result -> (String, String, String)? in
                guard case let .service(name: name, type: type, domain: domain, interface: _) = result.endpoint
                else { return nil }
                return (name, type, domain)
            }
            Task { @MainActor in self?.resolving(names) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func resolving(_ entries: [(String, String, String)]) {
        for (name, type, domain) in entries where services[name] == nil {
            let service = NetService(domain: domain, type: type, name: name)
            service.delegate = self
            service.resolve(withTimeout: 5)
            services[name] = service
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        var host: String?
        for data in sender.addresses ?? [] {
            host = data.withUnsafeBytes { raw -> String? in
                guard let base = raw.baseAddress else { return nil }
                let family = base.assumingMemoryBound(to: sockaddr.self).pointee.sa_family
                guard family == sa_family_t(AF_INET) else { return nil }
                let addr = base.assumingMemoryBound(to: sockaddr_in.self).pointee
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var value = addr.sin_addr
                guard inet_ntop(AF_INET, &value, &buffer, socklen_t(buffer.count)) != nil else { return nil }
                return String(cString: buffer)
            }
            if let host, !host.hasPrefix("169.254.") { break }
        }
        guard let host, sender.port > 0 else { return }
        let target = SendTarget(
            id: sender.name, name: sender.name, host: host, port: UInt16(sender.port), model: "Luch")
        Task { @MainActor in self.adopt(target) }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        Task { @MainActor in self.services[sender.name] = nil }
    }

    private func adopt(_ target: SendTarget) {
        resolved[target.id] = target
        broadcast()
    }

    private func sorted() -> [SendTarget] {
        resolved.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func broadcast() {
        let list = sorted()
        for continuation in listeners.values { continuation.yield(list) }
    }

    func stop() {
        browser?.cancel()
        browser = nil
        for service in services.values { service.stop() }
        services.removeAll()
        resolved.removeAll()
        broadcast()
    }
}
