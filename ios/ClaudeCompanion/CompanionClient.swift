import Foundation
import Network
import UIKit
import CompanionShared

/// Finds claude-companiond over Bonjour (or a manual host), keeps one WebSocket open, and publishes snapshots.
@MainActor
final class CompanionClient: ObservableObject {
    enum Phase: Equatable {
        case searching
        case connecting(String)
        case needsPairing(String?)
        case enteringCode(String?)
        case connected
    }

    @Published private(set) var phase: Phase = .searching
    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var macName: String?
    @Published private(set) var toast: String?
    @Published private(set) var lastMessageAt: Date?

    /// Called with (old, new) on every snapshot after the first, for sounds.
    var onSnapshot: ((Snapshot?, Snapshot) -> Void)?

    private let netQueue = DispatchQueue(label: "companion.net")
    private var browser: NWBrowser?
    private var conn: NWConnection?
    private var retryDelay: TimeInterval = 1
    private var watchdog: Timer?
    private var toastTask: Task<Void, Never>?

    var manualHost: String {
        get { UserDefaults.standard.string(forKey: "manualHost") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "manualHost"); restart() }
    }

    func start() {
        guard browser == nil, conn == nil else { return }
        #if DEBUG
        // `-debugToken <token>` on launch skips pairing, for headless simulator runs.
        if let t = UserDefaults.standard.string(forKey: "debugToken") { Keychain.token = t }
        // `-demo YES` shows made-up sessions without a Mac, for screenshots.
        if UserDefaults.standard.bool(forKey: "demo") { return loadDemo() }
        #endif
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkLiveness() }
        }
        connectOrBrowse()
    }

    func restart() {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "demo") { return loadDemo() }
        #endif
        teardown()
        retryDelay = 1
        connectOrBrowse()
    }

    #if DEBUG
    private func loadDemo() {
        let snap = DemoData.snapshot()
        snapshot = snap
        macName = snap.macName
        phase = .connected
    }
    #endif

    private func teardown() {
        browser?.cancel()
        browser = nil
        conn?.cancel()
        conn = nil
    }

    private func connectOrBrowse() {
        let manual = manualHost.trimmingCharacters(in: .whitespaces)
        if !manual.isEmpty {
            let parts = manual.split(separator: ":")
            let host = String(parts[0])
            let port = parts.count > 1 ? UInt16(parts[1]) ?? Companion.phonePort : Companion.phonePort
            connect(to: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!), label: host)
            return
        }
        phase = .searching
        let b = NWBrowser(for: .bonjour(type: Companion.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.pick(results) }
        }
        b.stateUpdateHandler = { [weak self] state in
            if case .failed = state { Task { @MainActor in self?.scheduleRetry() } }
        }
        browser = b
        b.start(queue: netQueue)
    }

    private func pick(_ results: Set<NWBrowser.Result>) {
        guard conn == nil else { return }
        let preferred = UserDefaults.standard.string(forKey: "lastMac")
        let sorted = results.sorted { a, b in
            (Self.name(a) == preferred ? 0 : 1, Self.name(a)) < (Self.name(b) == preferred ? 0 : 1, Self.name(b))
        }
        guard let first = sorted.first else { return }
        browser?.cancel()
        browser = nil
        connect(to: first.endpoint, label: Self.name(first))
    }

    private static func name(_ r: NWBrowser.Result) -> String {
        if case .service(let name, _, _, _) = r.endpoint { return name }
        return "Mac"
    }

    private func connect(to endpoint: NWEndpoint, label: String) {
        phase = .connecting(label)
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 4 << 20
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        let c = NWConnection(to: endpoint, using: params)
        conn = c
        c.stateUpdateHandler = { [weak self, weak c] state in
            Task { @MainActor in
                guard let self, let c, self.conn === c else { return }
                switch state {
                case .ready:
                    self.retryDelay = 1
                    self.lastMessageAt = Date()
                    self.send(WireMessage(type: .auth, token: Keychain.token ?? ""))
                case .failed, .cancelled:
                    self.conn = nil
                    self.scheduleRetry()
                case .waiting:
                    // No route yet (Wi-Fi off, Mac asleep): retry rather than sit in waiting.
                    c.cancel()
                default: break
                }
            }
        }
        c.start(queue: netQueue)
        receive(c)
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self, weak c] data, _, _, error in
            Task { @MainActor in
                guard let self, let c, self.conn === c else { return }
                if let data, let msg = WireMessage.decode(data) { self.handle(msg) }
                if error == nil { self.receive(c) } else { c.cancel() }
            }
        }
    }

    private func scheduleRetry() {
        teardown()
        if case .needsPairing = phase {} else if case .enteringCode = phase {} else { phase = .searching }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 15)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.conn == nil, self.browser == nil else { return }
            self.connectOrBrowse()
        }
    }

    /// The Mac resends a snapshot every 10 s; silence for 25 s means a dead socket (Mac slept, Wi-Fi blip).
    private func checkLiveness() {
        guard phase == .connected, let last = lastMessageAt, Date().timeIntervalSince(last) > 25 else { return }
        conn?.cancel()
    }

    private func handle(_ msg: WireMessage) {
        lastMessageAt = Date()
        switch msg.type {
        case .authOK:
            if let t = msg.token { Keychain.token = t }
            macName = msg.macName
            if let name = msg.macName { UserDefaults.standard.set(name, forKey: "lastMac") }
            phase = .connected
        case .authFailed:
            macName = msg.macName ?? macName
            if case .enteringCode = phase {
                phase = .enteringCode(msg.message)
            } else {
                phase = .needsPairing(msg.message)
            }
        case .pairCode:
            phase = .enteringCode(nil)
        case .snapshot:
            guard let snap = msg.snapshot else { return }
            let old = snapshot
            snapshot = snap
            macName = snap.macName
            if phase != .connected { phase = .connected }
            onSnapshot?(old, snap)
        case .actionResult:
            if let m = msg.message { showToast(m) }
        default:
            break
        }
    }

    func send(_ msg: WireMessage) {
        guard let c = conn else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "msg", metadata: [meta])
        c.send(content: msg.encoded(), contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }

    // MARK: actions

    func requestPairing() {
        send(WireMessage(type: .pairRequest, deviceName: UIDevice.current.name))
    }

    func submitCode(_ code: String) {
        send(WireMessage(type: .pair, code: code, deviceName: UIDevice.current.name))
    }

    func unpair() {
        Keychain.token = nil
        snapshot = nil
        restart()
    }

    func open(_ s: SessionInfo) {
        send(WireMessage(type: .action, action: "open", sessionId: s.id))
    }

    /// Starts a blank session on the Mac in `s`'s project.
    func newSession(like s: SessionInfo) {
        send(WireMessage(type: .action, action: "newSession", sessionId: s.id))
    }

    /// Starts a blank session on the Mac in a recently used project folder.
    func newSession(in p: RecentProject) {
        send(WireMessage(type: .action, action: "newSessionIn", folder: p.path))
    }

    func interrupt(_ s: SessionInfo) {
        send(WireMessage(type: .action, action: "interrupt", sessionId: s.id))
    }

    func decide(_ p: PermissionInfo, allow: Bool) {
        send(WireMessage(type: .decide, requestId: p.requestId, allow: allow))
    }

    func answer(requestId: String, answers: [String: String]) {
        send(WireMessage(type: .answer, requestId: requestId, answers: answers))
    }

    /// Types `text` into the session's message box on the Mac and sends it.
    func reply(_ s: SessionInfo, text: String) {
        send(WireMessage(type: .reply, sessionId: s.id, message: text))
    }

    func setDND(_ d: DNDState) {
        send(WireMessage(type: .setDND, dnd: d))
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { self?.toast = nil }
        }
    }
}

enum Keychain {
    private static let service = "com.mmichon.claudecompanion"
    private static let account = "token"

    static var token: String? {
        get {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
            return String(data: d, encoding: .utf8)
        }
        set {
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                       kSecAttrAccount as String: account]
            SecItemDelete(base as CFDictionary)
            guard let v = newValue else { return }
            var add = base
            add[kSecValueData as String] = Data(v.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
