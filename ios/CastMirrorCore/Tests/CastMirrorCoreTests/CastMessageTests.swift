@testable import CastMirrorCore
import XCTest

final class CastMessageTests: XCTestCase {
    func testEncodingMatchesThePCSender() {
        // Same bytes pc-sender/test/castv2.test.js checks.
        let framed = CastMessage(source: "a", destination: "b", namespace: "c", payload: "{}").framed()
        XCTAssertEqual(framed.hex, "00000011" + "08001201611a0162220163280032027b7d")
    }

    func testSplitsMessagesAndKeepsPartialOnes() throws {
        let big = CastMessage(source: "sender-0", destination: "receiver-0", namespace: CastNamespace.receiver,
                              payload: String(repeating: "x", count: 50_000))
        let small = CastMessage(source: "s", destination: "d", namespace: CastNamespace.heartbeat, payload: #"{"type":"PING"}"#)
        let stream = big.framed() + small.framed()

        var partial = stream.prefix(100)
        XCTAssertEqual(try CastMessage.takeMessages(from: &partial), [])
        XCTAssertEqual(partial.count, 100)

        var whole = stream
        XCTAssertEqual(try CastMessage.takeMessages(from: &whole), [big, small])
        XCTAssertTrue(whole.isEmpty)
    }

    func testReceiverPageAddress() throws {
        let url = DashCast.receiverPageURL(base: "http://192.168.1.5:8080/receiver/", webSocket: "ws://192.168.1.5:8765", debugSeconds: 30)
        let items = URLComponents(string: url)?.queryItems ?? []
        XCTAssertTrue(url.hasPrefix("http://192.168.1.5:8080/receiver/?"))
        XCTAssertEqual(items.first { $0.name == "ws" }?.value, "ws://192.168.1.5:8765")
        XCTAssertEqual(items.first { $0.name == "debug" }?.value, "30")
        XCTAssertEqual(DashCast.loadMessage(url: url)["force"] as? Bool, true)
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
