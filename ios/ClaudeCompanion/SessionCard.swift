import SwiftUI
import CompanionShared

struct SessionCard: View {
    let session: SessionInfo
    let now: Date
    let pinned: Bool
    let muted: Bool
    var showProject = true

    var body: some View {
        let color = session.displayColor(now: now)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Label(session.status.label, systemImage: session.status.symbol)
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(color))
                if pinned { Image(systemName: "pin.fill").foregroundStyle(.yellow).font(.caption) }
                if muted { Image(systemName: "speaker.slash.fill").foregroundStyle(.gray).font(.caption) }
                Spacer()
                Text(timerText)
                    .font(.system(.headline, design: .rounded).weight(.bold).monospacedDigit())
                    .foregroundStyle(color)
            }
            Text(session.title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)
            HStack(spacing: 6) {
                if showProject {
                    Image(systemName: "folder.fill").font(.caption2)
                    Text(session.project)
                }
                Text(metaLine)
            }
            .font(.caption2)
            .foregroundStyle(Color(white: 0.5))
            .lineLimit(1)

            if let preview {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(session.status.needsYou ? Color.white : Color(white: 0.7))
                    .lineLimit(session.status.needsYou ? 6 : 4)
            }
            if session.status == .busy { BusyBar(color: color) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(color.opacity(session.status == .idle ? 0.06 : 0.13))
        )
        .overlay(border(color))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }

    /// Model and non-default permission mode, joined after the project when it shows.
    private var metaLine: String {
        var parts: [String] = []
        if let model = session.model { parts.append(model.replacingOccurrences(of: "claude-", with: "")) }
        if let mode = session.permissionMode, mode != "default" { parts.append(mode) }
        return (showProject && !parts.isEmpty ? "· " : "") + parts.joined(separator: " · ")
    }

    private var timerText: String {
        let since = session.status == .idle ? (session.lastActivityAt ?? session.statusSince) : session.statusSince
        return elapsed(since, now: now)
    }

    private var preview: String? {
        if let p = session.permission { return "\(p.toolName): \(p.summary)" }
        if let prompt = session.prompt { return prompt.text.replacingOccurrences(of: "**", with: "") }
        return session.summary
    }

    @ViewBuilder
    private func border(_ color: Color) -> some View {
        if session.status == .permission {
            PulsingBorder(color: color)
        } else {
            RoundedRectangle(cornerRadius: 16).strokeBorder(color.opacity(session.status.needsYou ? 1 : 0.5), lineWidth: session.status.needsYou ? 3 : 1.5)
        }
    }
}

struct PulsingBorder: View {
    let color: Color
    @State private var on = false

    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .strokeBorder(color, lineWidth: on ? 5 : 2)
            .opacity(on ? 1 : 0.45)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

/// Driven by the clock rather than a repeatForever state animation, so ancestor
/// `.animation(_:value:)` transactions and LazyVGrid reuse can't stall it.
struct BusyBar: View {
    let color: Color

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
            let phase = -0.4 + 1.45 * t
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.18))
                    Capsule().fill(color).frame(width: geo.size.width * 0.35)
                        .offset(x: geo.size.width * phase)
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: 4)
    }
}
