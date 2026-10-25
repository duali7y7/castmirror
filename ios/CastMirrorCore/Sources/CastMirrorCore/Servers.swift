import Foundation
import Network

public struct ServerError: LocalizedError {
    public let errorDescription: String?
}

/// Starts a listener on `preferred`, or on any free port if that one is taken
/// (or `preferred` is 0), and returns the port it got.
private func listen(_ parameters: NWParameters, preferred: UInt16, queue: DispatchQueue,
                    onConnection: @escaping (NWConnection) -> Void) async throws -> (NWListener, UInt16) {
    var ports: [NWEndpoint.Port] = [.any]
    if preferred != 0, let port = NWEndpoint.Port(rawValue: preferred) { ports.insert(port, at: 0) }
    for port in ports {
        guard let listener = try? NWListener(using: parameters, on: port) else { continue }
        listener.newConnectionHandler = onConnection
        let ready: UInt16? = await withCheckedContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !resumed { resumed = true; continuation.resume(returning: listener.port?.rawValue) }
                case .failed, .cancelled:
                    if !resumed { resumed = true; listener.cancel(); continuation.resume(returning: nil) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        if let ready { return (listener, ready) }
    }
    throw ServerError(errorDescription: "Couldn't open a network port on the phone.")
}

/// The WebSocket the receiver connects back to: binary messages carry the
/// MP4 chunks, text messages carry JSON control messages both ways. One
/// receiver at a time; a new connection replaces the old one.
public final class WebSocketServer: @unchecked Sendable {
    public var onConnect: (() -> Void)?
    public var onText: ((String) -> Void)?
    public var onDisconnect: (() -> Void)?

    private let queue = DispatchQueue(label: "castmirror.ws")
    private var listener: NWListener?
    private var current: NWConnection?
    private let lock = NSLock()
    private var generation = 0
    private var inFlight = 0

    public init() {}

    public func start(preferredPort: UInt16) async throws -> UInt16 {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.maximumMessageSize = 16 << 20
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        let (listener, port) = try await listen(parameters, preferred: preferredPort, queue: queue) { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        return port
    }

    public func stop() {
        queue.async {
            self.listener?.cancel()
            self.current?.cancel()
            self.current = nil
        }
    }

    /// Sends one message. Safe from any thread.
    public func send(_ data: Data, text: Bool = false) {
        queue.async {
            guard let connection = self.current else { return }
            let metadata = NWProtocolWebSocket.Metadata(opcode: text ? .text : .binary)
            let context = NWConnection.ContentContext(identifier: text ? "text" : "binary", metadata: [metadata])
            let count = data.count
            let generation = self.lock.withLock { () -> Int in
                self.inFlight += count
                return self.generation
            }
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] _ in
                guard let self else { return }
                self.lock.withLock {
                    if self.generation == generation { self.inFlight -= count }
                }
            })
        }
    }

    public func sendText(_ text: String) {
        send(Data(text.utf8), text: true)
    }

    /// Bytes handed to the connection but not sent yet.
    public var backlog: Int {
        lock.withLock { inFlight }
    }

    private func accept(_ connection: NWConnection) {
        current?.cancel()
        current = connection
        lock.withLock {
            generation += 1
            inFlight = 0
        }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                if case .hostPort(let host, _) = connection.endpoint { logInfo("receiver connected from \(host)") }
                self.onConnect?()
            case .failed, .cancelled:
                if self.current === connection {
                    self.current = nil
                    self.onDisconnect?()
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .close {
                connection.cancel()
                return
            }
            if metadata?.opcode == .text, let data, let text = String(data: data, encoding: .utf8) {
                self.onText?(text)
            }
            self.receive(on: connection)
        }
    }
}

/// Serves the receiver page (bundled with the extension) at /receiver/, and
/// recent log lines at /status. The Chromecast loads the page from here over
/// plain http, so the page's ws:// connection back isn't mixed content.
public final class HTTPServer: @unchecked Sendable {
    /// Text for /status.
    public var status: () -> String = { Log.shared.recent.joined(separator: "\n") + "\n" }

    private let receiverDirectory: URL?
    private let queue = DispatchQueue(label: "castmirror.http")
    private var listener: NWListener?

    public init(receiverDirectory: URL?) {
        self.receiverDirectory = receiverDirectory
    }

    public func start(preferredPort: UInt16) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let (listener, port) = try await listen(parameters, preferred: preferredPort, queue: queue) { [weak self] connection in
            self?.serve(connection)
        }
        self.listener = listener
        return port
    }

    public func stop() {
        queue.async { self.listener?.cancel() }
    }

    struct Response {
        let status: String
        let contentType: String
        let body: Data
    }

    func response(for target: String) -> Response {
        let notFound = Response(status: "404 Not Found", contentType: "text/plain", body: Data("not found\n".utf8))
        let path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        if path == "/status" {
            return Response(status: "200 OK", contentType: "text/plain; charset=utf-8", body: Data(status().utf8))
        }
        let prefix = "/receiver/"
        guard let receiverDirectory, path.hasPrefix(prefix) else { return notFound }
        var relative = String(path.dropFirst(prefix.count))
        relative = relative.removingPercentEncoding ?? relative
        if relative.isEmpty { relative = "index.html" }
        let parts = relative.split(separator: "/")
        guard !parts.contains(where: { $0.hasPrefix(".") }) else { return notFound }
        let file = parts.reduce(receiverDirectory) { $0.appendingPathComponent(String($1)) }
        guard let body = try? Data(contentsOf: file) else { return notFound }
        let types = ["html": "text/html; charset=utf-8", "js": "text/javascript", "css": "text/css"]
        return Response(status: "200 OK", contentType: types[file.pathExtension] ?? "application/octet-stream", body: body)
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(connection, received: Data())
    }

    private func readRequest(_ connection: NWConnection, received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var received = received
            if let data { received.append(data) }
            if let end = received.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: received[received.startIndex..<end.lowerBound], as: UTF8.self)
                self.respond(connection, requestHead: head)
            } else if error != nil || isComplete || received.count > 16384 {
                connection.cancel()
            } else {
                self.readRequest(connection, received: received)
            }
        }
    }

    private func respond(_ connection: NWConnection, requestHead: String) {
        // Request line: GET /receiver/index.html HTTP/1.1
        let requestLine = requestHead.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        let response = parts.count >= 2 ? self.response(for: String(parts[1])) : self.response(for: "/")
        let head = "HTTP/1.1 \(response.status)\r\n"
            + "Content-Type: \(response.contentType)\r\n"
            + "Content-Length: \(response.body.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + response.body, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
