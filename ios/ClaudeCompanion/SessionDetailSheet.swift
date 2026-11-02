import SwiftUI
import CompanionShared

/// What a session is asking for. Permission requests can be answered here while you're away from the Mac;
/// held questions get a picker (with a free-text "Other"), and a desktop turn that ended on a question can be
/// answered with a short typed reply.
struct SessionDetailSheet: View {
    @EnvironmentObject var client: CompanionClient
    @EnvironmentObject var prefs: Prefs
    @Environment(\.dismiss) private var dismiss
    let sessionId: String
    /// Chosen labels per question, while a held AskUserQuestion is open.
    @State private var picks: [String: Set<String>] = [:]
    /// Free-text "Other" answers per question.
    @State private var others: [String: String] = [:]
    @State private var replyText = ""
    @FocusState private var replyFocused: Bool

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
                        if !prompt.options.isEmpty, !canReply(s) {
                            VStack(alignment: .leading, spacing: 6) {
                                // Plain bullets: these are read-only, so they mustn't look like the picker's radio buttons.
                                ForEach(prompt.options, id: \.self) { o in
                                    Text("•  \(o)").font(.callout).foregroundStyle(Color.ink(0.6))
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
                permissionButtons(p, desktop: s.isDesktop, threshold: client.snapshot?.awayThreshold ?? 60)
            } else if let prompt = s.prompt, prompt.kind == .question {
                if let rid = prompt.requestId, let qs = prompt.questions {
                    let ready = qs.allSatisfy { !answerText($0).isEmpty }
                    Button {
                        client.answer(requestId: rid, answers: qs.reduce(into: [:]) { out, q in out[q.question] = answerText(q) })
                        dismiss()
                    } label: {
                        Text("Send answer").font(.title3.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent).tint(.green).disabled(!ready)
                } else {
                    Text(s.isDesktop
                         ? "This question is already showing on the Mac, so answer it there. New questions wait for the phone until you open the session on the Mac."
                         : "You're at the Mac, so the question is showing there. The phone can answer new questions once the Mac has been idle for \(Int(client.snapshot?.awayThreshold ?? 60)) s.")
                        .font(.footnote)
                        .foregroundStyle(.gray)
                }
            } else if canReply(s) {
                replyBox(s)
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
    private func permissionButtons(_ p: PermissionInfo, desktop: Bool, threshold: Double) -> some View {
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
            Text(desktop
                 ? "This request is showing on the Mac because you opened the session there. New requests wait for the phone until you open the session on the Mac."
                 : "You're at the Mac, so the prompt is showing there. The phone can answer new requests once the Mac has been idle for \(Int(threshold)) s.")
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
                            if !q.multiSelect, !on { others[q.question] = nil }
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
                    TextField("Other…", text: Binding(
                        get: { others[q.question] ?? "" },
                        set: { v in
                            others[q.question] = v
                            if !q.multiSelect, !v.isEmpty { picks[q.question] = [] }
                        }), axis: .vertical)
                        .lineLimit(1...3)
                        .font(.callout)
                        .padding(.vertical, 8).padding(.horizontal, 10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.ink(0.1)))
                }
            }
        }
    }

    /// The picked labels, plus the typed "Other" text, comma-joined.
    private func answerText(_ q: PendingPrompt.Question) -> String {
        var parts = q.options.filter { (picks[q.question] ?? []).contains($0) }
        let other = (others[q.question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !other.isEmpty { parts.append(other) }
        return parts.joined(separator: ", ")
    }

    /// A desktop turn that ended on a question: it can be answered with a typed reply.
    private func canReply(_ s: SessionInfo) -> Bool {
        s.isDesktop && s.status == .waiting && s.prompt?.kind == .message
    }

    private func replyBox(_ s: SessionInfo) -> some View {
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(spacing: 10) {
            // The question's suggested answers (a wrap-up's buttons): one tap sends the label as the reply.
            ForEach(s.prompt?.options ?? [], id: \.self) { o in
                Button { sendReply(s, text: o) } label: {
                    Text(o).font(.title3.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent).tint(o == s.prompt?.options.first ? .green : Color.ink(0.4))
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Reply to Claude", text: $replyText, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($replyFocused)
                    .submitLabel(.send)
                    .onSubmit { sendReply(s, text: replyText) }
                    .padding(.vertical, 10).padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.ink(0.1)))
                Button { sendReply(s, text: replyText) } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 34))
                }
                .tint(.green)
                .disabled(text.isEmpty)
            }
        }
    }

    private func sendReply(_ s: SessionInfo, text raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        client.reply(s, text: text)
        replyText = ""
        replyFocused = false
        dismiss()
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

extension SessionInfo {
    /// A question, or a desktop turn that ended on one: tapping the card opens the sheet instead of the Mac, so you
    /// see the options even while the question is showing on the Mac.
    var answerableFromPhone: Bool {
        guard status == .waiting, let prompt else { return false }
        return prompt.kind == .question || (isDesktop && prompt.kind == .message)
    }
}
