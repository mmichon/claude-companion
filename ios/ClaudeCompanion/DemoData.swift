#if DEBUG
import Foundation
import CompanionShared

/// Made-up sessions for `-demo YES` launches: screenshots and UI work without a Mac.
enum DemoData {
    static func snapshot(now: Date = Date()) -> Snapshot {
        func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }
        func session(_ n: Int, _ title: String, _ project: String, _ status: SessionStatus, since: TimeInterval,
                     summary: String? = nil, prompt: PendingPrompt? = nil, permission: PermissionInfo? = nil) -> SessionInfo {
            SessionInfo(id: "local_demo\(n)", cliSessionId: "demo\(n)", pid: Int32(1000 + n), title: title, project: project,
                        cwd: "/Users/demo/src/\(project)", status: status, statusSince: ago(since), lastActivityAt: ago(since),
                        model: "claude-opus-5-5", permissionMode: "default", summary: summary, needsAction: nil,
                        prompt: prompt, permission: permission, isDesktop: true)
        }
        let sessions = [
            session(1, "Add rate limiting to the API", "storefront", .permission, since: 40,
                    permission: PermissionInfo(requestId: "demo-perm", toolName: "Bash", summary: "npm test -- --runInBand",
                                               detail: "Run the test suite", decidableFromPhone: true, createdAt: ago(40))),
            session(2, "Migrate settings to SwiftData", "weather-app", .waiting, since: 190,
                    summary: "Two migration paths are possible; which one should I take?",
                    prompt: PendingPrompt(kind: .question, text: "Keep the old UserDefaults keys as a fallback?",
                                          options: ["Yes, for one release", "No, migrate once"],
                                          questions: [.init(question: "Keep the old UserDefaults keys as a fallback?",
                                                            header: "Migration", options: ["Yes, for one release", "No, migrate once"])],
                                          requestId: "demo-question")),
            session(3, "Fix flaky checkout test", "storefront", .busy, since: 75),
            session(4, "Write release notes for 2.4", "docs-site", .busy, since: 320),
            session(5, "Dark mode for the dashboard", "admin-panel", .done, since: 540,
                    summary: "Dark mode is in, with tokens for every surface. Screenshots attached to the PR."),
            session(6, "Bump dependencies", "cli-tools", .waiting, since: 95,
                    prompt: PendingPrompt(kind: .message, text: "Lodash 5 drops two helpers we use. Should I replace them now or pin 4.x?")),
            session(7, "Investigate memory leak", "image-pipeline", .idle, since: 14400),
        ]
        let projects = ["storefront", "weather-app", "docs-site", "admin-panel"].enumerated().map { i, name in
            RecentProject(path: "/Users/demo/src/\(name)", name: name, lastUsedAt: ago(Double(i) * 600))
        }
        let usage = UsageInfo(fiveHourPct: 42, sevenDayPct: 18, fiveHourResetsAt: now.addingTimeInterval(2 * 3600 + 900),
                              sevenDayResetsAt: now.addingTimeInterval(4 * 86400), planSampledAt: now,
                              todayInputTokens: 1_840_000, todayOutputTokens: 212_000, todayCacheReadTokens: 9_600_000,
                              todayMessages: 318)
        return Snapshot(sessions: sessions, projects: projects, usage: usage, macName: "Studio",
                        macIdleSeconds: 300, awayThreshold: 60, generatedAt: now)
    }
}
#endif
