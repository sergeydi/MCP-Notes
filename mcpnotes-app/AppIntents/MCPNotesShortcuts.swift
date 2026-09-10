import AppIntents

/// Registers phrases that surface `CreateNoteIntent`/`SearchNotesIntent` directly in Siri and
/// the Shortcuts app without any per-user setup.
struct MCPNotesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateNoteIntent(),
            phrases: [
                "Create a note in \(.applicationName)",
                "Add a new note to \(.applicationName)"
            ],
            shortTitle: "Create Note",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: SearchNotesIntent(),
            phrases: [
                "Search notes in \(.applicationName)",
                "Find a note in \(.applicationName)"
            ],
            shortTitle: "Search Notes",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: OpenNoteIntent(),
            phrases: [
                "Open a note in \(.applicationName)"
            ],
            shortTitle: "Open Note",
            systemImageName: "note.text"
        )
        AppShortcut(
            intent: AppendToNoteIntent(),
            phrases: [
                "Add to a note in \(.applicationName)",
                "Append to a note in \(.applicationName)"
            ],
            shortTitle: "Add to Note",
            systemImageName: "text.append"
        )
        AppShortcut(
            intent: ToggleBookmarkIntent(),
            phrases: [
                "Bookmark a note in \(.applicationName)",
                "Toggle bookmark in \(.applicationName)"
            ],
            shortTitle: "Toggle Bookmark",
            systemImageName: "bookmark.fill"
        )
        AppShortcut(
            intent: ListBookmarkedNotesIntent(),
            phrases: [
                "List bookmarked notes in \(.applicationName)",
                "Show bookmarks in \(.applicationName)"
            ],
            shortTitle: "Bookmarked Notes",
            systemImageName: "bookmark.circle.fill"
        )
    }
}
