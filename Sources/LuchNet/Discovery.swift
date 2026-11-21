// Bonjour discovery and publishing via the DNS-SD C API: it hands out the interface index per result,
// which is exactly what PROTOCOL.md §2 needs to keep the stream off a VPN default route.
// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import dnssd
import LuchProto

public struct Receiver {
    public var id: String
    public var name: String
    public var model: String
    public var address: String
    public var interfaceName: String
    public var interfaceIndex: UInt32
    public var port: UInt16
    public var service: String

    public init(id: String, name: String, model: String, address: String, interfaceName: String,
                interfaceIndex: UInt32, port: UInt16, service: String) {
        self.id = id
        self.name = name
        self.model = model
        self.address = address
        self.interfaceName = interfaceName
        self.interfaceIndex = interfaceIndex
        self.port = port
        self.service = service
    }
}

private func txtMap(_ txt: UnsafeRawPointer?, length: UInt16) -> [String: String] {
    guard let txt, length > 0 else { return [:] }
    let bytes = UnsafeRawBufferPointer(start: txt, count: Int(length))
    var out: [String: String] = [:]
    var i = 0
    while i < bytes.count {
        let n = Int(bytes[i])
        i += 1
        guard i + n <= bytes.count else { break }
        let entry = String(decoding: bytes[i..<i + n], as: UTF8.self)
        i += n
        if let eq = entry.firstIndex(of: "=") {
            out[entry[..<eq].lowercased()] = String(entry[entry.index(after: eq)...])
        }
    }
    return out
}

private func interfaceName(_ index: UInt32) -> String {
    if index == 0 || index == 0xFFFF_FFFF { return "" }
    var buf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
    guard if_indextoname(index, &buf) != nil else { return "" }
    return String(cString: buf)
}

/// IPv4 address of a `.local.` host target, resolved through the system resolver (mDNS included).
private func resolveIPv4(_ host: String) -> String? {
    var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                         ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return nil }
    defer { freeaddrinfo(res) }
    var addr = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    var cur: UnsafeMutablePointer<addrinfo>? = first
    while let ai = cur {
        if ai.pointee.ai_family == AF_INET,
           getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &addr, socklen_t(addr.count), nil, 0, NI_NUMERICHOST) == 0 {
            return String(cString: addr)
        }
        cur = ai.pointee.ai_next
    }
    return nil
}

/// Interface index of the LAN (an up, non-loopback interface with an IPv4 address).
public func lanInterfaceIndex() -> UInt32 {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return 0 }
    defer { freeifaddrs(head) }
    var best: (UInt32, String) = (0, "")
    var cur: UnsafeMutablePointer<ifaddrs>? = first
    while let ifa = cur {
        defer { cur = ifa.pointee.ifa_next }
        let flags = Int32(ifa.pointee.ifa_flags)
        guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
        guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
        let name = String(cString: ifa.pointee.ifa_name)
        let idx = if_nametoindex(name)
        // Prefer the usual Wi-Fi/Ethernet names when several interfaces qualify.
        if name.hasPrefix("en") { return idx }
        if best.0 == 0 { best = (idx, name) }
    }
    return best.0
}

private let browseCallback: DNSServiceBrowseReply = { _, flags, ifIndex, err, name, _, _, ctx in
    guard let ctx else { return }
    let discovery = Unmanaged<Discovery>.fromOpaque(ctx).takeUnretainedValue()
    discovery.handleBrowse(flags: flags, ifIndex: ifIndex, error: err, name: name)
}

private let resolveCallback: DNSServiceResolveReply = { _, _, ifIndex, err, fullname, host, port, txtLen, txt, ctx in
    guard let ctx else { return }
    let discovery = Unmanaged<Discovery>.fromOpaque(ctx).takeUnretainedValue()
    discovery.handleResolve(ifIndex: ifIndex, error: err, fullname: fullname, host: host,
                            port: port, txtLen: txtLen, txt: txt)
}

private let registerCallback: DNSServiceRegisterReply = { _, _, err, name, _, _, ctx in
    guard let ctx else { return }
    let discovery = Unmanaged<Discovery>.fromOpaque(ctx).takeUnretainedValue()
    if err != kDNSServiceErr_NoError {
        log("bonjour: publish \(name.map { String(cString: $0) } ?? "?"): error \(err)")
    } else {
        discovery.published = true
    }
}

public final class Discovery {
    public var onUpdate: (() -> Void)?
    public private(set) var receivers: [String: Receiver] = [:] // service instance name -> receiver
    public var published = false

    private var browserRef: DNSServiceRef?
    private var registerRef: DNSServiceRef?
    private var resolveRefs: [DNSServiceRef] = []
    private let lock = NSLock()
    private var started = false

    public init() {}

    public func start() {
        guard !started else { return }
        started = true
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let err = DNSServiceBrowse(&browserRef, 0, 0, Proto.receiverType, nil, browseCallback, ctx)
        guard err == kDNSServiceErr_NoError, let ref = browserRef else {
            log("bonjour: browse \(Proto.receiverType) failed: \(err)")
            return
        }
        log("bonjour: browsing \(Proto.receiverType)")
        process(ref)
    }

    public func publish(name: String, id: String) {
        var txt: [UInt8] = []
        for entry in ["v=\(Proto.version)", "id=\(id)", "name=\(name)"] {
            let bytes = Array(entry.utf8)
            txt.append(UInt8(bytes.count))
            txt.append(contentsOf: bytes)
        }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let err = txt.withUnsafeBufferPointer { buf in
            DNSServiceRegister(&registerRef, 0, 0, name, Proto.senderType, nil, nil,
                               UInt16(9).bigEndian, UInt16(buf.count), buf.baseAddress,
                               registerCallback, ctx)
        }
        if err != kDNSServiceErr_NoError {
            log("bonjour: register \(Proto.senderType) failed: \(err)")
            return
        }
        if let ref = registerRef { process(ref) }
        log("bonjour: published \(Proto.senderType) as \"\(name)\"")
    }

    /// Keeps processing results on a background thread for the lifetime of the reference.
    private func process(_ ref: DNSServiceRef) {
        DispatchQueue.global(qos: .utility).async {
            while true {
                let err = DNSServiceProcessResult(ref)
                if err != kDNSServiceErr_NoError {
                    log("bonjour: process result stopped: \(err)")
                    break
                }
            }
        }
    }

    fileprivate func handleBrowse(flags: DNSServiceFlags, ifIndex: UInt32, error: DNSServiceErrorType,
                                  name: UnsafePointer<CChar>?) {
        guard error == kDNSServiceErr_NoError, let name else { return }
        let service = String(cString: name)
        log("bonjour: browse event flags=\(flags) \(service) if=\(ifIndex)")
        if flags & kDNSServiceFlagsAdd != 0 {
            resolve(service, ifIndex: ifIndex)
        } else {
            lock.lock()
            let removed = receivers.removeValue(forKey: service)
            lock.unlock()
            if let removed {
                log("bonjour: gone: \(removed.name) (\(removed.address))")
                onUpdate?()
            }
        }
    }

    private func resolve(_ service: String, ifIndex: UInt32) {
        var ref: DNSServiceRef?
        let type = Proto.receiverType
        let err = DNSServiceResolve(&ref, 0, ifIndex, service, type, "local.", resolveCallback,
                                    Unmanaged.passUnretained(self).toOpaque())
        guard err == kDNSServiceErr_NoError, let ref else {
            log("bonjour: resolve \(service) failed: \(err)")
            return
        }
        lock.lock()
        resolveRefs.append(ref)
        lock.unlock()
        process(ref)
    }

    fileprivate func handleResolve(ifIndex: UInt32, error: DNSServiceErrorType, fullname: UnsafePointer<CChar>?,
                                   host: UnsafePointer<CChar>?, port: UInt16, txtLen: UInt16, txt: UnsafeRawPointer?) {
        guard error == kDNSServiceErr_NoError, let fullname, let host else { return }
        let txt = txtMap(txt, length: txtLen)
        if let v = txt["v"], v != "0" {
            log("bonjour: ignoring \(String(cString: fullname)): protocol v\(v)")
            return
        }
        let serviceName = txt["service"] ?? String(cString: fullname).components(separatedBy: "._luch").first ?? ""
        let hostTarget = String(cString: host)
        let portHost = UInt16(bigEndian: port)
        // getaddrinfo can hit the network (mDNS): keep it off the DNS-SD callback thread.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            guard let address = resolveIPv4(hostTarget) else {
                log("bonjour: no IPv4 for \(hostTarget)")
                return
            }
            // A loopback service can be resolved on en0 (Bonjour publishes on every interface); pinning
            // 127.0.0.1 to en0 would fail, so the index must follow the address.
            var index = ifIndex
            if address.hasPrefix("127.") {
                index = if_nametoindex("lo0")
            }
            let receiver = Receiver(id: txt["id"] ?? serviceName, name: txt["name"] ?? serviceName,
                                    model: txt["model"] ?? "", address: address,
                                    interfaceName: interfaceName(index), interfaceIndex: index,
                                    port: portHost, service: serviceName)
            self.lock.lock()
            self.receivers[receiver.service] = receiver
            self.lock.unlock()
            log("bonjour: found \(receiver.name) id=\(receiver.id) \(receiver.address):\(receiver.port) via \(receiver.interfaceName)(\(receiver.interfaceIndex))")
            self.onUpdate?()
        }
    }

    public func all() -> [Receiver] {
        lock.lock()
        defer { lock.unlock() }
        return receivers.values.sorted { $0.name < $1.name }
    }

    /// Waits until a receiver matching `match` appears (nil = any), or the timeout expires.
    public func wait(matching match: String?, timeout: TimeInterval) -> Receiver? {
        start()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let list = all()
            if let match {
                if let hit = list.first(where: { $0.name.localizedCaseInsensitiveContains(match) || $0.id == match || $0.address == match }) {
                    return hit
                }
            } else if list.count == 1 {
                return list[0]
            } else if list.count > 1 {
                return nil // ambiguous without a name
            }
            usleep(100_000)
        }
        return nil
    }
}
