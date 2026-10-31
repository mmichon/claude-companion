import SwiftUI
import CompanionShared

struct SettingsView: View {
    @EnvironmentObject var client: CompanionClient
    @EnvironmentObject var prefs: Prefs
    @Environment(\.alerts) private var alerts
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Sounds") {
                    Picker("Alerts", selection: $prefs.dndMode) {
                        Text("All sessions").tag(DNDState.Mode.off)
                        Text("Pinned only").tag(DNDState.Mode.pinnedOnly)
                        Text("Muted").tag(DNDState.Mode.muted)
                    }
                    HStack {
                        Image(systemName: "speaker.fill")
                        Slider(value: $prefs.volume, in: 0.1...1)
                        Image(systemName: "speaker.wave.3.fill")
                    }
                    Toggle("Re-alert on long waits (5/10/15 min)", isOn: $prefs.escalate)
                    HStack {
                        Text("Test")
                        Spacer()
                        ForEach(Array(zip(["Done", "Wait", "Perm", "Long"], [TonePlayer.Sound.done, .waiting, .permission, .escalate])), id: \.0) { name, sound in
                            Button(name) { alerts?.test(sound) }.buttonStyle(.bordered)
                        }
                    }
                }
                Section("Board") {
                    Toggle("Group by project", isOn: $prefs.groupByProject)
                }
                Section {
                    Toggle("Night mode", isOn: $prefs.nightEnabled)
                    if prefs.nightEnabled {
                        Stepper("Starts \(hour(prefs.nightStart))", value: $prefs.nightStart, in: 0...23)
                        Stepper("Ends \(hour(prefs.nightEnd))", value: $prefs.nightEnd, in: 0...23)
                    }
                } header: {
                    Text("Night")
                } footer: {
                    Text("Dims the screen and mutes all sounds during these hours.")
                }
                Section {
                    LabeledContent("Connected to", value: client.macName ?? "—")
                    TextField("Manual host (blank = Bonjour)", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { client.manualHost = host }
                    Button("Reconnect") { client.manualHost = host }
                    Button("Unpair this phone", role: .destructive) { client.unpair(); dismiss() }
                } header: {
                    Text("Mac")
                } footer: {
                    Text("Leave the host blank to find the Mac automatically. Otherwise enter e.g. 10.0.0.20 or mac.local:47820.")
                }
            }
            .navigationTitle("Companion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { host = client.manualHost }
        }
        .preferredColorScheme(.dark)
    }

    private func hour(_ h: Int) -> String {
        var c = DateComponents()
        c.hour = h
        let date = Calendar.current.date(from: c) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}
