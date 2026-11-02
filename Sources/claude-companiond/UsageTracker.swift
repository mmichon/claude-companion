import Foundation
import CompanionShared

/// Today's token totals from Claude Code transcripts, read incrementally, plus plan usage
/// (percentages and reset times) from the usage API, falling back to the desktop app's last sample.
final class UsageTracker {
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var offsets: [String: UInt64] = [:]
    private var seenMessageIds = Set<String>()
    private var day = ""
    private(set) var usage = UsageInfo()
    private var lastFetch = Date.distantPast
    private var fetchBackoff: TimeInterval = 60
    private var fetching = false
    private var apiSampledAt: Date?

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func refresh() {
        let today = Self.dayFormatter.string(from: Date())
        if today != day {
            day = today
            offsets = [:]
            seenMessageIds = []
            // Plan windows don't follow the calendar day; only the token totals start over.
            usage.todayMessages = 0
            usage.todayInputTokens = 0
            usage.todayOutputTokens = 0
            usage.todayCacheReadTokens = 0
        }
        scanTranscripts()
        fetchPlanUsage()
        // The API answer wins while it's recent; the desktop file has no reset times.
        if apiSampledAt.map({ Date().timeIntervalSince($0) > 10 * 60 }) ?? true { readPlanUsage() }
    }

    /// Same endpoint `/usage` reads, with Claude Code's own OAuth token. Runs on the daemon queue.
    private func fetchPlanUsage() {
        guard !fetching, Date().timeIntervalSince(lastFetch) > fetchBackoff, let token = oauthToken() else { return }
        fetching = true
        lastFetch = Date()
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            Daemon.queue.async {
                guard let self else { return }
                self.fetching = false
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200, let data,
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    self.fetchBackoff = min(self.fetchBackoff * 2, 15 * 60)
                    return
                }
                self.fetchBackoff = 60
                func window(_ key: String) -> (Double?, Date?) {
                    let w = obj[key] as? [String: Any]
                    return ((w?["utilization"] as? NSNumber)?.doubleValue, (w?["resets_at"] as? String).flatMap(Self.parseISO))
                }
                (self.usage.fiveHourPct, self.usage.fiveHourResetsAt) = window("five_hour")
                // No open 5-hour window means none of it is used yet.
                if self.usage.fiveHourPct == nil { self.usage.fiveHourPct = 0 }
                (self.usage.sevenDayPct, self.usage.sevenDayResetsAt) = window("seven_day")
                self.usage.planSampledAt = Date()
                self.apiSampledAt = Date()
            }
        }.resume()
    }

    /// Claude Code keeps its login in the keychain; older installs use `~/.claude/.credentials.json`.
    private func oauthToken() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        var data: Data?
        if (try? p.run()) != nil {
            data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus != 0 { data = nil }
        }
        if data == nil { data = try? Data(contentsOf: home.appendingPathComponent(".claude/.credentials.json")) }
        guard let data, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }
        // Claude Code refreshes an expired token itself; asking with it would only fail.
        if let exp = ms(oauth["expiresAt"]), exp < Date() { return nil }
        return token
    }

    private static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    private func scanTranscripts() {
        let projects = home.appendingPathComponent(".claude/projects")
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: projects, includingPropertiesForKeys: [.contentModificationDateKey],
                                             options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  mtime >= startOfDay else { continue }
            readNewLines(url, since: startOfDay)
        }
    }

    private func readNewLines(_ url: URL, since startOfDay: Date) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let start = offsets[url.path] ?? 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd(), !data.isEmpty else { return }
        // Only consume whole lines; a partial last line is re-read next time.
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return }
        offsets[url.path] = start + UInt64(lastNewline + 1)
        let chunk = data[data.startIndex...lastNewline]
        for line in chunk.split(separator: 0x0A) {
            // Cheap filter before parsing: transcripts are mostly tool output.
            guard line.count < 2_000_000, let s = String(data: line, encoding: .utf8), s.contains("\"usage\"") else { continue }
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let u = msg["usage"] as? [String: Any] else { continue }
            if let ts = obj["timestamp"] as? String, let d = Self.isoFormatter.date(from: ts), d < startOfDay { continue }
            // One API message is split over several transcript lines that repeat the same usage.
            let msgId = msg["id"] as? String ?? UUID().uuidString
            guard seenMessageIds.insert(msgId).inserted else { continue }
            usage.todayMessages += 1
            usage.todayInputTokens += (u["input_tokens"] as? Int ?? 0) + (u["cache_creation_input_tokens"] as? Int ?? 0)
            usage.todayCacheReadTokens += u["cache_read_input_tokens"] as? Int ?? 0
            usage.todayOutputTokens += u["output_tokens"] as? Int ?? 0
        }
    }

    /// `plan-usage-history.json` samples: `u.fh` = 5-hour %, `u.sd` = 7-day %.
    private func readPlanUsage() {
        let url = home.appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let samples = obj["samples"] as? [[String: Any]],
              let last = samples.last, let at = ms(last["t"]),
              let u = last["u"] as? [String: Any] else { return }
        // Idle long enough for Claude Code's token to lapse: keep the last API answer, whose reset
        // times already tell the phone when each window refilled.
        if apiSampledAt != nil, Date().timeIntervalSince(at) >= 10 * 60 { return }
        // A sample older than 6 hours predates the current 5-hour window, so that window is untouched.
        guard Date().timeIntervalSince(at) < 6 * 3600 else {
            usage.fiveHourPct = 0
            usage.fiveHourResetsAt = nil
            usage.sevenDayPct = Date().timeIntervalSince(at) < 7 * 86_400 ? (u["sd"] as? NSNumber)?.doubleValue : nil
            usage.planSampledAt = at
            return
        }
        usage.fiveHourPct = (u["fh"] as? NSNumber)?.doubleValue
        usage.sevenDayPct = (u["sd"] as? NSNumber)?.doubleValue
        usage.planSampledAt = at
    }
}
