import SwiftUI
import CompanionShared

struct BoardView: View {
    @EnvironmentObject var client: CompanionClient
    @EnvironmentObject var prefs: Prefs
    @State private var selected: SessionInfo?
    @State private var showSettings = false
    @Environment(\.isUpsideDown) private var isUpsideDown

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let now = ctx.date
            let sessions = client.snapshot?.sessions ?? []
            let (active, idle) = partition(sessions)
            GeometryReader { geo in
            let layout = HousingLayout(size: geo.size, insets: geo.safeAreaInsets, upsideDown: isUpsideDown)
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    HeaderView(sessions: sessions, now: now, showSettings: $showSettings, showsTopRow: layout == .inline)
                    ScrollView {
                        if prefs.groupByProject {
                            ForEach(groups(active), id: \.project) { g in
                                ProjectHeader(project: g.project, sessions: g.sessions)
                                    .padding(.horizontal, 14)
                                    .padding(.top, 10)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        guard let s = g.sessions.first else { return }
                                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                        client.newSession(like: s)
                                    }
                                cardGrid(g.sessions, now: now)
                            }
                        } else {
                            cardGrid(active, now: now)
                                .padding(.top, 8)
                        }

                        if active.isEmpty {
                            Text("Nothing active").font(.title3).foregroundStyle(.gray).padding(.top, 40)
                        }

                        if let projects = client.snapshot?.projects, !projects.isEmpty {
                            ProjectsSection(projects: projects, now: now, expanded: $prefs.projectsExpanded) { p in
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                client.newSession(in: p)
                            }
                        }

                        if !idle.isEmpty {
                            IdleSection(sessions: idle, now: now, expanded: $prefs.idleExpanded,
                                        grouped: prefs.groupByProject,
                                        onTap: { client.open($0) }, menu: { menu(for: $0) })
                        }
                    }
                }
                if let toast = client.toast {
                    Text(toast)
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Capsule().fill(Color.ink(0.18)))
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                HousingStats(layout: layout, size: geo.size, insets: geo.safeAreaInsets,
                             sessions: sessions, showSettings: $showSettings)
                if prefs.isNight(now) {
                    // Dim, not black: still readable from the desk, passes taps through.
                    Color.black.opacity(0.65).ignoresSafeArea().allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.25), value: client.toast)
            .animation(.default, value: (prefs.groupByProject ? groups(active).flatMap(\.sessions) : active).map(\.id))
            }
        }
        .sheet(item: $selected) { s in
            SessionDetailSheet(sessionId: s.id).flipWhenUpsideDown()
        }
        .sheet(isPresented: $showSettings) { SettingsView().flipWhenUpsideDown() }
        .onChange(of: prefs.dndState) { _, d in client.setDND(d) }
        .onChange(of: client.phase) { _, p in if p == .connected { client.setDND(prefs.dndState) } }
        .onChange(of: client.snapshot) { _, snap in if let snap { prefs.pruneDismissed(snap.sessions) } }
    }

    private func cardGrid(_ sessions: [SessionInfo], now: Date) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 8)], spacing: 8) {
            ForEach(sessions) { s in
                SessionCard(session: s, now: now, pinned: prefs.pinned.contains(s.id), muted: prefs.muted.contains(s.id),
                            showProject: !prefs.groupByProject)
                    .onTapGesture { if s.answerableFromPhone { selected = s } else { client.open(s) } }
                    .contextMenu { menu(for: s) }
                    .swipeToDismiss(enabled: !prefs.pinned.contains(s.id)) { dismiss(s) }
            }
        }
        .padding(.horizontal, 12)
    }

    private func dismiss(_ s: SessionInfo) {
        withAnimation { prefs.dismiss(s) }
        client.showToast("Dismissed")
    }

    /// Needs-you first (oldest wait first), then pinned, working, unread, errors; idle goes in its own section.
    private func partition(_ sessions: [SessionInfo]) -> ([SessionInfo], [SessionInfo]) {
        func rank(_ s: SessionInfo) -> Int {
            if s.status.needsYou { return 0 }
            if prefs.pinned.contains(s.id) { return 1 }
            switch s.status {
            case .busy: return 2
            case .done: return 3
            case .error: return 4
            default: return 5
            }
        }
        func isActive(_ s: SessionInfo) -> Bool {
            prefs.pinned.contains(s.id) || (s.status != .idle && !prefs.isDismissed(s))
        }
        let active = sessions.filter(isActive)
            .sorted { a, b in
                let ra = rank(a), rb = rank(b)
                if ra != rb { return ra < rb }
                if ra == 0 { return a.statusSince < b.statusSince }
                return (a.lastActivityAt ?? .distantPast) > (b.lastActivityAt ?? .distantPast)
            }
        let idle = sessions.filter { !isActive($0) }
            .sorted { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }
        return (active, idle)
    }

    @ViewBuilder
    private func menu(for s: SessionInfo) -> some View {
        Button { client.open(s) } label: { Label("Open on Mac", systemImage: "macbook") }
        Button { selected = s } label: { Label("Details", systemImage: "text.alignleft") }
        if s.status == .busy || s.status == .permission {
            Button(role: .destructive) { client.interrupt(s) } label: { Label("Interrupt (Esc)", systemImage: "stop.circle") }
        }
        Button { prefs.togglePin(s.id) } label: {
            prefs.pinned.contains(s.id) ? Label("Unpin", systemImage: "pin.slash") : Label("Pin to top", systemImage: "pin")
        }
        Button { prefs.toggleMute(s.id) } label: {
            prefs.muted.contains(s.id) ? Label("Unmute", systemImage: "speaker.wave.2") : Label("Mute sounds", systemImage: "speaker.slash")
        }
        if s.status != .idle, !prefs.pinned.contains(s.id), !prefs.isDismissed(s) {
            Button { dismiss(s) } label: { Label("Dismiss", systemImage: "xmark.circle") }
        }
    }
}

/// Swipe a card left past the threshold to dismiss it; shorter swipes spring back.
/// Only horizontal-dominant drags count, so the board still scrolls vertically.
private struct SwipeToDismiss: ViewModifier {
    let enabled: Bool
    let onDismiss: () -> Void
    @State private var offset: CGFloat = 0
    @State private var width: CGFloat = 400

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .opacity(1 - min(0.6, Double(-offset / width)))
            .background(alignment: .trailing) {
                if offset < 0 {
                    Label("Dismiss", systemImage: "xmark")
                        .font(.headline).foregroundStyle(.red)
                        .padding(.trailing, 16)
                        .opacity(min(1, Double(-offset / 80)))
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .simultaneousGesture(enabled ? drag : nil)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { v in
                guard abs(v.translation.width) > abs(v.translation.height) else { return }
                offset = min(0, v.translation.width)
            }
            .onEnded { v in
                let horizontal = abs(v.translation.width) > abs(v.translation.height)
                if horizontal, v.translation.width < -110 || v.predictedEndTranslation.width < -200 {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.easeOut(duration: 0.2)) { offset = -width * 1.2 } completion: {
                        onDismiss()
                        offset = 0
                    }
                } else {
                    withAnimation(.spring(duration: 0.3)) { offset = 0 }
                }
            }
    }
}

extension View {
    func swipeToDismiss(enabled: Bool = true, onDismiss: @escaping () -> Void) -> some View {
        modifier(SwipeToDismiss(enabled: enabled, onDismiss: onDismiss))
    }
}

struct HeaderView: View {
    @EnvironmentObject var client: CompanionClient
    @EnvironmentObject var prefs: Prefs
    let sessions: [SessionInfo]
    let now: Date
    @Binding var showSettings: Bool
    /// Off when the chips and buttons sit beside the sensor housing instead.
    var showsTopRow = true

    var body: some View {
        VStack(spacing: 8) {
            if showsTopRow {
                HStack(spacing: 10) {
                    StatusChips(sessions: sessions, style: .full)
                    HeaderButtons(showSettings: $showSettings)
                }
            }
            if let usage = client.snapshot?.usage, usage.fiveHourPct != nil {
                PlanUsageHero(usage: usage, now: now)
            }
            HStack(spacing: 8) {
                Circle().fill(client.phase == .connected ? Color.green : Color.gray).frame(width: 8, height: 8)
                Text(client.macName ?? "Mac").font(.caption.weight(.semibold)).foregroundStyle(Color.ink(0.7)).lineLimit(1)
                Spacer(minLength: 0)
                if let usage = client.snapshot?.usage { TodayTokens(usage: usage) }
            }
            if client.phase != .connected {
                Text("Mac offline — reconnecting…")
                    .font(.caption.weight(.semibold)).foregroundStyle(.black)
                    .frame(maxWidth: .infinity).padding(.vertical, 4)
                    .background(Color.gray)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }
}

/// "All quiet" or the waiting / working / unread counts.
struct StatusChips: View {
    enum Style { case full, compact }
    @EnvironmentObject var client: CompanionClient
    @EnvironmentObject var prefs: Prefs
    let sessions: [SessionInfo]
    let style: Style
    var axis: Axis = .horizontal

    var body: some View {
        let layout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: style == .full ? 10 : 5))
                                         : AnyLayout(VStackLayout(spacing: 6))
        layout {
            if sessions.allSatisfy({ !$0.status.needsYou && $0.status != .busy && $0.status != .done }) {
                Text(style == .full ? "All quiet" : "Quiet").font(style == .full ? .headline : .caption.weight(.semibold))
                    .foregroundStyle(.gray).fixedSize()
            }
            if style == .full { Spacer(minLength: 4) }
            let waiting = sessions.filter { $0.status.needsYou }
            let hidden = waiting.filter { prefs.isDismissed($0) }
            if hidden.isEmpty {
                countChip(waiting.count, "waiting", SessionStatus.waiting.color)
            } else {
                // Dismissed sessions still count as waiting; tapping the chip brings their cards back.
                Button { restore(hidden) } label: {
                    countChip(waiting.count, "waiting", SessionStatus.waiting.color, hidden: hidden.count)
                }
                .buttonStyle(.plain)
            }
            countChip(sessions.filter { $0.status == .busy }.count, "working", SessionStatus.busy.color)
            countChip(sessions.filter { $0.status == .done }.count, "unread", SessionStatus.done.color)
        }
    }

    private func restore(_ hidden: [SessionInfo]) {
        withAnimation { prefs.restore(hidden) }
        client.showToast(hidden.count == 1 ? "Restored 1 dismissed session" : "Restored \(hidden.count) dismissed sessions")
    }

    @ViewBuilder
    private func countChip(_ n: Int, _ label: String, _ color: Color, hidden: Int = 0) -> some View {
        if n > 0 {
            HStack(spacing: 4) {
                Text("\(n)").font(.headline.monospacedDigit())
                // Beside the housing there's only room for the number; the color says which count it is.
                if style == .full { Text(label).font(.caption.weight(.semibold)) }
                if hidden > 0 {
                    Image(systemName: "eye.slash.fill").font(.caption2.weight(.semibold))
                }
            }
            .foregroundStyle(.black)
            .padding(.horizontal, style == .full ? 9 : 7).padding(.vertical, 4)
            .background(Capsule().fill(color))
            .fixedSize()
        }
    }
}

/// Do-not-disturb cycle and settings.
struct HeaderButtons: View {
    @EnvironmentObject var client: CompanionClient
    @EnvironmentObject var prefs: Prefs
    @Binding var showSettings: Bool
    var axis: Axis = .horizontal

    var body: some View {
        let layout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 10)) : AnyLayout(VStackLayout(spacing: 14))
        layout {
            Button { cycleDND() } label: {
                Image(systemName: dndSymbol).font(.title3).foregroundStyle(prefs.dndMode == .off ? .gray : .yellow)
            }
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill").font(.title3).foregroundStyle(.gray)
            }
        }
    }

    private var dndSymbol: String {
        switch prefs.dndMode {
        case .off: return "bell.fill"
        case .pinnedOnly: return "pin.fill"
        case .muted: return "moon.fill"
        }
    }

    private func cycleDND() {
        let all = DNDState.Mode.allCases
        prefs.dndMode = all[(all.firstIndex(of: prefs.dndMode)! + 1) % all.count]
        let message: String = switch prefs.dndMode {
        case .off: "Sounds on"
        case .pinnedOnly: "Sounds for pinned sessions only"
        case .muted: "All sounds muted"
        }
        client.showToast(message)
    }
}

/// Where the header's chips and buttons go. The status bar is hidden, so on a phone with a Dynamic Island
/// or notch the strip around the housing is empty: in portrait the ears either side of it, in landscape
/// the side insets. Upside down the housing ends up at the visual bottom, so the header keeps its own row.
enum HousingLayout: Equatable {
    case inline, ears, sideStrips

    init(size: CGSize, insets: EdgeInsets, upsideDown: Bool) {
        let landscape = size.width > size.height
        if landscape, min(insets.leading, insets.trailing) >= 40 {
            self = .sideStrips
        } else if !landscape, !upsideDown, insets.top >= 44 {
            self = .ears
        } else {
            self = .inline
        }
    }
}

struct HousingStats: View {
    let layout: HousingLayout
    let size: CGSize
    let insets: EdgeInsets
    let sessions: [SessionInfo]
    @Binding var showSettings: Bool

    var body: some View {
        switch layout {
        case .inline:
            EmptyView()
        case .ears:
            // A Dynamic Island is ~126pt wide (top inset ≥ 51pt); a notch is ~210pt.
            let housing: CGFloat = insets.top >= 51 ? 126 : 210
            let corner: CGFloat = 26 // keep clear of the rounded display corners
            let ear = max(0, (size.width - housing) / 2 - corner - 8)
            HStack(spacing: 0) {
                StatusChips(sessions: sessions, style: .compact)
                    .frame(width: ear, alignment: .leading)
                Spacer(minLength: housing + 16)
                HeaderButtons(showSettings: $showSettings)
                    .frame(width: ear, alignment: .trailing)
            }
            .padding(.horizontal, corner)
            .frame(height: insets.top)
            .frame(maxHeight: .infinity, alignment: .top)
            .offset(y: -insets.top)
        case .sideStrips:
            // The housing sits mid-height in one strip, so both strips keep to their upper half.
            HStack(spacing: 0) {
                StatusChips(sessions: sessions, style: .compact, axis: .vertical)
                    .frame(width: insets.leading)
                    .offset(x: -insets.leading)
                Spacer(minLength: 0)
                HeaderButtons(showSettings: $showSettings, axis: .vertical)
                    .frame(width: insets.trailing)
                    .offset(x: insets.trailing)
            }
            .padding(.top, 28)
            .frame(maxHeight: size.height / 2 - 70, alignment: .top)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

/// The 5-hour window front and center: how much is left and when it refills. The 7-day window rides underneath.
struct PlanUsageHero: View {
    let usage: UsageInfo
    let now: Date
    @State private var reminderNote: String?

    var body: some View {
        // Past its reset time the window has refilled, even if no fresh sample has arrived yet.
        let fiveLeft = left(usage.fiveHourPct ?? 0, resetsAt: usage.fiveHourResetsAt)
        let color = Self.color(left: fiveLeft)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("5-HOUR LIMIT").font(.caption2.weight(.bold)).foregroundStyle(.gray)
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text("\(Int(fiveLeft.rounded()))%")
                            .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(color)
                        Text("left").font(.title3.weight(.semibold)).foregroundStyle(Color.ink(0.6))
                    }
                }
                Spacer(minLength: 8)
                if let reset = usage.fiveHourResetsAt, reset > now {
                    // Tap to get a Reminders.app nudge when the window refills.
                    Button { remind(at: reset) } label: {
                        VStack(alignment: .trailing, spacing: 0) {
                            HStack(spacing: 3) {
                                Image(systemName: "bell").font(.system(size: 9, weight: .bold))
                                Text("RESETS").font(.caption2.weight(.bold))
                            }
                            .foregroundStyle(.gray)
                            Text(reset, format: .dateTime.hour().minute())
                                .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(.primary)
                            Text(reminderNote ?? "in \(countdown(to: reset))")
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(reminderNote == nil ? Color.ink(0.6) : .green)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.ink(0.16))
                    Capsule().fill(color).frame(width: geo.size.width * min(1, fiveLeft / 100))
                }
            }
            .frame(height: 10)
            if let sd = usage.sevenDayPct {
                let sevenLeft = left(sd, resetsAt: usage.sevenDayResetsAt)
                HStack(spacing: 6) {
                    Text("7-day").font(.caption.weight(.bold)).foregroundStyle(.gray)
                    Text("\(Int(sevenLeft.rounded()))% left").font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Self.color(left: sevenLeft))
                    if let reset = usage.sevenDayResetsAt, reset > now {
                        Text("· resets \(reset.formatted(.dateTime.weekday(.abbreviated).hour()))")
                            .font(.caption.monospacedDigit()).foregroundStyle(Color.ink(0.5))
                    }
                    Spacer(minLength: 0)
                }
                .lineLimit(1)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.ink(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(fiveLeft <= 30 ? 0.6 : 0), lineWidth: 1.5))
    }

    private func remind(at reset: Date) {
        Task {
            let note: String
            switch await ResumeReminder.create(at: reset) {
            case .created: note = "reminder set"
            case .alreadySet: note = "already set"
            case .denied: note = "allow in Settings"
            case .failed: note = "couldn't save"
            }
            UINotificationFeedbackGenerator().notificationOccurred(note == "reminder set" ? .success : .warning)
            reminderNote = note
            try? await Task.sleep(for: .seconds(3))
            reminderNote = nil
        }
    }

    private func left(_ usedPct: Double, resetsAt: Date?) -> Double {
        if let resetsAt, resetsAt <= now { return 100 }
        return max(0, 100 - usedPct)
    }

    static func color(left: Double) -> Color {
        left <= 10 ? .red : left <= 30 ? .orange : Color.ink(0.92)
    }

    private func countdown(to date: Date) -> String {
        let s = max(0, Int(date.timeIntervalSince(now)))
        if s >= 86_400 { return "\(s / 86_400)d \((s % 86_400) / 3600)h" }
        if s >= 3600 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        return "\(s / 60)m"
    }
}

struct TodayTokens: View {
    let usage: UsageInfo

    var body: some View {
        Text("today \(usage.todayMessages) msgs · \(compactTokens(usage.todayOutputTokens)) out · \(compactTokens(usage.todayInputTokens + usage.todayCacheReadTokens)) in")
            .font(.caption.monospacedDigit())
            .foregroundStyle(Color.ink(0.55))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

struct IdleSection<Menu: View>: View {
    let sessions: [SessionInfo]
    let now: Date
    @Binding var expanded: Bool
    let grouped: Bool
    let onTap: (SessionInfo) -> Void
    @ViewBuilder let menu: (SessionInfo) -> Menu

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    Text("Idle (\(sessions.count))")
                    Spacer()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.gray)
            }
            if expanded {
                if grouped {
                    ForEach(groups(sessions), id: \.project) { g in
                        Text(g.project)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.ink(0.45))
                            .padding(.top, 6).padding(.leading, 2)
                        rows(g.sessions)
                    }
                } else {
                    rows(sessions)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 16)
    }

    private func rows(_ sessions: [SessionInfo]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 8)], spacing: 6) {
            ForEach(sessions) { s in
                HStack(spacing: 8) {
                    Circle().fill(s.status.color).frame(width: 7, height: 7)
                    Text(s.title).lineLimit(1).foregroundStyle(Color.ink(0.75))
                    Spacer()
                    if !grouped {
                        Text(s.project).lineLimit(1).foregroundStyle(Color.ink(0.4))
                    }
                    if let at = s.lastActivityAt {
                        Text(elapsed(at, now: now)).monospacedDigit().foregroundStyle(Color.ink(0.4))
                    }
                }
                .font(.caption)
                .padding(.vertical, 5).padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.ink(0.07)))
                .contentShape(Rectangle())
                .onTapGesture { onTap(s) }
                .contextMenu { menu(s) }
            }
        }
    }
}

/// Folders used in the last week, most recent first. Tap one to start a new session there on the Mac.
struct ProjectsSection: View {
    let projects: [RecentProject]
    let now: Date
    @Binding var expanded: Bool
    let onTap: (RecentProject) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    Text("New session in… (\(projects.count))")
                    Spacer()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.gray)
            }
            if expanded {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 8)], spacing: 6) {
                    ForEach(projects) { p in
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill").foregroundStyle(Color.ink(0.45))
                            Text(p.name).font(.subheadline.weight(.semibold)).lineLimit(1).foregroundStyle(Color.ink(0.85))
                            Spacer()
                            Text(elapsed(p.lastUsedAt, now: now)).font(.caption).monospacedDigit().foregroundStyle(Color.ink(0.4))
                            NewSessionPill()
                        }
                        .padding(.vertical, 6).padding(.leading, 10).padding(.trailing, 6)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.ink(0.07)))
                        .contentShape(Rectangle())
                        .onTapGesture { onTap(p) }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 16)
    }
}

/// The "start a session here" affordance. Sized to be an easy thumb target; the enclosing row handles the tap.
struct NewSessionPill: View {
    var body: some View {
        Label("New", systemImage: "plus")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(Color.ink(0))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(Color.ink(0.85)))
            .frame(minHeight: 44)
    }
}

struct ProjectHeader: View {
    let project: String
    let sessions: [SessionInfo]

    var body: some View {
        HStack(spacing: 6) {
            // The first session is the group's most urgent one.
            if let top = sessions.first { Circle().fill(top.status.color).frame(width: 8, height: 8) }
            Image(systemName: "folder.fill").font(.caption)
            Text(project).font(.subheadline.weight(.bold))
            Text("\(sessions.count)").font(.caption.monospacedDigit()).foregroundStyle(Color.ink(0.45))
            Spacer()
            NewSessionPill()
        }
        .foregroundStyle(Color.ink(0.8))
        .lineLimit(1)
    }
}

/// Splits an already-sorted list by project. Groups keep the order of their first session, so the most urgent project leads.
func groups(_ sessions: [SessionInfo]) -> [(project: String, sessions: [SessionInfo])] {
    var out: [(project: String, sessions: [SessionInfo])] = []
    var index: [String: Int] = [:]
    for s in sessions {
        if let i = index[s.project] {
            out[i].sessions.append(s)
        } else {
            index[s.project] = out.count
            out.append((s.project, [s]))
        }
    }
    return out
}
