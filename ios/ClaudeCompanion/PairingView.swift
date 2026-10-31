import SwiftUI

struct PairingView: View {
    @EnvironmentObject var client: CompanionClient
    @State private var code = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "iphone.and.arrow.forward").font(.system(size: 54)).foregroundStyle(.orange)
            Text("Pair with \(client.macName ?? "your Mac")").font(.title2.weight(.bold)).foregroundStyle(.primary)

            switch client.phase {
            case .enteringCode(let error):
                Text("Enter the 6-digit code shown on the Mac (notification and menu bar).")
                    .multilineTextAlignment(.center).foregroundStyle(.gray)
                TextField("000000", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.system(size: 44, weight: .bold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
                    .focused($focused)
                    .frame(maxWidth: 260)
                    .onChange(of: code) { _, v in
                        code = String(v.filter(\.isNumber).prefix(6))
                        if code.count == 6 { client.submitCode(code); code = "" }
                    }
                    .onAppear { focused = true }
                if let error { Text(error).foregroundStyle(.red) }
                Button("Send a new code") { client.requestPairing() }.foregroundStyle(.gray)
            case .needsPairing(let error):
                if let error { Text(error).foregroundStyle(.red) }
                Button {
                    client.requestPairing()
                } label: {
                    Text("Show code on Mac").font(.headline).padding(.horizontal, 24).padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent).tint(.orange)
            default:
                EmptyView()
            }
        }
        .padding(24)
    }
}
