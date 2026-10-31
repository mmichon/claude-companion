import SwiftUI
import CompanionShared

/// What a session is asking for. Permission requests can be answered here while you're away from the Mac;
/// questions and replies are read-only, with a jump to the Mac.
struct SessionDetailSheet: View {
    @EnvironmentObject var client: CompanionClient
    @EnvironmentObject var prefs: Prefs
    @Environment(\.dismiss) private var dismiss
    let sessionId: String
    /// Chosen labels per question, while a held AskUserQuestion is open.
    @State private var picks: [String: Set<String>] = [:]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            if let s = client.snapshot?.sessions.first(where: { $0.id == sessionId }) {
                content(s, now: ctx.date)
            } else {
                Text("Session ended").foregroundStyle(.gray).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.ink(0).ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func content(_ s: SessionInfo, now: Date) -> some View {
        let color = s.displayColor(now: now)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(s.status.label, systemImage: s.status.symbol)
                    .font(.headline.weight(.heavy)).foregroundStyle(.black)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(color))
                Spacer()
                Text(elapsed(s.statusSince, now: now))
                    .font(.system(.title2, design: .rounded).weight(.bold).monospacedDigit())
                    .foregroundStyle(color)
            }
            Text(s.title).font(.title2.weight(.bold)).foregroundStyle(.primary)
            Text(s.cwd).font(.caption.monospaced()).foregroundStyle(.gray).lineLimit(1).truncationMode(.head)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let p = s.permission {
                        permissionBody(p)
                    } else if let prompt = s.prompt, prompt.requestId != nil, let qs = prompt.questions, !qs.isEmpty {
                        questionPicker(qs)
                    } else if let prompt = s.prompt {
                        Text(markdown(prompt.text)).font(.body).foregroundStyle(.primary).textSelection(.enabled)
                        if !prompt.options.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(prompt.options, id: \.self) { o in
                                    Label(o, systemImage: "circle").font(.callout).foregroundStyle(Color.ink(0.8))
                                }
                            }
                            .padding(.top, 4)
                        }
                    } else if let summary = s.summary {
                        Text(summary).foregroundStyle(Color.ink(0.8))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let p = s.permission {
                permissionButtons(p, macIdle: client.snapshot?.macIdleSeconds ?? 0, threshold: client.snapshot?.awayThreshold ?? 60)
            } else if let prompt = s.prompt, prompt.kind == .question {
                if let rid = prompt.requestId, let qs = prompt.questions {
                    let ready = qs.allSatisfy { !(picks[$0.question] ?? []).isEmpty }
                    Button {
                        client.answer(requestId: rid, answers: qs.reduce(into: [:]) { out, q in
                            out[q.question] = q.options.filter { (picks[q.question] ?? []).contains($0) }.joined(separator: ", ")
                        })
                        dismiss()
                    } label: {
                        Text("Send answer").font(.title3.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent).tint(.green).disabled(!ready)
                } else {
                    Text("You're at the Mac, so the question is showing there. The phone can answer new questions once the Mac has been idle for \(Int(client.snapshot?.awayThreshold ?? 60)) s.")
                        .font(.footnote)
                        .foregroundStyle(.gray)
                }
            }
            HStack(spacing: 12) {
                Button {
                    client.open(s)
                    dismiss()
                } label: {
                    Label("Open on Mac", systemImage: "macbook").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.bordered).tint(.primary)
                if s.status == .busy || s.status == .permission {
                    Button(role: .destructive) { client.interrupt(s) } label: {
                        Label("Esc", systemImage: "stop.circle").padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .font(.headline)
        }
        .padding(20)
    }

    private func permissionBody(_ p: PermissionInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(p.toolName).font(.headline).foregroundStyle(SessionStatus.permission.color)
            Text(p.summary)
                .font(.callout.monospaced())
                .foregroundStyle(.primary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.ink(0.1)))
                .textSelection(.enabled)
            if !p.detail.isEmpty {
                DisclosureGroup("Full request") {
                    Text(p.detail).font(.caption.monospaced()).foregroundStyle(Color.ink(0.7)).textSelection(.enabled)
                }
                .foregroundStyle(.gray)
            }
        }
    }

    @ViewBuilder
    private func permissionButtons(_ p: PermissionInfo, macIdle: Double, threshold: Double) -> some View {
        if p.decidableFromPhone {
            HStack(spacing: 12) {
                Button {
                    client.decide(p, allow: false)
                    dismiss()
                } label: {
                    Text("Deny").font(.title3.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent).tint(.red)
                Button {
                    client.decide(p, allow: true)
                    dismiss()
                } label: {
                    Text("Allow").font(.title3.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent).tint(.green)
            }
        } else {
            Text("You're at the Mac, so the prompt is showing there. The phone can answer new requests once the Mac has been idle for \(Int(threshold)) s.")
                .font(.footnote)
                .foregroundStyle(.gray)
        }
    }

    private func questionPicker(_ qs: [PendingPrompt.Question]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(qs, id: \.question) { q in
                VStack(alignment: .leading, spacing: 8) {
                    if let h = q.header { Text(h.uppercased()).font(.caption.weight(.bold)).foregroundStyle(.gray) }
                    Text(markdown(q.question)).font(.body).foregroundStyle(.primary)
                    ForEach(q.options, id: \.self) { o in
                        let on = (picks[q.question] ?? []).contains(o)
                        Button {
                            var set = q.multiSelect ? (picks[q.question] ?? []) : []
                            if on { set.remove(o) } else { set.insert(o) }
                            picks[q.question] = set
                        } label: {
                            Label(o, systemImage: on ? (q.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle")
                                                     : (q.multiSelect ? "square" : "circle"))
                                .font(.callout).foregroundStyle(on ? .primary : Color.ink(0.8))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8).padding(.horizontal, 10)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.ink(on ? 0.2 : 0.1)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
