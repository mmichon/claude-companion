import Foundation

public enum Companion {
    public static let serviceType = "_claudecompanion._tcp"
    public static let phonePort: UInt16 = 47820
    public static let hookPort: UInt16 = 47821
}

/// What the board shows for a session, in priority order (highest first).
public enum SessionStatus: String, Codable, CaseIterable, Sendable {
    case permission  // a tool permission prompt is pending
    case waiting     // Claude asked something / turn ended needing you
    case error
    case busy
    case done        // turn finished, not yet looked at on the Mac
    case idle

    public var needsYou: Bool { self == .permission || self == .waiting }

    public var label: String {
        switch self {
        case .permission: return "Permission"
        case .waiting: return "Waiting on you"
        case .error: return "Error"
        case .busy: return "Working"
        case .done: return "Done · unread"
        case .idle: return "Idle"
        }
    }
}

public struct PendingPrompt: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case question, message }

    /// One AskUserQuestion question.
    public struct Question: Codable, Hashable, Sendable {
        public var question: String
        public var header: String?
        public var options: [String]
        public var multiSelect: Bool

        public init(question: String, header: String? = nil, options: [String], multiSelect: Bool = false) {
            self.question = question
            self.header = header
            self.options = options
            self.multiSelect = multiSelect
        }
    }

    public var kind: Kind
    public var text: String
    public var options: [String]
    public var questions: [Question]?
    /// Set while the AskUserQuestion hook is held, so the phone can answer it.
    public var requestId: String?

    public init(kind: Kind, text: String, options: [String] = [], questions: [Question]? = nil, requestId: String? = nil) {
        self.kind = kind
        self.text = text
        self.options = options
        self.questions = questions
        self.requestId = requestId
    }
}

public struct PermissionInfo: Codable, Hashable, Sendable {
    public var requestId: String
    public var toolName: String
    /// One-line description: the command, file path, or URL.
    public var summary: String
    /// Longer detail (description, full input) for the sheet.
    public var detail: String
    /// False while you're at the Mac: the desktop prompt is showing instead.
    public var decidableFromPhone: Bool
    public var createdAt: Date

    public init(requestId: String, toolName: String, summary: String, detail: String, decidableFromPhone: Bool, createdAt: Date) {
        self.requestId = requestId
        self.toolName = toolName
        self.summary = summary
        self.detail = detail
        self.decidableFromPhone = decidableFromPhone
        self.createdAt = createdAt
    }
}

public struct SessionInfo: Codable, Hashable, Identifiable, Sendable {
    /// Desktop session id (`local_…`) when there is one, else the CLI session id.
    public var id: String
    public var cliSessionId: String
    public var pid: Int32
    public var title: String
    public var project: String
    public var cwd: String
    public var status: SessionStatus
    public var statusSince: Date
    public var lastActivityAt: Date?
    public var model: String?
    public var permissionMode: String?
    /// Latest recap of the turn (desktop summary or wrap-up).
    public var summary: String?
    /// What the desktop thinks you need to do, if anything.
    public var needsAction: String?
    public var prompt: PendingPrompt?
    public var permission: PermissionInfo?
    public var isDesktop: Bool

    public init(id: String, cliSessionId: String, pid: Int32, title: String, project: String, cwd: String,
                status: SessionStatus, statusSince: Date, lastActivityAt: Date?, model: String?,
                permissionMode: String?, summary: String?, needsAction: String?, prompt: PendingPrompt?,
                permission: PermissionInfo?, isDesktop: Bool) {
        self.id = id
        self.cliSessionId = cliSessionId
        self.pid = pid
        self.title = title
        self.project = project
        self.cwd = cwd
        self.status = status
        self.statusSince = statusSince
        self.lastActivityAt = lastActivityAt
        self.model = model
        self.permissionMode = permissionMode
        self.summary = summary
        self.needsAction = needsAction
        self.prompt = prompt
        self.permission = permission
        self.isDesktop = isDesktop
    }
}

public struct UsageInfo: Codable, Hashable, Sendable {
    /// Plan usage percentages from the desktop app, when a recent sample exists.
    public var fiveHourPct: Double?
    public var sevenDayPct: Double?
    /// When each plan window resets, when the usage API answered.
    public var fiveHourResetsAt: Date?
    public var sevenDayResetsAt: Date?
    public var planSampledAt: Date?
    public var todayInputTokens: Int
    public var todayOutputTokens: Int
    public var todayCacheReadTokens: Int
    public var todayMessages: Int

    public init(fiveHourPct: Double? = nil, sevenDayPct: Double? = nil,
                fiveHourResetsAt: Date? = nil, sevenDayResetsAt: Date? = nil, planSampledAt: Date? = nil,
                todayInputTokens: Int = 0, todayOutputTokens: Int = 0, todayCacheReadTokens: Int = 0, todayMessages: Int = 0) {
        self.fiveHourPct = fiveHourPct
        self.sevenDayPct = sevenDayPct
        self.fiveHourResetsAt = fiveHourResetsAt
        self.sevenDayResetsAt = sevenDayResetsAt
        self.planSampledAt = planSampledAt
        self.todayInputTokens = todayInputTokens
        self.todayOutputTokens = todayOutputTokens
        self.todayCacheReadTokens = todayCacheReadTokens
        self.todayMessages = todayMessages
    }
}

/// A folder Claude Code was used in lately, for starting a new session there from the phone.
public struct RecentProject: Codable, Hashable, Identifiable, Sendable {
    public var path: String
    public var name: String
    public var lastUsedAt: Date

    public var id: String { path }

    public init(path: String, name: String, lastUsedAt: Date) {
        self.path = path
        self.name = name
        self.lastUsedAt = lastUsedAt
    }
}

public struct DNDState: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable { case off, pinnedOnly, muted }
    public var mode: Mode
    public var night: Bool

    public init(mode: Mode = .off, night: Bool = false) {
        self.mode = mode
        self.night = night
    }
}

public struct Snapshot: Codable, Hashable, Sendable {
    public var sessions: [SessionInfo]
    /// Most recent first. Optional so an older companiond's snapshots still decode.
    public var projects: [RecentProject]?
    public var usage: UsageInfo
    public var macName: String
    public var macIdleSeconds: Double
    /// Seconds of keyboard/mouse idle after which the phone can answer permissions.
    public var awayThreshold: Double
    public var generatedAt: Date

    public init(sessions: [SessionInfo], projects: [RecentProject]? = nil, usage: UsageInfo, macName: String,
                macIdleSeconds: Double, awayThreshold: Double, generatedAt: Date) {
        self.sessions = sessions
        self.projects = projects
        self.usage = usage
        self.macName = macName
        self.macIdleSeconds = macIdleSeconds
        self.awayThreshold = awayThreshold
        self.generatedAt = generatedAt
    }
}

/// One JSON message over the WebSocket, either direction. `type` says which fields are set.
public struct WireMessage: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        // server -> phone
        case hello, authOK, authFailed, pairCode, snapshot, actionResult
        // phone -> server
        case auth, pairRequest, pair, action, decide, answer, setDND
    }

    public var type: Kind
    public var token: String?
    public var code: String?
    public var deviceName: String?
    public var needsPairing: Bool?
    public var macName: String?
    public var snapshot: Snapshot?
    public var action: String?
    public var sessionId: String?
    public var requestId: String?
    public var allow: Bool?
    /// Question text -> chosen label(s), comma-joined for multi-select.
    public var answers: [String: String]?
    public var dnd: DNDState?
    public var message: String?
    /// Project folder for `newSessionIn`.
    public var folder: String?

    public init(type: Kind, token: String? = nil, code: String? = nil, deviceName: String? = nil, needsPairing: Bool? = nil,
                macName: String? = nil, snapshot: Snapshot? = nil, action: String? = nil, sessionId: String? = nil,
                requestId: String? = nil, allow: Bool? = nil, answers: [String: String]? = nil, dnd: DNDState? = nil,
                message: String? = nil, folder: String? = nil) {
        self.type = type
        self.token = token
        self.code = code
        self.deviceName = deviceName
        self.needsPairing = needsPairing
        self.macName = macName
        self.snapshot = snapshot
        self.action = action
        self.sessionId = sessionId
        self.requestId = requestId
        self.allow = allow
        self.answers = answers
        self.dnd = dnd
        self.message = message
        self.folder = folder
    }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()

    public func encoded() -> Data { (try? WireMessage.encoder.encode(self)) ?? Data() }
    public static func decode(_ data: Data) -> WireMessage? { try? decoder.decode(WireMessage.self, from: data) }
}
