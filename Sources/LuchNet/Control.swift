// Control channel: TCP, one JSON object per line, exactly as luch-android/PROTOCOL.md describes.
// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import LuchProto

public final class ControlChannel {
    public var onEvent: (([String: Any]) -> Void)?
    public var onClosed: ((String) -> Void)?
    public private(set) var rttMs: Double = 0

    private let fd: Int32
    private let lock = NSLock()
    private let cond = NSCondition()
    private var inbox: [[String: Any]] = []
    private var closed = false
    private var lastHeard = Date()
    private var pingN: UInt32 = 0
    private var pingAt = Date()
    private var pingTimer: DispatchSourceTimer?

    private init(fd: Int32) { self.fd = fd }

    deinit {
        pingTimer?.cancel()
        close(fd)
    }

    /// Connects to the receiver, pinning the socket to the interface it was discovered on.
    public static func open(ip: String, port: UInt16, interfaceIndex: UInt32, timeout: TimeInterval = 5) -> ControlChannel? {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else {
            log("control: socket() failed: \(errnoString())")
            return nil
        }
        func fail(_ why: String) -> ControlChannel? {
            log("control: \(why)")
            close(s)
            return nil
        }

        if interfaceIndex != 0 {
            var idx = interfaceIndex
            if setsockopt(s, IPPROTO_IP, IP_BOUND_IF, &idx, socklen_t(MemoryLayout<UInt32>.size)) != 0 {
                log("control: IP_BOUND_IF(\(interfaceIndex)) failed: \(errnoString())")
            }
        }
        _ = fcntl(s, F_SETFL, O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else {
            return fail("\(ip) is not an IPv4 address")
        }
        let rc = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(s, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 && errno != EINPROGRESS {
            return fail("connect \(ip):\(port): \(errnoString())")
        }
        if rc != 0 {
            var pfd = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pfd, 1, Int32(timeout * 1000))
            if ready <= 0 {
                return fail("connect \(ip):\(port) timed out")
            }
            var soErr: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(s, SOL_SOCKET, SO_ERROR, &soErr, &len)
            if soErr != 0 {
                errno = soErr
                return fail("connect \(ip):\(port): \(errnoString())")
            }
        }
        _ = fcntl(s, F_SETFL, 0)
        log("control: connected to \(ip):\(port) via ifindex \(interfaceIndex)")
        let channel = ControlChannel(fd: s)
        channel.start()
        return channel
    }

    private func start() {
        lastHeard = Date()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "luch.control.timer"))
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        pingTimer = t

        Thread.detachNewThread { [weak self] in self?.readLoop() }
    }

    private func tick() {
        lock.lock()
        let isClosed = closed
        let n = pingN
        pingN &+= 1
        pingAt = Date()
        let silent = Date().timeIntervalSince(lastHeard)
        lock.unlock()
        if isClosed { return }
        if silent >= 30 {
            closeChannel("silent for 30 s")
            return
        }
        _ = send(["t": "ping", "n": n])
    }

    @discardableResult
    public func send(_ obj: [String: Any]) -> Bool {
        guard JSONSerialization.isValidJSONObject(obj),
              var data = try? JSONSerialization.data(withJSONObject: obj) else {
            log("control: cannot encode \(obj)")
            return false
        }
        data.append(0x0a)
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        var written = 0
        let ok = data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Bool in
            while written < buf.count {
                let n = Darwin.send(fd, buf.baseAddress!.advanced(by: written), buf.count - written, 0)
                if n <= 0 {
                    if errno == EINTR { continue }
                    return false
                }
                written += n
            }
            return true
        }
        return ok
    }

    /// Blocks until a message with `t == type` arrives (other messages are dropped) or the timeout expires.
    public func waitFor(_ type: String, timeout: TimeInterval) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        cond.lock()
        defer { cond.unlock() }
        while Date() < deadline {
            if let idx = inbox.firstIndex(where: { ($0["t"] as? String) == type }) {
                return inbox.remove(at: idx)
            }
            if closed { return nil }
            cond.wait(until: deadline)
        }
        return nil
    }

    private func readLoop() {
        var buf = [UInt8](repeating: 0, count: 65536)
        var pending = Data()
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n > 0 {
                pending.append(contentsOf: buf[0..<Int(n)])
                while let nl = pending.firstIndex(of: 0x0a) {
                    let line = pending[pending.startIndex..<nl]
                    pending.removeSubrange(pending.startIndex...nl)
                    guard !line.isEmpty else { continue }
                    guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                          let t = obj["t"] as? String else {
                        log("control: bad line")
                        continue
                    }
                    handle(obj, type: t)
                }
                if pending.count > Proto.maxLine {
                    closeChannel("line too long")
                    return
                }
            } else if n == 0 {
                closeChannel("closed by receiver")
                return
            } else {
                if errno == EINTR { continue }
                closeChannel("read: \(errnoString())")
                return
            }
        }
    }

    private func handle(_ obj: [String: Any], type: String) {
        lock.lock()
        lastHeard = Date()
        let open = !closed
        lock.unlock()
        guard open else { return }

        switch type {
        case "ping":
            _ = send(["t": "pong", "n": obj["n"] ?? 0])
            return
        case "pong":
            let n = (obj["n"] as? NSNumber)?.uint32Value
            lock.lock()
            if let n, pingN > 0, n == pingN &- 1 {
                rttMs = Date().timeIntervalSince(pingAt) * 1000
            }
            lock.unlock()
            return
        default:
            break
        }

        cond.lock()
        inbox.append(obj)
        if inbox.count > 64 { inbox.removeFirst(inbox.count - 64) }
        cond.broadcast()
        cond.unlock()
        onEvent?(obj)
    }

    public func closeChannel(_ why: String) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        cond.lock()
        cond.broadcast()
        cond.unlock()
        log("control: closed (\(why))")
        onClosed?(why)
    }

    public func bye() {
        _ = send(["t": "bye"])
        shutdown(fd, SHUT_WR)
    }
}
