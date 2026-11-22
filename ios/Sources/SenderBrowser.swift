// The senders this device can see: the same mDNS service the Mac publishes, so the waiting screen
// can say who is actually on the network instead of showing a static placeholder.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Network

@MainActor
final class SenderBrowser {
    struct Sender: Identifiable, Equatable {
        let id: String
        let name: String
    }

    private(set) var senders: [Sender] = []
    private var listeners: [UUID: AsyncStream<[Sender]>.Continuation] = [:]
    private var browser: NWBrowser?

    /// One stream per consumer; it starts with the current list, then yields every change.
    func updates() -> AsyncStream<[Sender]> {
        AsyncStream { continuation in
            let id = UUID()
            listeners[id] = continuation
            continuation.yield(senders)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.listeners[id] = nil }
            }
        }
    }

    private func publish(_ list: [Sender]) {
        senders = list
        for continuation in listeners.values { continuation.yield(list) }
    }

    func start() {
        guard browser == nil else { return }
        // Plain Bonjour over the local network; peer-to-peer would narrow the search to AWDL.
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let browser = NWBrowser(
            for: .bonjour(type: "_luchsrc._tcp.", domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            print("sender-browser: state \(state)")
            guard case .failed = state else { return }
            Task { @MainActor in self?.restart() }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let list = results.compactMap { result -> Sender? in
                guard case let .service(name: name, type: _, domain: _, interface: _) = result.endpoint
                else { return nil }
                return Sender(id: name, name: name)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            print("sender-browser: \(results.count) result(s) -> \(list.count)")
            Task { @MainActor in self?.publish(list) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        publish([])
    }

    private func restart() {
        stop()
        // A short delay keeps a flapping network from spinning the browser.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.start() }
    }
}
