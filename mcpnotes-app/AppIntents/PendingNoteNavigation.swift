import Foundation

/// Hands off "open this note" requests from `OpenNoteIntent` to the foregrounded app instance.
/// An App Intent may run in a separate background instance of this app's process from the one
/// the user is about to see (the same reason `CreateNoteIntent`'s writes only reliably reach the
/// UI via a foreground-triggered reload rather than shared in-memory state — see
/// `mcpnotes_App`'s `scenePhase` handling). `UserDefaults.standard` is backed by a plist in the
/// app's shared container, so it's visible across any process instance of this same app.
enum PendingNoteNavigation {
    private static let key = "pendingOpenNoteID"

    static func request(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: key)
    }

    /// Reads and clears the pending target, if any. Call once per foreground transition.
    static func consume() -> UUID? {
        guard let string = UserDefaults.standard.string(forKey: key) else { return nil }
        UserDefaults.standard.removeObject(forKey: key)
        return UUID(uuidString: string)
    }
}
