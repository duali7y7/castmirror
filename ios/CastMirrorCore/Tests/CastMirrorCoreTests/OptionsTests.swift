@testable import CastMirrorCore
import XCTest

final class OptionsTests: XCTestCase {
    /// The app and the extension are separate processes on the phone; Darwin
    /// notifications reach observers in the posting process too, so one
    /// process can play both sides here.
    func testSettingsReachTheExtension() {
        let queue = DispatchQueue(label: "test")
        var stats: [Bool] = []
        var sounds: [SoundMode] = []
        var expected = expectation(description: "first settings")
        expected.expectedFulfillmentCount = 2
        let observation = OptionsChannel.observe(queue: queue, showStats: { show in
            stats.append(show)
            expected.fulfill()
        }, sound: { sound in
            sounds.append(sound)
            expected.fulfill()
        })
        OptionsChannel.post(MirrorOptions(showStats: true, sound: .tv))
        wait(for: [expected], timeout: 5)

        expected = expectation(description: "second settings")
        expected.expectedFulfillmentCount = 2
        OptionsChannel.post(MirrorOptions(showStats: false, sound: .tvInVideo))
        wait(for: [expected], timeout: 5)
        XCTAssertEqual(queue.sync { stats }, [true, false])
        XCTAssertEqual(queue.sync { sounds }, [.tv, .tvInVideo])

        observation.cancel()
        OptionsChannel.post(MirrorOptions(showStats: true, sound: .phone))
        queue.sync {}
        XCTAssertEqual(queue.sync { stats }, [true, false], "nothing heard after cancelling")
    }

    func testAppHearsTheBroadcastStart() {
        let started = expectation(description: "broadcast started")
        let observation = OptionsChannel.observeStarted(queue: DispatchQueue(label: "test")) { started.fulfill() }
        OptionsChannel.announceStarted()
        wait(for: [started], timeout: 5)
        observation.cancel()
    }

    func testOptionsRoundTripThroughUserDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "castmirror-tests-\(UUID().uuidString)"))
        XCTAssertEqual(MirrorOptions(defaults: defaults), MirrorOptions())
        MirrorOptions(showStats: true, sound: .tvInVideo).save(to: defaults)
        XCTAssertEqual(MirrorOptions(defaults: defaults), MirrorOptions(showStats: true, sound: .tvInVideo))
    }
}
