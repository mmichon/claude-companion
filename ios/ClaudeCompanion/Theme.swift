import SwiftUI
import CompanionShared

extension SessionStatus {
    var color: Color {
        switch self {
        // Light variants are a touch deeper so timers and borders hold contrast on white.
        case .permission: return .adaptive(dark: (1.0, 0.22, 0.78), light: (0.9, 0.1, 0.66))     // magenta
        case .waiting: return .adaptive(dark: (1.0, 0.58, 0.0), light: (0.95, 0.5, 0.0))         // orange
        case .error: return .adaptive(dark: (1.0, 0.23, 0.19), light: (0.92, 0.16, 0.13))        // red
        case .busy: return .adaptive(dark: (0.2, 0.6, 1.0), light: (0.1, 0.5, 0.95))             // blue
        case .done: return .adaptive(dark: (0.19, 0.86, 0.42), light: (0.1, 0.7, 0.32))          // green
        case .idle: return .adaptive(dark: (0.42, 0.42, 0.42), light: (0.6, 0.6, 0.6))
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

enum Appearance: String, CaseIterable {
    case system, light, dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var label: String { rawValue.capitalized }
}

extension Color {
    /// A gray given by its dark-mode white level; light mode mirrors it (0 = page background, 1 = strongest ink).
    static func ink(_ white: Double) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .light ? UIColor(white: 1 - white, alpha: 1) : UIColor(white: white, alpha: 1) })
    }

    static func adaptive(dark: (Double, Double, Double), light: (Double, Double, Double)) -> Color {
        Color(UIColor { t in
            let c = t.userInterfaceStyle == .light ? light : dark
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
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
