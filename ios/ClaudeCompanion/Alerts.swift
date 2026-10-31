import AVFoundation
import Foundation
import CompanionShared

/// Per-phone preferences: pins, mutes, do-not-disturb, night schedule.
@MainActor
final class Prefs: ObservableObject {
    private let d = UserDefaults.standard

    @Published var pinned: Set<String> { didSet { d.set(Array(pinned), forKey: "pinned") } }
    @Published var muted: Set<String> { didSet { d.set(Array(muted), forKey: "muted") } }
    @Published var dndMode: DNDState.Mode { didSet { d.set(dndMode.rawValue, forKey: "dndMode") } }
    @Published var nightEnabled: Bool { didSet { d.set(nightEnabled, forKey: "nightEnabled") } }
    @Published var nightStart: Int { didSet { d.set(nightStart, forKey: "nightStart") } }
    @Published var nightEnd: Int { didSet { d.set(nightEnd, forKey: "nightEnd") } }
    @Published var escalate: Bool { didSet { d.set(escalate, forKey: "escalate") } }
    @Published var volume: Double { didSet { d.set(volume, forKey: "volume") } }
    @Published var idleExpanded: Bool { didSet { d.set(idleExpanded, forKey: "idleExpanded") } }
    @Published var groupByProject: Bool { didSet { d.set(groupByProject, forKey: "groupByProject") } }
    @Published var projectsExpanded: Bool { didSet { d.set(projectsExpanded, forKey: "projectsExpanded") } }
    /// Swiped-away sessions: id -> the statusSince they were dismissed at. A new status brings the card back.
    @Published var dismissed: [String: Date] {
        didSet { d.set(dismissed.mapValues(\.timeIntervalSince1970), forKey: "dismissed") }
    }

    init() {
        pinned = Set(d.stringArray(forKey: "pinned") ?? [])
        muted = Set(d.stringArray(forKey: "muted") ?? [])
        dndMode = DNDState.Mode(rawValue: d.string(forKey: "dndMode") ?? "") ?? .off
        nightEnabled = d.object(forKey: "nightEnabled") as? Bool ?? false
        nightStart = d.object(forKey: "nightStart") as? Int ?? 22
        nightEnd = d.object(forKey: "nightEnd") as? Int ?? 7
        escalate = d.object(forKey: "escalate") as? Bool ?? true
        volume = d.object(forKey: "volume") as? Double ?? 0.6
        idleExpanded = d.object(forKey: "idleExpanded") as? Bool ?? false
        groupByProject = d.object(forKey: "groupByProject") as? Bool ?? true
        projectsExpanded = d.object(forKey: "projectsExpanded") as? Bool ?? true
        dismissed = (d.dictionary(forKey: "dismissed") as? [String: Double] ?? [:]).mapValues { Date(timeIntervalSince1970: $0) }
    }

    func isNight(_ date: Date = Date()) -> Bool {
        guard nightEnabled else { return false }
        let h = Calendar.current.component(.hour, from: date)
        return nightStart <= nightEnd ? (h >= nightStart && h < nightEnd) : (h >= nightStart || h < nightEnd)
    }

    var dndState: DNDState { DNDState(mode: dndMode, night: isNight()) }

    /// Whether an event for this session should make a sound right now.
    func audible(_ id: String) -> Bool {
        if muted.contains(id) || isNight() { return false }
        switch dndMode {
        case .off: return true
        case .muted: return false
        case .pinnedOnly: return pinned.contains(id)
        }
    }

    func togglePin(_ id: String) { if pinned.contains(id) { pinned.remove(id) } else { pinned.insert(id) } }
    func toggleMute(_ id: String) { if muted.contains(id) { muted.remove(id) } else { muted.insert(id) } }

    func dismiss(_ s: SessionInfo) { dismissed[s.id] = s.statusSince }
    func restore(_ sessions: [SessionInfo]) { for s in sessions { dismissed[s.id] = nil } }
    func isDismissed(_ s: SessionInfo) -> Bool {
        // Dates round-trip through the wire as milliseconds.
        guard let at = dismissed[s.id] else { return false }
        return abs(at.timeIntervalSince(s.statusSince)) < 0.002
    }
    /// Drop dismissals for sessions that ended or moved on to a new status.
    func pruneDismissed(_ sessions: [SessionInfo]) {
        let keep = dismissed.filter { id, _ in sessions.contains { $0.id == id && isDismissed($0) } }
        if keep.count != dismissed.count { dismissed = keep }
    }
}

/// Turns snapshot transitions into sounds, and re-alerts on long waits.
@MainActor
final class Alerts {
    private let prefs: Prefs
    private let tones = TonePlayer()
    /// How many escalation alerts each waiting session has had (max 3, every 5 min).
    private var escalations: [String: Int] = [:]
    private var timer: Timer?

    init(prefs: Prefs) {
        self.prefs = prefs
    }

    func attach(to client: CompanionClient) {
        client.onSnapshot = { [weak self] old, new in self?.diff(old, new) }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self, weak client] _ in
            Task { @MainActor in if let snap = client?.snapshot { self?.checkEscalation(snap) } }
        }
    }

    private func diff(_ old: Snapshot?, _ new: Snapshot) {
        // First snapshot after (re)connecting: no sounds for state you already had.
        guard let old else { return }
        let before = Dictionary(old.sessions.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
        var sound: TonePlayer.Sound?
        for s in new.sessions {
            let was = before[s.id]
            guard was != s.status else { continue }
            if !s.status.needsYou { escalations[s.id] = nil }
            guard prefs.audible(s.id) else { continue }
            let candidate: TonePlayer.Sound? = switch s.status {
            case .permission: .permission
            case .waiting: .waiting
            case .done where was == .busy: .done
            case .error: .error
            default: nil
            }
            // One sound per snapshot, the most urgent.
            if let c = candidate, sound == nil || c.rank < sound!.rank { sound = c }
        }
        if let sound { tones.play(sound, volume: prefs.volume) }
    }

    private func checkEscalation(_ snap: Snapshot) {
        guard prefs.escalate else { return }
        let now = Date()
        for s in snap.sessions where s.status.needsYou && !prefs.isDismissed(s) {
            let count = escalations[s.id] ?? 0
            let due = now.timeIntervalSince(s.statusSince) >= Double(count + 1) * 300
            if count < 3, due {
                escalations[s.id] = count + 1
                if prefs.audible(s.id) { tones.play(.escalate, volume: prefs.volume) }
                return
            }
        }
    }

    func test(_ sound: TonePlayer.Sound) { tones.play(sound, volume: prefs.volume) }
}

/// Short synthesized chimes, mixed with whatever else is playing.
final class TonePlayer {
    enum Sound: CaseIterable {
        case permission, waiting, escalate, error, done

        var rank: Int { Sound.allCases.firstIndex(of: self)! }

        /// (frequency Hz, duration s, gain)
        var notes: [(Double, Double, Double)] {
            switch self {
            case .done: return [(1046.5, 0.11, 0.5), (1318.5, 0.22, 0.45)]
            case .waiting: return [(784.0, 0.14, 0.7), (1174.7, 0.26, 0.7)]
            case .permission: return [(1760, 0.07, 0.8), (0, 0.05, 0), (1760, 0.07, 0.8), (0, 0.05, 0), (2093, 0.16, 0.8)]
            case .escalate: return [(1318.5, 0.15, 0.9), (1046.5, 0.15, 0.9), (784.0, 0.3, 0.9)]
            case .error: return [(440, 0.18, 0.7), (349.2, 0.3, 0.7)]
            }
        }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func play(_ sound: Sound, volume: Double) {
        if !engine.isRunning { try? engine.start() }
        guard engine.isRunning, let buffer = render(sound.notes) else { return }
        player.volume = Float(volume)
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
    }

    private func render(_ notes: [(Double, Double, Double)]) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let total = AVAudioFrameCount(notes.reduce(0) { $0 + $1.1 } * rate)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total), let out = buf.floatChannelData?[0] else { return nil }
        var i = 0
        for (freq, dur, gain) in notes {
            let n = Int(dur * rate)
            let attack = Int(0.005 * rate)
            for k in 0..<n {
                let t = Double(k) / rate
                // Fast attack, exponential decay; a soft second harmonic gives it a bell-ish edge.
                let env = (k < attack ? Double(k) / Double(attack) : 1) * exp(-t * 9)
                let wave = sin(2 * .pi * freq * t) + 0.25 * sin(4 * .pi * freq * t)
                out[i + k] = Float(freq == 0 ? 0 : wave * env * gain * 0.4)
            }
            i += n
        }
        buf.frameLength = AVAudioFrameCount(i)
        return buf
    }
}
