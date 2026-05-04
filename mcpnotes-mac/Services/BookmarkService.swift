import Foundation

/// Manages bookmarked note IDs via iCloud Key-Value Store so bookmarks
/// sync across all of the user's devices automatically.
struct BookmarkService {
    private static let storeKey = "bookmarkedNoteIDs"

    static func loadBookmarks() -> Set<UUID> {
        guard let array = NSUbiquitousKeyValueStore.default.array(forKey: storeKey) as? [String] else {
            return []
        }
        return Set(array.compactMap { UUID(uuidString: $0) })
    }

    static func save(bookmarks: Set<UUID>) {
        let array = bookmarks.map(\.uuidString)
        NSUbiquitousKeyValueStore.default.set(array, forKey: storeKey)
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    static func toggle(id: UUID, in bookmarks: inout Set<UUID>) {
        if bookmarks.contains(id) {
            bookmarks.remove(id)
        } else {
            bookmarks.insert(id)
        }
        save(bookmarks: bookmarks)
    }
}
