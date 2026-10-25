import Foundation
import Network

public enum CastNamespace {
    public static let connection = "urn:x-cast:com.google.cast.tp.connection"
    public static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
    public static let receiver = "urn:x-cast:com.google.cast.receiver"
}

public enum CastError: LocalizedError {
    case malformed
    case closed
    case timeout(String)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .malformed: return "The Chromecast sent a message CastMirror couldn't read."
        case .closed: return "The connection to the Chromecast closed."
        case .timeout(let request): return "The Chromecast didn't answer (\(request))."
        case .launchFailed(let reason): return "The Chromecast couldn't open the receiver (\(reason))."
        }
    }
}

/// Minimal Cast v2 sender: TLS to port 8009, length-prefixed CastMessages,
/// JSON payloads. Just enough to launch a receiver app and talk to it, with
/// the same steps as pc-sender/src/castv2.js. All state lives on `queue`.
public final class CastClient: @unchecked Sendable {
    public enum Event {
        /// The receiver app stopped, or another app took over the TV.
        case appStopped
        case disconnected
    }

    /// Called on the client's queue.
    public var onEvent: ((Event) -> Void)?

    private let queue = DispatchQueue(label: "castmirror.cast")
    private let sourceId = "sender-castmirror"
    private var connection: NWConnection?
    private var buffer = Data()
    private var nextRequestId = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var heartbeat: DispatchSourceTimer?
    private var transportId: String?
    private var sessionId: String?
    private var closed = false

    /// This phone's IPv4 address on the connection to the Chromecast, which
    /// is the address the TV can reach the phone on.
    public private(set) var localAddress: String?

    public init() {}

    public func connect(to endpoint: NWEndpoint) async throws {
        let tls = NWProtocolTLS.Options()
        // Chromecasts present a Google device certificate rather than a public
        // CA chain. This sender doesn't need to authenticate the device, so it
        // skips verification, as other third-party senders do.
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        // IPv4, so the address handed to the TV is one its browser can use.
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard !resumed else { return }
                    resumed = true
                    self.didConnect(connection)
                    continuation.resume()
                case .waiting(let error), .failed(let error):
                    if !resumed {
                        resumed = true
                        connection.cancel()
                        continuation.resume(throwing: error)
                    } else {
                        self.didClose()
                    }
                case .cancelled:
                    if !resumed {
                        resumed = true
                        continuation.resume(throwing: CastError.closed)
                    } else {
                        self.didClose()
                    }
                default:
                    break
                }
            }
            queue.async {
                self.connection = connection
                connection.start(queue: self.queue)
            }
        }
    }

    /// Launches the receiver app (or joins it if it's already running) and
    /// opens a virtual connection to it. With `namespace`, waits until the
    /// app's page has registered it, since messages sent before then are
    /// dropped. `restart` stops a running copy first, so the app starts over
    /// from its own page.
    public func launch(appId: String, waitingFor namespace: String?, restart: Bool) async throws {
        if restart {
            let status = try await request(["type": "GET_STATUS"])
            if let running = Self.applications(in: status).first(where: { $0["appId"] as? String == appId }),
               let session = running["sessionId"] as? String {
                _ = try? await request(["type": "STOP", "sessionId": session], timeout: 5)
            }
        }

        func readyApp(_ reply: [String: Any]) -> [String: Any]? {
            guard let app = Self.applications(in: reply).first(where: { $0["appId"] as? String == appId }) else { return nil }
            if let namespace {
                let names = (app["namespaces"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
                if !names.contains(namespace) { return nil }
            }
            return app
        }

        var reply = try await request(["type": "LAUNCH", "appId": appId])
        if reply["type"] as? String == "LAUNCH_ERROR" {
            throw CastError.launchFailed(reply["reason"] as? String ?? "unknown reason")
        }
        var found = readyApp(reply)
        var attempts = 0
        while found == nil && attempts < 40 {
            try await Task.sleep(nanoseconds: 500_000_000)
            reply = try await request(["type": "GET_STATUS"])
            found = readyApp(reply)
            attempts += 1
        }
        guard let app = found, let transport = app["transportId"] as? String, let session = app["sessionId"] as? String else {
            throw CastError.launchFailed("app \(appId) didn't start")
        }
        queue.sync {
            transportId = transport
            sessionId = session
            send(to: transport, namespace: CastNamespace.connection, ["type": "CONNECT"])
        }
    }

    /// Sends a JSON message to the launched app.
    public func sendToApp(namespace: String, _ payload: [String: Any]) {
        queue.async {
            guard let transport = self.transportId else { return }
            self.send(to: transport, namespace: namespace, payload)
        }
    }

    /// Stops the launched app, which returns the TV to its home screen.
    public func stopApp() async {
        guard let session = queue.sync(execute: { sessionId }) else { return }
        _ = try? await request(["type": "STOP", "sessionId": session], timeout: 3)
    }

    public func close() {
        queue.async {
            self.closed = true
            self.heartbeat?.cancel()
            self.connection?.cancel()
        }
    }

    // MARK: - Connection

    private func didConnect(_ connection: NWConnection) {
        if case .hostPort(let host, _)? = connection.currentPath?.localEndpoint, case .ipv4(let address) = host {
            localAddress = address.rawValue.map(String.init).joined(separator: ".")
        }
        send(to: "receiver-0", namespace: CastNamespace.connection, ["type": "CONNECT"])
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            self?.send(to: "receiver-0", namespace: CastNamespace.heartbeat, ["type": "PING"])
        }
        timer.resume()
        heartbeat = timer
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                do {
                    for message in try CastMessage.takeMessages(from: &self.buffer) {
                        self.handle(message)
                    }
                } catch {
                    logInfo("cast: unreadable message, closing")
                    connection.cancel()
                    return
                }
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection)
        }
    }

    private func didClose() {
        heartbeat?.cancel()
        heartbeat = nil
        let waiting = pending
        pending = [:]
        waiting.values.forEach { $0.resume(throwing: CastError.closed) }
        if !closed {
            closed = true
            onEvent?(.disconnected)
        }
    }

    private func handle(_ message: CastMessage) {
        guard let json = (try? JSONSerialization.jsonObject(with: Data(message.payload.utf8))) as? [String: Any] else { return }
        let type = json["type"] as? String
        if message.namespace == CastNamespace.heartbeat && type == "PING" {
            send(to: message.source, namespace: CastNamespace.heartbeat, ["type": "PONG"])
            return
        }
        if let id = json["requestId"] as? Int, let continuation = pending.removeValue(forKey: id) {
            continuation.resume(returning: json)
        }
        // The device announces every status change, including our app
        // stopping or another app taking over the TV.
        if message.namespace == CastNamespace.receiver && type == "RECEIVER_STATUS", let session = sessionId,
           !Self.applications(in: json).contains(where: { $0["sessionId"] as? String == session }) {
            sessionId = nil
            onEvent?(.appStopped)
        }
    }

    // MARK: - Messages

    /// Must run on `queue`.
    private func send(to destination: String, namespace: String, _ payload: [String: Any]) {
        guard let connection, let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let message = CastMessage(source: sourceId, destination: destination, namespace: namespace,
                                  payload: String(decoding: data, as: UTF8.self))
        connection.send(content: message.framed(), completion: .contentProcessed { _ in })
    }

    /// Sends a request to the device's receiver channel and waits for the
    /// reply with the same requestId.
    private func request(_ payload: [String: Any], timeout: TimeInterval = 15) async throws -> [String: Any] {
        let name = payload["type"] as? String ?? "request"
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.connection != nil, !self.closed else {
                    continuation.resume(throwing: CastError.closed)
                    return
                }
                let id = self.nextRequestId
                self.nextRequestId += 1
                self.pending[id] = continuation
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.pending.removeValue(forKey: id)?.resume(throwing: CastError.timeout(name))
                }
                var body = payload
                body["requestId"] = id
                self.send(to: "receiver-0", namespace: CastNamespace.receiver, body)
            }
        }
    }

    private static func applications(in reply: [String: Any]) -> [[String: Any]] {
        (reply["status"] as? [String: Any])?["applications"] as? [[String: Any]] ?? []
    }
}
