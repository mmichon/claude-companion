import SwiftUI

@main
struct ClaudeCompanionApp: App {
    @StateObject private var client = CompanionClient()
    @StateObject private var prefs = Prefs()
    @State private var alerts: Alerts?
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .flipWhenUpsideDown()
                .environmentObject(client)
                .environmentObject(prefs)
                .environment(\.alerts, alerts)
                .preferredColorScheme(prefs.appearance.colorScheme)
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
                .onAppear {
                    if alerts == nil {
                        let a = Alerts(prefs: prefs)
                        a.attach(to: client)
                        alerts = a
                    }
                    client.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    // Sits on a charger: never let the screen sleep while the app is up.
                    UIApplication.shared.isIdleTimerDisabled = phase == .active
                    if phase == .active { client.restart() }
                }
        }
    }
}

private struct AlertsKey: EnvironmentKey {
    static let defaultValue: Alerts? = nil
}

extension EnvironmentValues {
    var alerts: Alerts? {
        get { self[AlertsKey.self] }
        set { self[AlertsKey.self] = newValue }
    }
}

struct RootView: View {
    @EnvironmentObject var client: CompanionClient

    var body: some View {
        ZStack {
            Color.ink(0).ignoresSafeArea()
            switch client.phase {
            case .needsPairing, .enteringCode:
                PairingView()
            case .searching, .connecting:
                if client.snapshot != nil {
                    BoardView()
                } else {
                    SearchingView()
                }
            case .connected:
                BoardView()
            }
        }
    }
}

struct SearchingView: View {
    @EnvironmentObject var client: CompanionClient
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 18) {
            ProgressView().tint(.primary).scaleEffect(1.4)
            Text(label).font(.title3.weight(.semibold)).foregroundStyle(.primary)
            Text("Run claude-companiond on your Mac, on the same network.")
                .font(.subheadline).foregroundStyle(.gray)
            Button("Settings") { showSettings = true }
                .buttonStyle(.bordered).tint(.gray)
        }
        .padding()
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private var label: String {
        if case .connecting(let name) = client.phase { return "Connecting to \(name)…" }
        return "Looking for your Mac…"
    }
}
