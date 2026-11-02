import AppKit
import SwiftUI

/// Reports whether the hosting window is really on screen, and hands out the window itself.
///
/// `.onAppear` / `.onDisappear` are not enough: a `MenuBarExtra` keeps its hosted view alive while
/// the panel is closed, and closing a `Window` scene doesn't always remove its content. This watches
/// the `NSWindow` instead (key changes, close, occlusion), so a flag driven by it can't stick.
struct WindowVisibility: NSViewRepresentable {
    let onChange: (Bool) -> Void
    var onWindow: (NSWindow?) -> Void = { _ in }

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onChange = onChange
        view.onWindow = onWindow
    }

    final class TrackingView: NSView {
        var onChange: (Bool) -> Void = { _ in }
        var onWindow: (NSWindow?) -> Void = { _ in }
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            onWindow(window)
            guard let window else { return report(false) }

            let center = NotificationCenter.default
            let names: [Notification.Name] = [
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
            ]
            for name in names {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    // Hop one turn so `isVisible` and the occlusion state have settled.
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.evaluate() } }
                })
            }
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report(false) }
            })
            evaluate()
        }

        private func evaluate() {
            guard let window else { return report(false) }
            report(window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible))
        }

        private func report(_ visible: Bool) { onChange(visible) }
    }
}
