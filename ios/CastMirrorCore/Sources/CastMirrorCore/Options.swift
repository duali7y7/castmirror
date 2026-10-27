import Foundation
import notify

/// Where the sound plays.
public enum SoundMode: String, CaseIterable, Sendable {
    /// On the phone only; the TV gets picture only, about 0.5 s behind.
    case phone
    /// On the TV, sent apart from the picture and played in step with it,
    /// at about the same delay as picture only.
    case tv
    /// On the TV, inside the video stream. Steady, but the Chromecast then
    /// holds about 2 s and can't catch up.
    case tvInVideo
}

/// The settings the app passes to the broadcast extension.
public struct MirrorOptions: Equatable, Sendable {
    public var showStats = false
    public var sound = SoundMode.phone

    /// UserDefaults keys, shared with the app's @AppStorage.
    public static let showStatsKey = "showStats"
    public static let soundKey = "sound"

    public init(showStats: Bool = false, sound: SoundMode = .phone) {
        self.showStats = showStats
        self.sound = sound
    }

    public init(defaults: UserDefaults) {
        showStats = defaults.bool(forKey: Self.showStatsKey)
        sound = defaults.string(forKey: Self.soundKey).flatMap(SoundMode.init(rawValue:)) ?? .phone
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(showStats, forKey: Self.showStatsKey)
        defaults.set(sound.rawValue, forKey: Self.soundKey)
    }
}

/// Carries the app's settings to the broadcast extension. With a free Apple
/// ID the two can't share storage (App Groups), so they use system-wide
/// Darwin notifications instead: one name per setting value, sent by the app
/// whenever it changes or a broadcast starts. The extension keeps the last
/// values it heard, for broadcasts started from Control Center.
public enum OptionsChannel {
    static let prefix = "io.github.duali7y7.castmirror."
    static let statsOn = prefix + "stats.on"
    static let statsOff = prefix + "stats.off"
    static let started = prefix + "extension.started"

    static func name(for sound: SoundMode) -> String {
        prefix + "sound." + sound.rawValue
    }

    /// App side: sends every setting.
    public static func post(_ options: MirrorOptions) {
        notify_post(options.showStats ? statsOn : statsOff)
        notify_post(name(for: options.sound))
    }

    /// Extension side: a broadcast has started, so the app should send its settings.
    public static func announceStarted() {
        notify_post(started)
    }

    /// App side: calls `handler` on `queue` each time a broadcast starts.
    public static func observeStarted(queue: DispatchQueue, handler: @escaping () -> Void) -> Observation {
        Observation(names: [started], queue: queue) { _ in handler() }
    }

    /// Extension side: calls the handlers on `queue` with each setting the app sends.
    public static func observe(queue: DispatchQueue, showStats: @escaping (Bool) -> Void,
                               sound: @escaping (SoundMode) -> Void) -> Observation {
        let sounds = Dictionary(uniqueKeysWithValues: SoundMode.allCases.map { (name(for: $0), $0) })
        return Observation(names: [statsOn, statsOff] + sounds.keys.sorted(), queue: queue) { name in
            if let mode = sounds[name] {
                sound(mode)
            } else {
                showStats(name == statsOn)
            }
        }
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
