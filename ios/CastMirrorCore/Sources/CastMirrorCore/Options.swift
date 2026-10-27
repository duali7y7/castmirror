import Foundation
import notify

/// Carries the app's settings to the broadcast extension. With a free Apple
/// ID the two can't share storage (App Groups), so they use system-wide
/// Darwin notifications instead: one name per setting value, sent by the app
/// whenever it changes or a broadcast starts. The extension keeps the last
/// value it heard, for broadcasts started from Control Center.
public enum OptionsChannel {
    static let prefix = "io.github.duali7y7.castmirror."
    static let statsOn = prefix + "stats.on"
    static let statsOff = prefix + "stats.off"
    static let started = prefix + "extension.started"

    /// App side: whether the TV shows the stats overlay.
    public static func post(showStats: Bool) {
        notify_post(showStats ? statsOn : statsOff)
    }

    /// Extension side: a broadcast has started, so the app should send its settings.
    public static func announceStarted() {
        notify_post(started)
    }

    /// App side: calls `handler` on `queue` each time a broadcast starts.
    public static func observeStarted(queue: DispatchQueue, handler: @escaping () -> Void) -> Observation {
        Observation(names: [started], queue: queue) { _ in handler() }
    }

    /// Extension side: calls `onChange` on `queue` with each stats setting the app sends.
    public static func observe(queue: DispatchQueue, onChange: @escaping (_ showStats: Bool) -> Void) -> Observation {
        Observation(names: [statsOn, statsOff], queue: queue) { name in onChange(name == statsOn) }
    }

    /// Stops listening when cancelled or released.
    public final class Observation {
        private var tokens: [Int32] = []

        init(names: [String], queue: DispatchQueue, handler: @escaping (String) -> Void) {
            for name in names {
                var token: Int32 = 0
                if notify_register_dispatch(name, &token, queue, { _ in handler(name) }) == 0 {
                    tokens.append(token)
                } else {
                    logInfo("settings: couldn't listen for \(name)")
                }
            }
        }

        public func cancel() {
            tokens.forEach { notify_cancel($0) }
            tokens = []
        }

        deinit {
            cancel()
        }
    }
}
