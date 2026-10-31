import AppKit

enum Actions {
    /// Switches the Claude desktop app to the session.
    static func openSession(_ id: String) {
        var c = URLComponents()
        c.scheme = "claude"
        c.host = "code"
        c.path = "/continue"
        c.queryItems = [URLQueryItem(name: "session", value: id), URLQueryItem(name: "source", value: "companion")]
        guard let url = c.url else { return }
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
    }

    /// Starts a blank Code session in `folder` (the deep link behind Finder's "New Claude Code Session Here").
    static func newSession(folder: String) {
        var c = URLComponents()
        c.scheme = "claude"
        c.host = "code"
        c.path = "/new"
        c.queryItems = [URLQueryItem(name: "folder", value: folder), URLQueryItem(name: "source", value: "companion")]
        guard let url = c.url else { return }
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
    }

    /// Brings the session forward and presses Esc in Claude, which stops the running turn.
    /// Not SIGINT: in the stream-json mode desktop sessions use, SIGINT kills the CLI outright.
    /// Needs Accessibility permission for claude-companiond (System Events keystrokes); returns false without it.
    static func interrupt(sessionId: String) -> Bool {
        openSession(sessionId)
        Thread.sleep(forTimeInterval: 0.8)
        let script = """
        tell application "System Events"
            if frontmost of process "Claude" then key code 53
        end tell
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let err = Pipe()
        p.standardError = err
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            logLine("interrupt failed: \(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))")
        }
        return p.terminationStatus == 0
    }
}
