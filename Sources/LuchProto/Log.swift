// Tiny logging helper: everything goes to stderr so stdout stays parseable.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

private let logStart = Date()

/// When set, every line is also appended here (a bundled .app launched with `open` has no terminal).
public var logFile: String?

public func log(_ message: String) {
    let t = Date().timeIntervalSince(logStart)
    let line = String(format: "[%7.3f] %@\n", t, message)
    FileHandle.standardError.write(Data(line.utf8))
    guard let path = logFile else { return }
    let fm = FileManager.default
    if !fm.fileExists(atPath: path) {
        fm.createFile(atPath: path, contents: nil)
    }
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    }
}

public func errnoString() -> String {
    String(cString: strerror(errno))
}
