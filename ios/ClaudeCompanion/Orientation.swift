import SwiftUI
import UIKit

/// Face ID iPhones never rotate the interface to portrait-upside-down, whatever
/// the app declares. The phone stands on its top edge so the charging cable fits,
/// so watch the physical orientation and turn the content 180° ourselves.
@MainActor
final class UpsideDownWatcher: ObservableObject {
    @Published private(set) var isUpsideDown = false
    private var observer: NSObjectProtocol?

    init() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        observer = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    private func update() {
        switch UIDevice.current.orientation {
        case .portraitUpsideDown:
            isUpsideDown = true
            // iOS leaves the interface in whatever orientation it was last in
            // (often landscape); put it back in portrait so the flip is right.
            requestPortrait()
        case .portrait, .landscapeLeft, .landscapeRight: isUpsideDown = false
        default: break // face up/down, unknown: keep the last state
        }
    }

    private func requestPortrait() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes
        where scene.interfaceOrientation != .portrait {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        }
    }
}

private struct FlipWhenUpsideDown: ViewModifier {
    @StateObject private var watcher = UpsideDownWatcher()

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(watcher.isUpsideDown ? 180 : 0))
            .animation(.easeInOut(duration: 0.3), value: watcher.isUpsideDown)
    }
}

extension View {
    func flipWhenUpsideDown() -> some View { modifier(FlipWhenUpsideDown()) }
}
