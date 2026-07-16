import SwiftUI

/// Display mode of the notes sidebar list.
public enum SidebarMode: Int, CaseIterable, Hashable {
    case all
    case byTag
    case favorites
    case search

    public var symbolName: String {
        switch self {
        case .all:       "note.text"
        case .byTag:     "tag"
        case .favorites: "bookmark"
        case .search:    "magnifyingglass"
        }
    }

    public var label: LocalizedStringKey {
        switch self {
        case .all:       "All Notes"
        case .byTag:     "By Tags"
        case .favorites: "Favorites"
        case .search:    "Search"
        }
    }
}
