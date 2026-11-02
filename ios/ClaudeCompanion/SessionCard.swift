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
                .foregroundStyle(.primary)
                .lineLimit(2)
            HStack(spacing: 6) {
                if showProject {
                    Image(systemName: "folder.fill").font(.caption2)
                    Text(session.project)
                }
                Text(metaLine)
            }
            .font(.caption2)
            .foregroundStyle(Color.ink(0.5))
            .lineLimit(1)

            if let preview {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(session.status.needsYou ? Color.primary : Color.ink(0.7))
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

/// Runs as a Core Animation layer animation on the render server, so SwiftUI
/// re-renders, ancestor transactions, LazyVGrid reuse, sheets and backgrounding
/// can't stall it (TimelineView(.animation) still froze occasionally).
struct BusyBar: View {
    let color: Color

    var body: some View {
        BusyBarRepresentable(color: UIColor(color)).frame(height: 4)
    }
}

private struct BusyBarRepresentable: UIViewRepresentable {
    let color: UIColor
    func makeUIView(context: Context) -> BusyBarView { BusyBarView() }
    func updateUIView(_ view: BusyBarView, context: Context) { view.color = color }
}

final class BusyBarView: UIView {
    private static let period: CFTimeInterval = 1.4
    private let track = CALayer()
    private let thumb = CALayer()
    private var animatedWidth: CGFloat = 0

    var color: UIColor = .white {
        didSet {
            guard color != oldValue else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            track.backgroundColor = color.withAlphaComponent(0.18).cgColor
            thumb.backgroundColor = color.cgColor
            CATransaction.commit()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        track.masksToBounds = true
        thumb.anchorPoint = .zero
        layer.addSublayer(track)
        track.addSublayer(thumb)
        NotificationCenter.default.addObserver(self, selector: #selector(resume),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.frame = bounds
        track.cornerRadius = bounds.height / 2
        thumb.bounds = CGRect(x: 0, y: 0, width: bounds.width * 0.35, height: bounds.height)
        thumb.cornerRadius = bounds.height / 2
        thumb.position = .zero
        CATransaction.commit()
        startIfNeeded(force: bounds.width != animatedWidth)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        startIfNeeded(force: false)
    }

    @objc private func resume() { startIfNeeded(force: true) }

    private func startIfNeeded(force: Bool) {
        guard window != nil, bounds.width > 0 else { return }
        if !force, thumb.animation(forKey: "slide") != nil { return }
        let w = bounds.width
        let a = CABasicAnimation(keyPath: "position.x")
        a.fromValue = -0.4 * w
        a.toValue = 1.05 * w
        a.duration = Self.period
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        // Phase-locked to the wall clock so restarts don't jump and all bars sweep together.
        a.beginTime = thumb.convertTime(CACurrentMediaTime(), from: nil)
            - Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period)
        thumb.add(a, forKey: "slide")
        animatedWidth = w
    }
}
