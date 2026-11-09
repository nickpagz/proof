import Foundation
import Network

/// Tiny HTTP listener on 127.0.0.1 that catches the OAuth redirect once, answers the browser, and stops.
final class LoopbackServer {
    struct Callback {
        let code: String?
        let state: String?
        let error: String?
        let errorDescription: String?
    }

    private let port: UInt16
    private let queue = DispatchQueue(label: "io.github.nickpagz.proof.loopback")
    private var listener: NWListener?
    private var continuation: CheckedContinuation<Callback, Error>?
    private var pending: Result<Callback, Error>?
    private var finished = false
    private var connections: [NWConnection] = []

    init(port: UInt16) {
        self.port = port
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Log.note("sign-in callback listener ready on 127.0.0.1:\(self?.port ?? 0)")
            case .failed(let error):
                self?.finish(.failure(Self.map(error)))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    /// Resolves with the first /callback request, or throws on timeout, cancellation, or listener failure.
    func waitForCallback(timeout: Duration) async throws -> Callback {
        try await withThrowingTaskGroup(of: Callback.self) { group in
            group.addTask { try await self.awaitCallback() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw WPComError.timedOut
            }
            guard let first = try await group.next() else { throw WPComError.cancelled }
            group.cancelAll()
            return first
        }
    }

    func cancel() {
        finish(.failure(WPComError.cancelled))
    }

    private func awaitCallback() async throws -> Callback {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Callback, Error>) in
                queue.async {
                    if let pending = self.pending {
                        continuation.resume(with: pending)
                    } else {
                        self.continuation = continuation
                    }
                }
            }
        } onCancel: {
            finish(.failure(WPComError.cancelled))
        }
    }

    private func finish(_ result: Result<Callback, Error>) {
        queue.async {
            guard !self.finished else { return }
            self.finished = true
            if let continuation = self.continuation {
                self.continuation = nil
                continuation.resume(with: result)
            } else {
                self.pending = result
            }
            // Accepted connections outlive the listener, so the browser still gets its response.
            self.listener?.cancel()
            self.listener = nil
        }
    }

    private static func map(_ error: NWError) -> WPComError {
        if case .posix(let code) = error, code == .EADDRINUSE { return .portInUse }
        return .failed("Could not listen for the sign-in callback: \(error.localizedDescription)")
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                self.handle(requestHead: head, on: connection)
            } else if isComplete || error != nil || buffer.count > 65536 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func handle(requestHead: String, on connection: NWConnection) {
        let requestLine = requestHead.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            respond(connection, status: 400, body: "<p>Bad request.</p>")
            return
        }
        guard let components = URLComponents(string: "http://127.0.0.1\(parts[1])"), components.path == "/callback" else {
            respond(connection, status: 404, body: "<p>Not found.</p>")
            return
        }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            values[item.name] = item.value ?? ""
        }
        let callback = Callback(code: values["code"], state: values["state"],
                                error: values["error"], errorDescription: values["error_description"])
        if finished {
            respond(connection, status: 200, body: "<h1>Already signed in</h1><p>You can close this window and return to Proof.</p>")
            return
        }
        if callback.error != nil {
            respond(connection, status: 200, body: "<h1>Sign-in cancelled</h1><p>You can close this window and try again from Proof.</p>")
        } else {
            respond(connection, status: 200, body: "<h1>Signed in</h1><p>You can close this window and return to Proof.</p>")
        }
        finish(.success(callback))
    }

    private func respond(_ connection: NWConnection, status: Int, body: String) {
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>Proof</title>\
        <style>body{font-family:-apple-system,system-ui,sans-serif;margin:3rem auto;max-width:28rem;text-align:center;color:#222}\
        h1{font-weight:600}</style></head><body>\(body)</body></html>
        """
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 404: reason = "Not Found"
        default: reason = "Bad Request"
        }
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data((head + html).utf8), contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}
