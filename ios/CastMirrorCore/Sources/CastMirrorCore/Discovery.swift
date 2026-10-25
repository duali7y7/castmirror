import Foundation
import Network

public struct Chromecast: Hashable {
    /// The name set in the Google Home app, e.g. "Living Room TV".
    public let name: String
    public let model: String
    public let endpoint: NWEndpoint
}

/// Finds Chromecasts with Bonjour (_googlecast._tcp). The first search in the
/// app is what makes iOS ask for Local Network access, which the broadcast
/// extension then shares.
public final class ChromecastBrowser: @unchecked Sendable {
    /// Called with the full, sorted list whenever it changes.
    public var onChange: (([Chromecast]) -> Void)?

    private let queue = DispatchQueue(label: "castmirror.browse")
    private var browser: NWBrowser?

    public init() {}

    public func start() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let devices = results.compactMap(Self.chromecast).sorted { $0.name < $1.name }
            self?.onChange?(devices)
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state { logInfo("browse failed: \(error)") }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }

    static func chromecast(_ result: NWBrowser.Result) -> Chromecast? {
        guard case .service(let serviceName, _, _, _) = result.endpoint else { return nil }
        var name = serviceName
        var model = ""
        if case .bonjour(let txt) = result.metadata {
            name = txt["fn"] ?? serviceName
            model = txt["md"] ?? ""
        }
        return Chromecast(name: name, model: model, endpoint: result.endpoint)
    }

    /// Waits up to `timeout` seconds for the first Chromecast.
    public static func first(timeout: TimeInterval) async -> Chromecast? {
        await withCheckedContinuation { continuation in
            let browser = ChromecastBrowser()
            let lock = NSLock()
            var finished = false
            func finish(_ device: Chromecast?) {
                let first: Bool = lock.withLock {
                    defer { finished = true }
                    return !finished
                }
                guard first else { return }
                browser.onChange = nil
                browser.stop()
                continuation.resume(returning: device)
            }
            browser.onChange = { devices in
                if let device = devices.first { finish(device) }
            }
            browser.start()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }
}
