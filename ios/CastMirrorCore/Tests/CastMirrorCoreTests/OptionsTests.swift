@testable import CastMirrorCore
import XCTest

final class OptionsTests: XCTestCase {
    /// The app and the extension are separate processes on the phone; Darwin
    /// notifications reach observers in the posting process too, so one
    /// process can play both sides here.
    func testSettingsReachTheExtension() {
        let queue = DispatchQueue(label: "test")
        var heard: [Bool] = []
        var expected = expectation(description: "stats on")
        let observation = OptionsChannel.observe(queue: queue) { show in
            heard.append(show)
            expected.fulfill()
        }
        OptionsChannel.post(showStats: true)
        wait(for: [expected], timeout: 5)

        expected = expectation(description: "stats off")
        OptionsChannel.post(showStats: false)
        wait(for: [expected], timeout: 5)
        XCTAssertEqual(queue.sync { heard }, [true, false])

        observation.cancel()
        OptionsChannel.post(showStats: true)
        queue.sync {}
        XCTAssertEqual(queue.sync { heard }, [true, false], "nothing heard after cancelling")
    }

    func testAppHearsTheBroadcastStart() {
        let started = expectation(description: "broadcast started")
        let observation = OptionsChannel.observeStarted(queue: DispatchQueue(label: "test")) { started.fulfill() }
        OptionsChannel.announceStarted()
        wait(for: [started], timeout: 5)
        observation.cancel()
    }
}
