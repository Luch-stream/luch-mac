// The address this device offers on the local network, for the "visible as" line on the home screen.
// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

enum LocalAddress {
    /// The first usable IPv4 interface: link-local addresses are skipped, private ranges win.
    static func preferred() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var found: String?
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = cur {
            let flags = Int32(pointer.pointee.ifa_flags)
            if let addr = pointer.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                flags & Int32(IFF_UP) != 0, flags & Int32(IFF_LOOPBACK) == 0
            {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
                    NI_NUMERICHOST) == 0
                {
                    let text = String(cString: host)
                    if text.hasPrefix("169.254.") { cur = pointer.pointee.ifa_next; continue }
                    found = text
                    if text.hasPrefix("192.168.") || text.hasPrefix("10.") { break }
                }
            }
            cur = pointer.pointee.ifa_next
        }
        return found
    }
}
