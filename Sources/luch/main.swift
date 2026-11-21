// luch — macOS sender for Luch v1 receivers.
//
//   luch list [--seconds N]
//   luch mirror [<name>] [--ip A.B.C.D] [--iface en0] [--port N] [--display N]
//               [--fps N] [--bitrate KBPS] [--size WxH] [--seconds N] [--no-audio] [--synthetic]
// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import LuchEngine
import LuchMedia
import LuchNet
import LuchProto

func usage() -> Never {
    let text = """
    usage:
      luch list [--seconds N]
      luch hw
      luch caps [<name>]
      luch mirror [<name>] [--ip A.B.C.D] [--iface en0] [--port N] [--display N]
                  [--fps N] [--bitrate KBPS] [--size WxH] [--seconds N] [--no-audio]
                  [--codec auto|h264|hevc] [--profile baseline|main|high] [--synthetic]
    """
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(2)
}

struct Args {
    var command = ""
    var match: String?
    var ip: String?
    var iface: String?
    var port: UInt16 = Proto.controlPort
    var seconds: Double = 0
    var options = MirrorOptions()
}

func parse(_ argv: [String]) -> Args {
    var a = Args()
    var positionals: [String] = []
    var i = 0
    while i < argv.count {
        let flag = argv[i]
        func next() -> String {
            i += 1
            guard i < argv.count else { usage() }
            return argv[i]
        }
        switch flag {
        case "--ip": a.ip = next()
        case "--iface": a.iface = next()
        case "--port": a.port = UInt16(next()) ?? Proto.controlPort
        case "--seconds": a.seconds = Double(next()) ?? 0
        case "--display": a.options.display = Int(next())
        case "--fps": a.options.fps = Int(next()) ?? Proto.fps
        case "--bitrate": a.options.bitrate = Int(next()) ?? Proto.videoKbps
        case "--size":
            let parts = next().split(separator: "x")
            a.options.width = Int(parts.first ?? "") ?? Proto.width
            a.options.height = Int(parts.last ?? "") ?? Proto.height
        case "--no-audio": a.options.audio = false
        case "--weights":
            let value = next()
            guard let weights = CodecWeights(spec: value) else { usage() }
            a.options.weights = weights
        case "--warm":
            let value = next()
            guard let warmth = Double(value) else { usage() }
            a.options.warmth = min(1, max(0, warmth))
        case "--preset", "--quality":
            let value = next()
            guard let preset = QualityPreset.parse(value) else { usage() }
            a.options.preset = preset
        case "--size-mode":
            let value = next()
            guard let mode = SizeMode(rawValue: value) else { usage() }
            a.options.sizeMode = mode
        case "--fit":
            let value = next()
            guard let fit = FitMode(rawValue: value) else { usage() }
            a.options.fit = fit
        case "--codec":
            let value = next()
            guard let codec = CodecChoice(rawValue: value) else { usage() }
            a.options.codec = codec
        case "--profile":
            let value = next()
            guard let profile = VideoProfile(rawValue: value) else { usage() }
            a.options.profile = profile
        case "--synthetic": a.options.synthetic = true
        case "-h", "--help": usage()
        default:
            if flag.hasPrefix("-") { usage() }
            positionals.append(flag)
        }
        i += 1
    }
    a.command = positionals.first ?? ""
    if positionals.count > 1 { a.match = positionals[1] }
    return a
}

func runList(seconds: Double) {
    let discovery = Discovery()
    discovery.start()
    let identity = senderIdentity()
    discovery.publish(name: identity.name, id: identity.id)
    let deadline = Date().addingTimeInterval(seconds > 0 ? seconds : 3)
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    let found = discovery.all()
    if found.isEmpty {
        print("no receivers found (Luch app on the TV? same LAN? Local Network permission?)")
        return
    }
    for r in found {
        print("\(r.name)\t\(r.address):\(r.port)\t\(r.interfaceName.isEmpty ? "-" : r.interfaceName)\t\(r.model)")
    }
}

func resolveReceiver(_ a: Args) -> Receiver? {
    if let ip = a.ip {
        let index = a.iface.map { if_nametoindex($0) } ?? lanInterfaceIndex()
        return Receiver(id: "manual", name: ip, model: "", address: ip,
                        interfaceName: a.iface ?? "", interfaceIndex: index, port: a.port, service: ip)
    }
    let discovery = Discovery()
    discovery.start()
    let identity = senderIdentity()
    discovery.publish(name: identity.name, id: identity.id)
    log("looking for a receiver\(a.match.map { " matching \"\($0)\"" } ?? "")…")
    guard let r = discovery.wait(matching: a.match, timeout: 8) ?? discovery.all().first else {
        log("no receiver found")
        return nil
    }
    return r
}

/// What this Mac can encode and decode, at the sizes we care about.
func runHardware() {
    print("encoder           1080p  4K   hw decode")
    for codec in VideoCodec.allCases {
        let hd = VideoEncoder.supports(codec, width: 1920, height: 1080)
        let uhd = VideoEncoder.supports(codec, width: 3840, height: 2160)
        print(String(format: "%-12@  %-5@ %-4@ %@",
                     codec.label as NSString,
                     (hd ? "yes" : "no") as NSString,
                     (uhd ? "yes" : "no") as NSString,
                     (VideoEncoder.hardwareDecodeSupported(codec) ? "yes" : "no") as NSString))
    }
    print("ProRes/JPEG are available through VideoToolbox but are not part of the v1 wire format.")
}

/// Ask a receiver what it can do and show the selection without starting a session.
func runCaps(_ a: Args) {
    guard let receiver = resolveReceiver(a) else { exit(1) }
    guard let control = ControlChannel.open(ip: receiver.address, port: receiver.port,
                                            interfaceIndex: receiver.interfaceIndex) else {
        log("cannot connect to \(receiver.address):\(receiver.port)")
        exit(1)
    }
    let identity = senderIdentity()
    control.send(["t": "hello", "v": Int(Proto.version), "id": identity.id, "name": identity.name,
                  "app": Proto.app, "want": ["mirror"]])
    guard let welcome = control.waitFor("welcome", timeout: 5), let caps = ReceiverCaps(welcome: welcome) else {
        log("no welcome from receiver")
        exit(1)
    }
    print(caps.describe())
    print("grading:")
    print("weights: \(a.options.weights.spec)")
    for entry in CodecPlanner.ranking(caps: caps, receiverID: receiver.id,
                                      width: a.options.width, height: a.options.height,
                                      weights: a.options.weights) {
        print("  " + entry.summary)
    }
    let plan = CodecPlanner.plan(caps: caps, receiverID: receiver.id, options: a.options)
    print("plan: \(plan.codec.label) \(plan.width)x\(plan.height)@\(plan.fps) audio=\(plan.audio)")
    print("      \(plan.reason)")
    control.bye()
}

let args = parse(Array(CommandLine.arguments.dropFirst()))
switch args.command {
case "list":
    runList(seconds: args.seconds)
case "hw":
    runHardware()
case "caps":
    runCaps(args)
case "mirror":
    var options = args.options
    options.seconds = args.seconds
    if !options.synthetic && !ensureScreenRecording(wait: true) {
        log("no Screen Recording permission: allow it in the system dialog and run again")
        exit(3)
    }
    guard let receiver = resolveReceiver(args) else { exit(1) }
    log("receiver: \(receiver.name) \(receiver.address):\(receiver.port) via \(receiver.interfaceName.isEmpty ? "-" : receiver.interfaceName)")
    let engine = Engine(options: options)
    engine.terminateOnStop = true
    do {
        try engine.start(receiver: receiver)
    } catch {
        log("start failed: \(error.localizedDescription)")
        exit(1)
    }
    engine.run()
    exit(0)
case "":
    usage()
default:
    usage()
}
