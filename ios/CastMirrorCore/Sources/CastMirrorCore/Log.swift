import Foundation
import os

/// Recent log lines. A broadcast extension has no console to read without a
/// Mac, so lines also go to the receiver's overlay on the TV and to the
/// /status page the extension serves.
public final class Log: @unchecked Sendable {
    public static let shared = Log()

    private let lock = NSLock()
    private var lines: [String] = []
    private var sinkHandler: ((String) -> Void)?
    private let logger = Logger(subsystem: "io.github.duali7y7.castmirror", category: "mirror")
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// Records a line. `forward: false` keeps it off the TV, for lines that
    /// came from the TV in the first place.
    public func info(_ message: String, forward: Bool = true) {
        logger.log("\(message, privacy: .public)")
        let line = formatter.string(from: Date()) + " " + message
        let sink: ((String) -> Void)? = lock.withLock {
            lines.append(line)
            if lines.count > 300 { lines.removeFirst(lines.count - 300) }
            return forward ? sinkHandler : nil
        }
        sink?(message)
    }

    /// Called with each new line, to forward it to the TV.
    public var sink: ((String) -> Void)? {
        get { lock.withLock { sinkHandler } }
        set { lock.withLock { sinkHandler = newValue } }
    }

    public var recent: [String] { lock.withLock { lines } }
}

func logInfo(_ message: String) {
    Log.shared.info(message)
}
