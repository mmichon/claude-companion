import Foundation
import Network
import CompanionShared

/// WebSocket server on the LAN, advertised over Bonjour. A phone must present a token (issued by
/// pairing with a 6-digit code shown on the Mac) before it gets snapshots or can act.
final class PhoneServer {
    final class Client {
        let conn: NWConnection
        var authed = false
        var deviceName = "phone"
        init(conn: NWConnection) { self.conn = conn }
    }

    var onMessage: ((WireMessage, Client) -> Void)?
    var onClientsChanged: (() -> Void)?

    private let listener: NWListener
    private let queue: DispatchQueue
    private(set) var clients: [ObjectIdentifier: Client] = [:]

    init(port: UInt16, name: String, queue: DispatchQueue) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 1 << 20
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.service = NWListener.Service(name: name, type: Companion.serviceType)
        self.queue = queue
    }

    func start() {
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: logLine("phone server listening on \(Companion.phonePort), advertising \(Companion.serviceType)")
            case .failed(let err): logLine("phone listener failed: \(err)"); exit(1)
            default: break
            }
        }
        listener.start(queue: queue)
    }

    var authedCount: Int { clients.values.filter(\.authed).count }
    var authedNames: [String] { clients.values.filter(\.authed).map(\.deviceName) }

    func send(_ msg: WireMessage, to client: Client) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "msg", metadata: [meta])
        client.conn.send(content: msg.encoded(), contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }

    func broadcast(_ msg: WireMessage) {
        let data = msg.encoded()
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "msg", metadata: [meta])
        for c in clients.values where c.authed {
            c.conn.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
        }
    }

    private func accept(_ conn: NWConnection) {
        let client = Client(conn: conn)
        let key = ObjectIdentifier(client)
        clients[key] = client
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.clients[key] = nil
                self?.onClientsChanged?()
            default: break
            }
        }
        conn.start(queue: queue)
        receive(client)
    }

    private func receive(_ client: Client) {
        client.conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let msg = WireMessage.decode(data) { self.onMessage?(msg, client) }
            if error == nil { self.receive(client) } else { client.conn.cancel() }
        }
    }
}
