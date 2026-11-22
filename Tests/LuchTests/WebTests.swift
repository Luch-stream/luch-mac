// The browser receiver's server: the page over HTTPS and the websocket handshake.
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

@testable import LuchWeb

final class WebTests: XCTestCase {
    func testAcceptMatchesTheSpecExample() {
        // RFC 6455, section 1.3.
        XCTAssertEqual(
            WebSocketConnection.accept(for: "dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    func testPageIsServedOverTLS() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "luch-web-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let server = WebServer(identityDirectory: dir)
        try server.start(port: 14781, ip: "127.0.0.1")
        defer { server.stop() }

        let ready = expectation(description: "page")
        let session = URLSession(configuration: .ephemeral, delegate: TrustAll(), delegateQueue: nil)
        let task = session.dataTask(with: URL(string: "https://127.0.0.1:14781/")!) { data, response, error in
            defer { ready.fulfill() }
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let body = String(data: data ?? Data(), encoding: .utf8) ?? ""
            XCTAssertTrue(body.contains("<canvas>"), "the page should be the receiver html")
            XCTAssertTrue(body.contains("Luch"))
        }
        task.resume()
        wait(for: [ready], timeout: 10)
    }
}

private final class TrustAll: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(.useCredential, URLCredential(trust: challenge.protectionSpace.serverTrust!))
    }
}
