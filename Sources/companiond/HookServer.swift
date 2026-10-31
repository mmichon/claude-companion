import Foundation
import Network

/// Minimal HTTP/1.1 server on 127.0.0.1 for `hooks/companion-hook.sh`. One POST per connection;
/// the handler may answer later (permission requests long-poll).
final class HookServer {
    typealias Handler = (_ body: Data, _ respond: @escaping (Data) -> Void) -> Void

    private let listener: NWListener
    private let queue: DispatchQueue
    private let handler: Handler

    init(port: UInt16, queue: DispatchQueue, handler: @escaping Handler) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
        self.queue = queue
        self.handler = handler
    }

    func start() {
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.stateUpdateHandler = { state in
            if case .failed(let err) = state { logLine("hook listener failed: \(err)"); exit(1) }
        }
        listener.start(queue: queue)
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        read(conn, buffer: Data())
    }

    private func read(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let (body, complete) = Self.parse(buf), complete {
                self.handler(body) { response in
                    var head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(response.count)\r\nConnection: close\r\n\r\n"
                        .data(using: .utf8)!
                    head.append(response)
                    conn.send(content: head, completion: .contentProcessed { _ in conn.cancel() })
                }
                return
            }
            if isComplete || error != nil || buf.count > 4 << 20 { conn.cancel(); return }
            self.read(conn, buffer: buf)
        }
    }

    /// Returns the body and whether all of it has arrived.
    private static func parse(_ buf: Data) -> (Data, Bool)? {
        guard let range = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let header = String(decoding: buf[buf.startIndex..<range.lowerBound], as: UTF8.self)
        var length = 0
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                length = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let body = buf[range.upperBound...]
        return (Data(body.prefix(length)), body.count >= length)
    }
}
