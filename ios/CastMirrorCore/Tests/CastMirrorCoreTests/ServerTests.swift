@testable import CastMirrorCore
import XCTest

final class ServerTests: XCTestCase {
    func testWebSocketCarriesChunksAndControlMessages() async throws {
        let server = WebSocketServer()
        let port = try await server.start(preferredPort: 0)
        let connected = expectation(description: "receiver connected")
        let heard = expectation(description: "text from receiver")
        server.onConnect = { connected.fulfill() }
        server.onText = { text in if text == #"{"type":"ping"}"# { heard.fulfill() } }

        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
        task.resume()
        await fulfillment(of: [connected], timeout: 5)

        let chunk = Data((0..<200_000).map { UInt8($0 % 251) })
        server.send(chunk)
        guard case .data(let received) = try await task.receive() else { return XCTFail("expected a binary message") }
        XCTAssertEqual(received, chunk)

        server.sendText(#"{"type":"pong"}"#)
        guard case .string(let text) = try await task.receive() else { return XCTFail("expected a text message") }
        XCTAssertEqual(text, #"{"type":"pong"}"#)

        try await task.send(.string(#"{"type":"ping"}"#))
        await fulfillment(of: [heard], timeout: 5)
        task.cancel(with: .normalClosure, reason: nil)
        server.stop()
    }

    func testServesTheReceiverPageAndNothingElse() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("<p>receiver</p>".utf8).write(to: directory.appendingPathComponent("index.html"))
        try Data("var x;".utf8).write(to: directory.appendingPathComponent("receiver.js"))
        let server = HTTPServer(receiverDirectory: directory)
        server.status = { "status line\n" }

        XCTAssertEqual(server.response(for: "/receiver/").body, Data("<p>receiver</p>".utf8))
        XCTAssertEqual(server.response(for: "/receiver/?ws=ws://1.2.3.4:8765").status, "200 OK")
        XCTAssertEqual(server.response(for: "/receiver/receiver.js").contentType, "text/javascript")
        XCTAssertEqual(server.response(for: "/receiver/../secret").status, "404 Not Found")
        XCTAssertEqual(server.response(for: "/receiver/%2e%2e/secret").status, "404 Not Found")
        XCTAssertEqual(server.response(for: "/other").status, "404 Not Found")

        let port = try await server.start(preferredPort: 0)
        let (body, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/receiver/?ws=x")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(body, Data("<p>receiver</p>".utf8))
        let (status, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/status")!)
        XCTAssertEqual(String(decoding: status, as: UTF8.self), "status line\n")
        server.stop()
    }
}
