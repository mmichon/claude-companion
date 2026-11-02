import AppKit

// claude-companion-keys: the one process that needs Accessibility. It types into Claude for claude-companiond
// (a phone reply, or Esc) and runs as its own LaunchAgent, so macOS holds the grant for it rather than for the
// daemon. Keep it small and free of shared code: TCC pins an ad-hoc grant to the binary's cdhash, and the
// installer only replaces this binary when it changes.
//
// Protocol, over a Unix socket only this user can open: one JSON request, then the write side is shut;
// the answer is "ok" or "error: <why>".
//   {"op": "reply", "text": "…"}   paste text into Claude's message box and press Return
//   {"op": "esc"}                  press Esc in Claude

let socketPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/ClaudeCompanion/keys.sock").path
let claudeBundleId = "com.anthropic.claudefordesktop"

func log(_ s: String) {
    FileHandle.standardError.write("\(ISO8601DateFormatter().string(from: Date())) keys: \(s)\n".data(using: .utf8)!)
}

/// With `prompt`, an untrusted helper shows the macOS popup and lists itself under Privacy → Accessibility.
@discardableResult
func trusted(prompt: Bool) -> Bool {
    AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary)
}

/// Down, a short hold, then up, like a real key press: a back-to-back pair can be dropped by Claude's message box.
func press(_ key: CGKeyCode, flags: CGEventFlags = []) {
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
        e?.flags = flags
        e?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.03)
    }
}

func claudeFrontmost() -> Bool {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier == claudeBundleId
}

/// Pastes `text` and presses Return, then puts the clipboard back.
func reply(_ text: String) {
    let pb = NSPasteboard.general
    let saved = (pb.pasteboardItems ?? []).map { item -> NSPasteboardItem in
        let copy = NSPasteboardItem()
        for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
        return copy
    }
    pb.clearContents()
    pb.setString(text, forType: .string)
    defer {
        pb.clearContents()
        if !saved.isEmpty { pb.writeObjects(saved) }
    }
    press(9, flags: .maskCommand)  // V
    // Let the message box take the paste before Return, or Return lands first and the text sits there unsent.
    Thread.sleep(forTimeInterval: 0.6)
    press(36)  // Return
    Thread.sleep(forTimeInterval: 0.3)
}

func handle(_ data: Data) -> String {
    guard let req = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let op = req["op"] as? String else {
        return "error: bad request"
    }
    guard trusted(prompt: false) else {
        DispatchQueue.main.async { trusted(prompt: true) }
        return "error: not allowed under Privacy → Accessibility"
    }
    // The pasteboard and frontmost-app checks belong on the main thread.
    return DispatchQueue.main.sync {
        guard claudeFrontmost() else { return "error: Claude is not frontmost" }
        switch op {
        case "reply":
            guard let text = req["text"] as? String, !text.isEmpty else { return "error: no text" }
            reply(text)
        case "esc":
            press(53)
        default:
            return "error: unknown op \(op)"
        }
        return "ok"
    }
}

func serve() {
    unlink(socketPath)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        _ = socketPath.utf8CString.withUnsafeBytes { buf.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buf.count - 1))) }
    }
    let old = umask(0o077)
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    umask(old)
    guard fd >= 0, bound == 0, listen(fd, 4) == 0 else {
        log("can't listen on \(socketPath): \(String(cString: strerror(errno)))")
        exit(1)
    }
    log("listening")
    while true {
        let c = accept(fd, nil, nil)
        guard c >= 0 else { continue }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while data.count < 65_536 {
            let n = read(c, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        let answer = handle(data)
        if answer != "ok" { log(answer) }
        _ = answer.utf8CString.withUnsafeBytes { write(c, $0.baseAddress, $0.count - 1) }
        close(c)
    }
}

if !trusted(prompt: true) { log("not trusted for Accessibility; asked macOS to prompt") }
Thread.detachNewThread(serve)
NSApplication.shared.setActivationPolicy(.prohibited)
NSApplication.shared.run()
