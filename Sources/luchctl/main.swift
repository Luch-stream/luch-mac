// luchctl — CLI over Luch.app's local socket.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import LuchLocal

func call(_ request: [String: Any]) -> [String: Any] {
    do {
        return try LocalClient.request(request)
    } catch {
        FileHandle.standardError.write(Data("luchctl: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "list"

switch command {
case "list":
    let response = call(["cmd": "receivers"])
    let receivers = response["receivers"] as? [[String: Any]] ?? []
    if receivers.isEmpty {
        print("no receivers found (Luch app on the TV? same LAN?)")
    }
    for receiver in receivers {
        let mirroring = (receiver["mirroring"] as? Bool) == true ? " *" : ""
        let name = receiver["name"] as? String ?? "?"
        let address = receiver["address"] as? String ?? "?"
        let port = (receiver["port"] as? NSNumber)?.intValue ?? 0
        let iface = receiver["iface"] as? String ?? "-"
        let model = receiver["model"] as? String ?? ""
        print("\(name)\(mirroring)\t\(address):\(port)\t\(iface.isEmpty ? "-" : iface)\t\(model)")
    }

case "mirror":
    var request: [String: Any] = ["cmd": "mirror"]
    var positionals: [String] = []
    var index = 1
    while index < args.count {
        if args[index] == "--codec", index + 1 < args.count {
            request["codec"] = args[index + 1]
            index += 2
            continue
        }
        if (args[index] == "--preset" || args[index] == "--quality"), index + 1 < args.count {
            request["preset"] = args[index + 1]
            index += 2
            continue
        }
        if args[index] == "--size-mode", index + 1 < args.count {
            request["size_mode"] = args[index + 1]
            index += 2
            continue
        }
        if args[index] == "--profile", index + 1 < args.count {
            request["profile"] = args[index + 1]
            index += 2
            continue
        }
        if args[index] == "--frame-ms" {
            if index + 1 < args.count, let frameMs = Int(args[index + 1]) {
                request["frame_ms"] = frameMs
            }
            index += 2
            continue
        }
        positionals.append(args[index])
        index += 1
    }
    if let name = positionals.first { request["name"] = name }
    let response = call(request)
    if let error = response["error"] as? String { print("error: \(error)"); exit(1) }
    print("mirroring to \(response["receiver"] as? String ?? "?")")

case "stats":
    let response = call(["cmd": "stats"])
    let stats = response["stats"] as? [String: Any] ?? [:]
    if stats.isEmpty { print("not streaming") }
    else {
        let est = (stats["est_ms"] as? NSNumber)?.doubleValue ?? 0
        let host = (stats["host_ms"] as? NSNumber)?.doubleValue ?? 0
        let rtt = (stats["rtt_ms"] as? NSNumber)?.doubleValue ?? 0
        let decode = (stats["decode_ms"] as? NSNumber)?.doubleValue
        let fps = (stats["fps"] as? NSNumber)?.doubleValue ?? 0
        let mbps = (stats["mbps"] as? NSNumber)?.doubleValue ?? 0
        var line = String(format: "≈ %.0f ms · host %.1f · rtt %.1f · %.0f fps · %.1f Mbit/s", est, host, rtt, fps, mbps)
        if let decode { line += String(format: " · decode %.1f", decode) }
        if let battery = (stats["battery"] as? NSNumber)?.intValue {
            line += " · phone \(battery)%"
            if (stats["charging"] as? NSNumber)?.boolValue == true { line += "⚡" }
        }
        if let thermal = stats["thermal"] as? String, thermal != "none" { line += " · \(thermal)" }
        print(line)
    }

case "state":
    let response = call(["cmd": "state"])
    print("state: \(response["state"] as? String ?? "?"), streaming: \((response["streaming"] as? Bool) == true)")

case "warmth":
    guard args.count > 1, let value = Double(args[1]) else {
        print("usage: luchctl warmth 0...1")
        exit(2)
    }
    let response = call(["cmd": "warmth", "value": value])
    if let error = response["error"] as? String { print("error: \(error)"); exit(1) }
    print(String(format: "warmth: %.2f", (response["warmth"] as? NSNumber)?.doubleValue ?? value))

case "stop":
    let response = call(["cmd": "stop"])
    if let error = response["error"] as? String { print("error: \(error)"); exit(1) }
    print("stopped")

case "ping":
    let response = call(["cmd": "ping"])
    print((response["ok"] as? Bool) == true ? "app is running" : "no response")

default:
    print("""
    usage: luchctl list | mirror [name] [--codec auto|h264|hevc] [--profile baseline|main|high]
                          [--frame-ms N] | stats | state | stop | ping
    """)
    exit(2)
}
