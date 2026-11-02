import AppKit
import CoreGraphics
import CompanionShared

func logLine(_ s: String) {
    FileHandle.standardError.write("\(ISO8601DateFormatter().string(from: Date())) \(s)\n".data(using: .utf8)!)
}

/// Seconds since the last keyboard/mouse event on this Mac.
func macIdleSeconds() -> Double {
    CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
}

final class Daemon {
    static let queue = DispatchQueue(label: "claude-companiond")

    /// Keyboard/mouse idle after which a permission request waits for the phone instead of the desktop.
    let awayThreshold: Double = ProcessInfo.processInfo.environment["COMPANION_AWAY_SECONDS"].flatMap(Double.init) ?? 60
    /// Longest a held permission request waits for the phone before falling back to the desktop prompt.
    let holdLimit: TimeInterval = 9 * 60 + 30

    let macName = Host.current().localizedName ?? "Mac"
    let store = SessionStore()
    let usage = UsageTracker()
    let tokens = TokenStore()
    var phone: PhoneServer!
    var hooks: HookServer!
    var statusBar: StatusBar?

    // Permission requests by CLI session id.
    private struct PendingPermission {
        var info: PermissionInfo
        var cliSessionId: String
        /// Set while the hook is held waiting for the phone.
        var respond: ((Data) -> Void)?
    }
    private var permissions: [String: PendingPermission] = [:]

    // AskUserQuestion requests held for the phone, by CLI session id.
    private struct PendingQuestion {
        var requestId: String
        var input: [String: Any]
        var createdAt: Date
        var respond: (Data) -> Void
    }
    private var questions: [String: PendingQuestion] = [:]

    private var pairing: (code: String, expires: Date, attempts: Int)?
    private var dnd = DNDState()
    private var lastSnapshot: Snapshot?
    private var lastBroadcast = Date.distantPast
    private var lastUsageRefresh = Date.distantPast

    func start() throws {
        phone = try PhoneServer(port: Companion.phonePort, name: macName, queue: Self.queue)
        phone.onMessage = { [weak self] msg, client in self?.handle(msg, from: client) }
        phone.onClientsChanged = { [weak self] in self?.updateStatusBar() }
        hooks = try HookServer(port: Companion.hookPort, queue: Self.queue) { [weak self] body, respond in
            self?.handleHook(body, respond: respond) ?? respond(Data("{}".utf8))
        }
        phone.start()
        hooks.start()

        let timer = DispatchSource.makeTimerSource(queue: Self.queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }
    private var timer: DispatchSourceTimer?

    // MARK: snapshot loop

    func buildSnapshot() -> Snapshot {
        if Date().timeIntervalSince(lastUsageRefresh) > 30 {
            lastUsageRefresh = Date()
            usage.refresh()
        }
        var infos: [String: PermissionInfo] = [:]
        for (cli, p) in permissions { infos[cli] = p.info }
        let sessions = store.sessions(permissions: infos)
        return Snapshot(sessions: sessions, projects: store.recentProjects(live: sessions), usage: usage.usage, macName: macName,
                        macIdleSeconds: macIdleSeconds(), awayThreshold: awayThreshold, generatedAt: Date())
    }

    private func tick() {
        reconcilePermissions()
        let snap = buildSnapshot()
        let changed = lastSnapshot.map { $0.sessions != snap.sessions || $0.projects != snap.projects || $0.usage != snap.usage } ?? true
        // A periodic resend keeps the phone's idle readout and connection liveness fresh.
        if changed || Date().timeIntervalSince(lastBroadcast) > 10 {
            phone.broadcast(WireMessage(type: .snapshot, snapshot: snap))
            lastBroadcast = Date()
        }
        if changed { updateStatusBar(snap) }
        lastSnapshot = snap
    }

    /// Releases held requests when you come back to the keyboard or the hold runs out, and drops
    /// display-only entries once the session moves on.
    private func reconcilePermissions() {
        let idle = macIdleSeconds()
        let busy = Set((lastSnapshot?.sessions ?? []).filter { $0.status == .busy }.map(\.cliSessionId))
        for (cli, p) in permissions {
            if let respond = p.respond {
                if Date().timeIntervalSince(p.info.createdAt) > holdLimit || belongsOnMac(cli, since: p.info.createdAt, idle: idle) {
                    logLine("releasing permission \(p.info.requestId) to the desktop prompt")
                    respond(Data("{}".utf8))
                    permissions[cli]?.respond = nil
                    permissions[cli]?.info.decidableFromPhone = false
                }
            } else if busy.contains(cli), Date().timeIntervalSince(p.info.createdAt) > 2 {
                permissions[cli] = nil
            }
        }
        for (cli, q) in questions where Date().timeIntervalSince(q.createdAt) > holdLimit
            || belongsOnMac(cli, since: q.createdAt, idle: idle) {
            logLine("releasing question \(q.requestId) to the desktop prompt")
            q.respond(Data("{}".utf8))
            questions[cli] = nil
            store.recordPrompt(Self.questionPrompt(q.input), cliSessionId: cli)
        }
    }

    // MARK: hooks

    private func handleHook(_ body: Data, respond: @escaping (Data) -> Void) {
        let empty = Data("{}".utf8)
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let event = obj["hook_event_name"] as? String,
              let cli = obj["session_id"] as? String else { respond(empty); return }

        switch event {
        case "UserPromptSubmit":
            store.clearPrompt(cliSessionId: cli)
            dropPermission(cli)
        case "Stop":
            store.clearPrompt(cliSessionId: cli)
            dropPermission(cli)
        case "Notification":
            if let msg = obj["message"] as? String { store.recordNotification(msg, cliSessionId: cli) }
        case "PreToolUse":
            if obj["tool_name"] as? String == "AskUserQuestion" {
                store.recordPrompt(Self.questionPrompt(obj["tool_input"]), cliSessionId: cli)
            }
        case "PermissionRequest":
            handlePermissionRequest(obj, cli: cli, respond: respond)
            tick()
            return
        default:
            break
        }
        respond(empty)
        tick()
    }

    private func handlePermissionRequest(_ obj: [String: Any], cli: String, respond: @escaping (Data) -> Void) {
        dropPermission(cli)
        let tool = obj["tool_name"] as? String ?? "Tool"
        let input = obj["tool_input"] as? [String: Any] ?? [:]
        let away = !belongsOnMac(cli, since: Date(), idle: macIdleSeconds())
        // Desktop sessions ask AskUserQuestion through the permission hook: show it as the question it is.
        if tool == "AskUserQuestion", var prompt = Self.questionPrompt(input) {
            let requestId = UUID().uuidString
            if away {
                prompt.requestId = requestId
                questions[cli] = PendingQuestion(requestId: requestId, input: input, createdAt: Date(), respond: respond)
            }
            store.recordPrompt(prompt, cliSessionId: cli)
            logLine("question \(requestId) [\(cli)] — \(away ? "held for phone" : "desktop prompt")")
            if !away { respond(Data("{}".utf8)) }
            return
        }
        let (summary, detail) = Self.describe(tool: tool, input: input)
        let info = PermissionInfo(requestId: UUID().uuidString, toolName: tool, summary: summary, detail: detail,
                                  decidableFromPhone: away, createdAt: Date())
        permissions[cli] = PendingPermission(info: info, cliSessionId: cli, respond: away ? respond : nil)
        logLine("permission \(info.requestId) [\(cli)] \(tool): \(summary) — \(away ? "held for phone" : "desktop prompt")")
        if !away { respond(Data("{}".utf8)) }
    }

    /// Phone first: a desktop session's question or permission prompt waits for the phone until you open that session in Claude, or are
    /// using the Mac with it already on screen. A CLI session has no focus signal, so any keyboard/mouse use counts.
    private func belongsOnMac(_ cli: String, since: Date, idle: Double) -> Bool {
        let active = idle < awayThreshold
        guard let focus = store.desktopFocus(forCli: cli) else { return active }
        if let opened = focus.lastFocused, opened > since { return true }
        let claudeFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.anthropic.claudefordesktop"
        return active && claudeFrontmost && focus.isCurrent
    }

    private func dropPermission(_ cli: String) {
        if let respond = permissions[cli]?.respond { respond(Data("{}".utf8)) }
        permissions[cli] = nil
        questions.removeValue(forKey: cli)?.respond(Data("{}".utf8))
    }

    private func answer(requestId: String, answers: [String: String]) -> String {
        guard let (cli, q) = questions.first(where: { $0.value.requestId == requestId }) else {
            return "That question is no longer pending."
        }
        var updated = q.input
        updated["answers"] = answers
        let decision: [String: Any] = ["behavior": "allow", "updatedInput": updated]
        let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        q.respond((try? JSONSerialization.data(withJSONObject: out)) ?? Data("{}".utf8))
        questions[cli] = nil
        store.clearPrompt(cliSessionId: cli)
        logLine("question \(requestId) answered from phone")
        return "Answered"
    }

    private func decide(requestId: String, allow: Bool) -> String {
        guard let (cli, p) = permissions.first(where: { $0.value.info.requestId == requestId }) else {
            return "That request is no longer pending."
        }
        guard let respond = p.respond else { return "Answer it on the Mac — it's showing there." }
        let decision: [String: Any] = allow
            ? ["behavior": "allow"]
            : ["behavior": "deny", "message": "Denied from the companion phone."]
        let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        respond((try? JSONSerialization.data(withJSONObject: out)) ?? Data("{}".utf8))
        permissions[cli] = nil
        logLine("permission \(requestId) \(allow ? "allowed" : "denied") from phone")
        return allow ? "Allowed" : "Denied"
    }

    static func describe(tool: String, input: [String: Any]) -> (String, String) {
        let summary = (input["command"] as? String)
            ?? (input["file_path"] as? String)
            ?? (input["url"] as? String)
            ?? (input["pattern"] as? String)
            ?? (input["path"] as? String)
            ?? tool
        var detail = ""
        if let d = input["description"] as? String { detail += d + "\n\n" }
        if let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            detail += String(s.prefix(4000))
        }
        return (String(summary.prefix(500)), detail)
    }

    static func questionPrompt(_ any: Any?) -> PendingPrompt? {
        guard let input = any as? [String: Any], let qs = input["questions"] as? [[String: Any]], !qs.isEmpty else { return nil }
        let parsed = qs.compactMap { q -> PendingPrompt.Question? in
            guard let text = q["question"] as? String else { return nil }
            let options = ((q["options"] as? [[String: Any]]) ?? []).compactMap { $0["label"] as? String }
            return PendingPrompt.Question(question: text, header: q["header"] as? String, options: options,
                                          multiSelect: q["multiSelect"] as? Bool ?? false)
        }
        let text = parsed.map(\.question).joined(separator: "\n\n")
        return PendingPrompt(kind: .question, text: text, options: parsed.flatMap(\.options), questions: parsed)
    }

    // MARK: phone messages

    private func handle(_ msg: WireMessage, from client: PhoneServer.Client) {
        switch msg.type {
        case .auth:
            if let t = msg.token, let name = tokens.deviceName(for: t) {
                client.authed = true
                client.deviceName = name
                phone.send(WireMessage(type: .authOK, macName: macName), to: client)
                phone.send(WireMessage(type: .snapshot, snapshot: buildSnapshot()), to: client)
                logLine("phone connected: \(name)")
            } else {
                phone.send(WireMessage(type: .authFailed, needsPairing: true, macName: macName), to: client)
            }
            updateStatusBar()
        case .pairRequest:
            let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
            pairing = (code, Date().addingTimeInterval(120), 0)
            client.deviceName = msg.deviceName ?? "phone"
            phone.send(WireMessage(type: .pairCode, macName: macName), to: client)
            showPairingCode(code, device: client.deviceName)
        case .pair:
            guard var p = pairing, p.expires > Date() else {
                phone.send(WireMessage(type: .authFailed, needsPairing: true, message: "Code expired — request a new one."), to: client)
                return
            }
            if msg.code == p.code {
                let token = tokens.issue(deviceName: msg.deviceName ?? client.deviceName)
                pairing = nil
                client.authed = true
                phone.send(WireMessage(type: .authOK, token: token, macName: macName), to: client)
                phone.send(WireMessage(type: .snapshot, snapshot: buildSnapshot()), to: client)
                logLine("paired: \(client.deviceName)")
            } else {
                p.attempts += 1
                pairing = p.attempts >= 5 ? nil : p
                phone.send(WireMessage(type: .authFailed, needsPairing: true, message: "Wrong code."), to: client)
            }
            updateStatusBar()
        case .action where msg.action == "newSessionIn":
            guard client.authed, let folder = msg.folder else { return }
            let result: String
            if store.isRecentProject(folder) {
                Actions.newSession(folder: folder)
                result = "New session in \(URL(fileURLWithPath: folder).lastPathComponent)"
            } else {
                result = "Not a recent project"
            }
            phone.send(WireMessage(type: .actionResult, action: "newSessionIn", message: result, folder: folder), to: client)
        case .action:
            guard client.authed, let action = msg.action, let id = msg.sessionId else { return }
            let result = perform(action, sessionId: id)
            phone.send(WireMessage(type: .actionResult, action: action, sessionId: id, message: result), to: client)
        case .decide:
            guard client.authed, let rid = msg.requestId, let allow = msg.allow else { return }
            let result = decide(requestId: rid, allow: allow)
            phone.send(WireMessage(type: .actionResult, action: "decide", requestId: rid, message: result), to: client)
            tick()
        case .answer:
            guard client.authed, let rid = msg.requestId, let answers = msg.answers else { return }
            let result = answer(requestId: rid, answers: answers)
            phone.send(WireMessage(type: .actionResult, action: "answer", requestId: rid, message: result), to: client)
            tick()
        case .reply:
            guard client.authed, let id = msg.sessionId, let text = msg.message else { return }
            let result = reply(sessionId: id, text: text)
            phone.send(WireMessage(type: .actionResult, action: "reply", sessionId: id, message: result), to: client)
        case .setDND:
            guard client.authed, let d = msg.dnd else { return }
            dnd = d
            updateStatusBar()
        default:
            break
        }
    }

    /// Sends a short message as your next prompt, for a desktop session whose turn ended on a question.
    /// A held AskUserQuestion or permission prompt is answered through its own hook instead.
    private func reply(sessionId: String, text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "Nothing to send" }
        guard text.count <= 2000 else { return "Too long — keep replies under 2000 characters" }
        guard let s = lastSnapshot?.sessions.first(where: { $0.id == sessionId }) else { return "Session not found" }
        guard s.isDesktop else { return "Replies work for desktop sessions only" }
        guard s.status == .waiting, s.prompt?.kind == .message else { return "That session isn't waiting for a reply" }
        logLine("reply to \(sessionId) from phone (\(text.count) chars)")
        return Actions.reply(sessionId: sessionId, text: text)
            ? "Sent"
            : "Couldn't type the reply — allow claude-companion-keys under Privacy & Security → Device Control and Data Access"
    }

    private func perform(_ action: String, sessionId: String) -> String {
        switch action {
        case "open":
            Actions.openSession(sessionId)
            return "Opened on Mac"
        case "newSession":
            // The phone names a session in the project, not a path, so it can only open folders already in use.
            guard let folder = store.projectRoot(forSessionId: sessionId) else { return "Session not found" }
            Actions.newSession(folder: folder)
            return "New session in \(URL(fileURLWithPath: folder).lastPathComponent)"
        case "interrupt":
            guard store.pid(forSessionId: sessionId) != nil else { return "Session not found" }
            return Actions.interrupt(sessionId: sessionId)
                ? "Sent Esc to the session"
                : "Couldn't press Esc — allow claude-companion-keys under Privacy & Security → Device Control and Data Access"
        default:
            return "Unknown action"
        }
    }

    // MARK: menu bar

    private func showPairingCode(_ code: String, device: String) {
        logLine("pairing code for \(device): \(code)")
        let script = "display notification \"Enter \(code) on \(device.replacingOccurrences(of: "\"", with: ""))\" with title \"Claude Companion pairing\" sound name \"Glass\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
        updateStatusBar()
    }

    private func updateStatusBar(_ snap: Snapshot? = nil) {
        let snap = snap ?? lastSnapshot
        let state = StatusBar.State(
            waiting: snap?.sessions.filter { $0.status.needsYou } ?? [],
            busy: snap?.sessions.filter { $0.status == .busy }.count ?? 0,
            phones: phone?.authedNames ?? [],
            pairingCode: pairing.flatMap { $0.expires > Date() ? $0.code : nil },
            dnd: dnd)
        DispatchQueue.main.async { [weak self] in self?.statusBar?.update(state) }
    }
}

/// Paired phone tokens, kept in Application Support (local disk).
final class TokenStore {
    private let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ClaudeCompanion")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tokens.json")
    }()
    private var tokens: [String: String]

    init() {
        tokens = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
    }

    func deviceName(for token: String) -> String? { tokens[token] }

    func issue(deviceName: String) -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        tokens[token] = deviceName
        if let data = try? JSONEncoder().encode(tokens) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return token
    }

    func revokeAll() {
        tokens = [:]
        try? FileManager.default.removeItem(at: url)
    }
}
