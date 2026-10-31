import SwiftUI
import CompanionShared

extension SessionStatus {
    var color: Color {
        switch self {
        case .permission: return Color(red: 1.0, green: 0.22, blue: 0.78)   // magenta
        case .waiting: return Color(red: 1.0, green: 0.58, blue: 0.0)       // orange
        case .error: return Color(red: 1.0, green: 0.23, blue: 0.19)        // red
        case .busy: return Color(red: 0.2, green: 0.6, blue: 1.0)           // blue
        case .done: return Color(red: 0.19, green: 0.86, blue: 0.42)        // green
        case .idle: return Color(white: 0.42)
        }
    }

    var symbol: String {
        switch self {
        case .permission: return "lock.shield.fill"
        case .waiting: return "hand.raised.fill"
        case .error: return "exclamationmark.octagon.fill"
        case .busy: return "sparkles"
        case .done: return "checkmark.circle.fill"
        case .idle: return "moon.zzz.fill"
        }
    }
}

extension SessionInfo {
    /// Waiting turns red after 5 minutes.
    func displayColor(now: Date) -> Color {
        if status == .waiting, now.timeIntervalSince(statusSince) > 300 { return SessionStatus.error.color }
        return status.color
    }
}

func elapsed(_ since: Date, now: Date) -> String {
    let s = max(0, Int(now.timeIntervalSince(since)))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return String(format: "%d:%02d", s / 60, s % 60) }
    if s < 86_400 { return "\(s / 3600)h \((s % 3600) / 60)m" }
    return "\(s / 86_400)d"
}

func compactTokens(_ n: Int) -> String {
    switch n {
    case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
    case 1_000...: return String(format: "%.0fk", Double(n) / 1_000)
    default: return "\(n)"
    }
}
