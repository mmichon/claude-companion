import AppKit
import CompanionShared

let args = CommandLine.arguments

if args.contains("--dump") {
    let daemon = Daemon()
    let snap = Daemon.queue.sync { daemon.buildSnapshot() }
    let enc = WireMessage.encoder
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try! enc.encode(snap))
    print()
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let daemon = Daemon()
let statusBar = StatusBar()
daemon.statusBar = statusBar
statusBar.onRevokeAll = { [weak daemon] in
    Daemon.queue.async {
        daemon?.tokens.revokeAll()
        daemon?.phone.clients.values.forEach { $0.conn.cancel() }
    }
}
do {
    try Daemon.queue.sync { try daemon.start() }
} catch {
    logLine("failed to start: \(error)")
    exit(1)
}
app.run()
