import SpriteKit

// Workaround for a SpriteKit bug on macOS: when a SwiftUI Window scene is closed
// (hidden via orderOut:), SpriteKit stops the display link internally but does NOT
// go through the isPaused setter, leaving the property stuck at false. On reopen
// (orderFront:), setting isPaused = false is then a no-op (false → false) and the
// display link never restarts. Fix: explicitly set isPaused = true when the window
// is hidden so the next unpause is a real true → false transition.
final class GraphSKView: SKView {
    var onWindowBecomeVisible: (() -> Void)?
    private var keyObserver: Any?
    private var occlusionObserver: Any?
    private var wasVisible: Bool = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = keyObserver { NotificationCenter.default.removeObserver(o); keyObserver = nil }
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o); occlusionObserver = nil }
        guard let win = window else { return }
        wasVisible = win.isVisible

        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            self?.isPaused = false
        }

        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: win,
            queue: .main
        ) { [weak self, weak win] _ in
            guard let self, let win else { return }
            let nowVisible = win.isVisible
            if nowVisible && !self.wasVisible {
                self.isPaused = false
                if let currentScene = self.scene { self.presentScene(currentScene) }
                self.onWindowBecomeVisible?()
            } else if !nowVisible && self.wasVisible {
                self.isPaused = true
            }
            self.wasVisible = nowVisible
        }
    }

    deinit {
        if let o = keyObserver { NotificationCenter.default.removeObserver(o) }
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o) }
    }
}
