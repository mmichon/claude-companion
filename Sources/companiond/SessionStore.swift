import Foundation
import CompanionShared

/// Builds the live session list from Claude Code's process registry (`~/.claude/sessions/<pid>.json`)
/// and the desktop app's per-session metadata, plus state learned from hooks. All access on `Daemon.queue`.
final class SessionStore {
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var registryDir: URL { home.appendingPathComponent(".claude/sessions") }
    private var desktopRoot: URL { home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions") }

    private struct Cached<T> { var mtime: Date; var value: T }
    private var registryCache: [String: Cached<[String: Any]>] = [:]
    private var desktopCache: [String: Cached<[String: Any]>] = [:]
    private var desktopDirs: [URL] = []
    private var desktopDirsScannedAt = Date.distantPast

    // Hook-derived state, keyed by CLI session id.
    private var prompts: [String: PendingPrompt] = [:]
    private var lastNotification: [String: String] = [:]
    private var statusSince: [String: (SessionStatus, Date)] = [:]

    // MARK: hook input

    func recordPrompt(_ prompt: PendingPrompt?, cliSessionId: String) {
        prompts[cliSessionId] = prompt
    }

    func recordNotification(_ message: String, cliSessionId: String) {
        lastNotification[cliSessionId] = message
    }

    /// A new user turn or a finished turn makes earlier prompts stale.
    func clearPrompt(cliSessionId: String) {
        prompts[cliSessionId] = nil
        lastNotification[cliSessionId] = nil
    }

    // MARK: snapshot

    func sessions(permissions: [String: PermissionInfo]) -> [SessionInfo] {
        refreshDesktopDirs()
        var out: [SessionInfo] = []
        var seen = Set<String>()
        for (_, reg) in readRegistry() {
            guard let pid = (reg["pid"] as? NSNumber)?.int32Value, processAlive(pid),
                  let cliId = reg["sessionId"] as? String else { continue }
            // sdk-cli processes are tooling (Agent SDK children), not sessions you work in.
            let entrypoint = reg["entrypoint"] as? String ?? ""
            if entrypoint == "sdk-cli" { continue }
            let hostId = reg["hostSessionId"] as? String
            let id = hostId ?? cliId
            if !seen.insert(id).inserted { continue }
            let desk = hostId.flatMap { desktopMeta(for: $0) }
            if (desk?["isArchived"] as? Bool) == true { continue }

            let cwd = reg["cwd"] as? String ?? desk?["cwd"] as? String ?? ""
            let title = (desk?["title"] as? String) ?? (reg["name"] as? String) ?? URL(fileURLWithPath: cwd).lastPathComponent
            let regStatus = reg["status"] as? String ?? "idle"
            let lastFocused = ms(desk?["lastFocusedAt"])
            let lastEdge = ms(desk?["lastTurnEdgeAt"])
            let unread = lastEdge != nil && (lastFocused == nil || lastEdge! > lastFocused!)
            let summaryObj = parseJSONString(desk?["postTurnSummary"])
            let wrapUpObj = desk?["turnWrapUp"] as? [String: Any]
            let wrapUp = wrapUpObj?["description"] as? String
            let needsAction = (summaryObj?["needs_action"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // A turn that ended on a question (wrap-up ask, or a "blocked" summary of the latest reply) leaves the CLI
            // "idle", but it's still waiting on you until you send the next message.
            let turnEndedAfterUser = (lastEdge ?? .distantPast) >= (ms(desk?["latestUserFrameAt"]) ?? .distantPast)
            let wrapUpAsk = (wrapUpObj?["needsUser"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let summaryBlocked = summaryObj?["status_category"] as? String == "blocked"
                && desk?["postTurnSummaryFor"] as? String == desk?["lastAssistantUuid"] as? String
            let endedOnQuestion = turnEndedAfterUser && (wrapUpAsk != nil || summaryBlocked)
            let errorText = (desk?["error"] as? String) ?? ((desk?["error"] as? [String: Any])?["message"] as? String)

            var permission = permissions[cliId]
            var status: SessionStatus
            if permission != nil {
                status = .permission
            } else if regStatus == "waiting" {
                status = .waiting
            } else if regStatus == "busy" {
                status = .busy
            } else if errorText != nil {
                status = .error
            } else if endedOnQuestion {
                status = .waiting
            } else if unread {
                status = .done
            } else {
                status = .idle
            }

            // An answered AskUserQuestion resumes the turn without a new prompt hook.
            if status == .busy { prompts[cliId] = nil }
            var prompt = prompts[cliId]
            if status == .waiting, prompt == nil {
                // Nothing from hooks (companiond restarted, or the hook never fired): read the request off the transcript.
                let tail = transcriptTail(cliSessionId: cliId, cwd: cwd)
                if let ask = tail?.pendingTools.first(where: { $0.name == "AskUserQuestion" }) {
                    prompt = Daemon.questionPrompt(ask.input)
                } else if reg["waitingFor"] as? String == "permission prompt", let tool = tail?.pendingTools.first {
                    let (summary, detail) = Daemon.describe(tool: tool.name, input: tool.input)
                    permission = PermissionInfo(requestId: "recovered-\(tool.id)", toolName: tool.name, summary: summary,
                                                detail: detail, decidableFromPhone: false,
                                                createdAt: ms(reg["statusUpdatedAt"]) ?? Date())
                    status = .permission
                }
                if prompt == nil, permission == nil {
                    let text = wrapUpAsk ?? tail?.lastText ?? needsAction ?? lastNotification[cliId] ?? "Claude is waiting for your input."
                    prompt = PendingPrompt(kind: .message, text: text)
                }
            }
            if !status.needsYou { prompt = nil }

            let regSince = ms(reg["statusUpdatedAt"]) ?? Date()
            let since: Date
            if let prev = statusSince[id], prev.0 == status {
                since = prev.1
            } else {
                since = status == .done ? (lastEdge ?? regSince) : (permission?.createdAt ?? regSince)
                statusSince[id] = (status, since)
            }

            out.append(SessionInfo(
                id: id, cliSessionId: cliId, pid: pid, title: title,
                project: projectName(forCwd: cwd), cwd: cwd,
                status: status, statusSince: since,
                lastActivityAt: ms(desk?["lastActivityAt"]) ?? ms(reg["updatedAt"]),
                model: desk?["model"] as? String, permissionMode: desk?["permissionMode"] as? String,
                summary: (summaryObj?["status_detail"] as? String) ?? wrapUp,
                needsAction: needsAction, prompt: prompt, permission: permission,
                isDesktop: hostId != nil))
        }
        statusSince = statusSince.filter { seen.contains($0.key) }
        return out
    }

    /// CLI session id -> pid, for interrupt.
    func pid(forSessionId id: String) -> Int32? {
        for (_, reg) in registryCache {
            let r = reg.value
            if (r["hostSessionId"] as? String) == id || (r["sessionId"] as? String) == id {
                return (r["pid"] as? NSNumber)?.int32Value
            }
        }
        return nil
    }

    /// The folder a new session for this session's project should start in: the repo, not a worktree of it.
    func projectRoot(forSessionId id: String) -> String? {
        for (_, reg) in registryCache {
            let r = reg.value
            guard (r["hostSessionId"] as? String) == id || (r["sessionId"] as? String) == id,
                  var path = r["cwd"] as? String, !path.isEmpty else { continue }
            if let w = path.range(of: "/.claude/worktrees/") { path = String(path[..<w.lowerBound]) }
            return path
        }
        return nil
    }

    func hostSessionId(forCli cliId: String) -> String? {
        for (_, reg) in registryCache where (reg.value["sessionId"] as? String) == cliId {
            return reg.value["hostSessionId"] as? String
        }
        return nil
    }

    // MARK: recent projects

    private var transcriptCwds: [String: String] = [:]  // transcript dir -> the cwd its sessions ran in
    private var recent: [RecentProject] = []
    private var recentScannedAt = Date.distantPast

    /// Folders with a Claude Code transcript written in the last `days`, most recent first, plus the folders of
    /// live sessions. Transcripts cover CLI and desktop sessions alike, archived ones included. Rescanned once a minute.
    func recentProjects(live: [SessionInfo], days: Double = 7, limit: Int = 25) -> [RecentProject] {
        if Date().timeIntervalSince(recentScannedAt) > 60 {
            recentScannedAt = Date()
            recent = scanRecentProjects(since: Date().addingTimeInterval(-days * 86_400))
        }
        var byPath = Dictionary(uniqueKeysWithValues: recent.map { ($0.path, $0) })
        for s in live where !s.cwd.isEmpty {
            let root = Self.repoRoot(s.cwd)
            let at = s.lastActivityAt ?? s.statusSince
            if let p = byPath[root], p.lastUsedAt >= at { continue }
            byPath[root] = RecentProject(path: root, name: projectName(forCwd: root), lastUsedAt: at)
        }
        return Array(byPath.values.sorted { $0.lastUsedAt > $1.lastUsedAt }.prefix(limit))
    }

    /// Whether the phone may start a session in `folder`: only folders the board offers, never an arbitrary path.
    func isRecentProject(_ folder: String) -> Bool {
        recent.contains { $0.path == folder } || registryCache.values.contains {
            ($0.value["cwd"] as? String).map(Self.repoRoot) == folder
        }
    }

    private func scanRecentProjects(since cutoff: Date) -> [RecentProject] {
        let fm = FileManager.default
        let root = home.appendingPathComponent(".claude/projects")
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        // Tool and scratch folders, not projects you'd start work in.
        let skip = [home.appendingPathComponent("Library").path + "/", "/private/", "/tmp/", "/var/folders/"]
        var newest: [String: Date] = [:]
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys)) ?? [] {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
            // Restarting Claude appends bookkeeping lines to old transcripts, so the mtime only narrows the
            // search; the last timestamped entry says when the session was really used.
            var used: Date?
            var sample: URL?
            for f in files where f.pathExtension == "jsonl" {
                guard let mtime = try? f.resourceValues(forKeys: Set(keys)).contentModificationDate, mtime >= cutoff,
                      let at = lastEntryDate(f, mtime: mtime), at >= cutoff, at > used ?? .distantPast else { continue }
                used = at
                sample = f
            }
            guard let used, let sample else { continue }
            if transcriptCwds[dir.path] == nil, let cwd = Self.cwd(inTranscript: sample) { transcriptCwds[dir.path] = cwd }
            guard let cwd = transcriptCwds[dir.path] else { continue }
            let path = Self.repoRoot(cwd)
            if skip.contains(where: { (path + "/").hasPrefix($0) }) { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
            if used > newest[path] ?? .distantPast { newest[path] = used }
        }
        return newest.map { RecentProject(path: $0.key, name: projectName(forCwd: $0.key), lastUsedAt: $0.value) }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    private var lastEntryCache: [String: Cached<Date?>] = [:]
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// When Claude last replied in a transcript, from its tail. Only assistant entries count: a restart writes
    /// timestamped attachments and cancelled tool results into sessions nobody touched.
    private func lastEntryDate(_ file: URL, mtime: Date) -> Date? {
        if let hit = lastEntryCache[file.path], hit.mtime == mtime { return hit.value }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        var at: Date?
        for line in data.split(separator: 0x0A).reversed() {
            if let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
               obj["type"] as? String == "assistant", let ts = obj["timestamp"] as? String, let d = Self.isoFormatter.date(from: ts) {
                at = d
                break
            }
        }
        lastEntryCache[file.path] = Cached(mtime: mtime, value: at)
        return at
    }

    /// The `cwd` recorded in the first lines of a transcript.
    private static func cwd(inTranscript file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 65_536)) ?? Data()
        for line in data.split(separator: 0x0A) {
            if let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
               let cwd = obj["cwd"] as? String, !cwd.isEmpty { return cwd }
        }
        return nil
    }

    /// A worktree's repo, else the folder itself.
    static func repoRoot(_ cwd: String) -> String {
        guard let w = cwd.range(of: "/.claude/worktrees/") else { return cwd }
        return String(cwd[..<w.lowerBound])
    }

    /// The repo a session belongs to: worktree sessions group with their repo, the home dir shows as `~`.
    private func projectName(forCwd cwd: String) -> String {
        var path = cwd
        if let r = path.range(of: "/.claude/worktrees/") { path = String(path[..<r.lowerBound]) }
        if path.isEmpty || path == home.path { return "~" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    // MARK: files

    struct PendingTool { var id: String; var name: String; var input: [String: Any] }
    struct TranscriptTail { var lastText: String?; var pendingTools: [PendingTool] }
    private var tailCache: [String: Cached<TranscriptTail>] = [:]

    /// From the tail of the session's transcript: the last text Claude wrote, and the tool calls still
    /// waiting on a result (what a permission prompt or question is holding up).
    private func transcriptTail(cliSessionId: String, cwd: String) -> TranscriptTail? {
        let slug = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let path = home.appendingPathComponent(".claude/projects/\(slug)/\(cliSessionId).jsonl").path
        guard let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
        if let hit = tailCache[path], hit.mtime == mtime { return hit.value }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        var tail = TranscriptTail(lastText: nil, pendingTools: [])
        for line in data.split(separator: 0x0A) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  obj["isSidechain"] as? Bool != true,
                  let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            switch obj["type"] as? String {
            case "assistant":
                let joined = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                    .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty { tail.lastText = String(joined.suffix(6000)) }
                for block in content where block["type"] as? String == "tool_use" {
                    guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                    tail.pendingTools.append(PendingTool(id: id, name: name, input: block["input"] as? [String: Any] ?? [:]))
                }
            case "user":
                let answered = Set(content.compactMap { $0["type"] as? String == "tool_result" ? $0["tool_use_id"] as? String : nil })
                if !answered.isEmpty { tail.pendingTools.removeAll { answered.contains($0.id) } }
            default:
                break
            }
        }
        tailCache[path] = Cached(mtime: mtime, value: tail)
        return tail
    }

    private func readRegistry() -> [(String, [String: Any])] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: registryDir.path) else { return [] }
        var live = Set<String>()
        var out: [(String, [String: Any])] = []
        for name in names where name.hasSuffix(".json") {
            let path = registryDir.appendingPathComponent(name).path
            live.insert(path)
            if let obj = readCached(path, cache: &registryCache) { out.append((path, obj)) }
        }
        registryCache = registryCache.filter { live.contains($0.key) }
        return out
    }

    private func desktopMeta(for hostId: String) -> [String: Any]? {
        for dir in desktopDirs {
            let path = dir.appendingPathComponent("\(hostId).json").path
            if let obj = readCached(path, cache: &desktopCache) { return obj }
        }
        return nil
    }

    /// `claude-code-sessions/<account>/<org>/` — rescanned once a minute in case you switch orgs.
    private func refreshDesktopDirs() {
        guard Date().timeIntervalSince(desktopDirsScannedAt) > 60 else { return }
        desktopDirsScannedAt = Date()
        let fm = FileManager.default
        var dirs: [URL] = []
        for acct in (try? fm.contentsOfDirectory(at: desktopRoot, includingPropertiesForKeys: nil)) ?? [] {
            for org in (try? fm.contentsOfDirectory(at: acct, includingPropertiesForKeys: nil)) ?? [] {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: org.path, isDirectory: &isDir), isDir.boolValue { dirs.append(org) }
            }
        }
        desktopDirs = dirs
    }

    private func readCached(_ path: String, cache: inout [String: Cached<[String: Any]>]) -> [String: Any]? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        if let hit = cache[path], hit.mtime == mtime { return hit.value }
        guard let data = FileManager.default.contents(atPath: path),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            // Mid-write: keep serving the previous parse.
            return cache[path]?.value
        }
        cache[path] = Cached(mtime: mtime, value: obj)
        return obj
    }
}

func processAlive(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}

func ms(_ any: Any?) -> Date? {
    if let n = any as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue / 1000) }
    if let s = any as? String, let d = Double(s) { return Date(timeIntervalSince1970: d / 1000) }
    return nil
}

func parseJSONString(_ any: Any?) -> [String: Any]? {
    if let d = any as? [String: Any] { return d }
    guard let s = any as? String, let data = s.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}
