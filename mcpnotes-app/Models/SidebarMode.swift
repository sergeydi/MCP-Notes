import SwiftUI

/// Display mode of the notes sidebar list.
public enum SidebarMode: Int, CaseIterable, Hashable {
    case all
    case byTag
    case favorites

    public var symbolName: String {
        switch self {
        case .all:       "note.text"
        case .byTag:     "tag"
        case .favorites: "bookmark"
        }
    }

    public var label: LocalizedStringKey {
        switch self {
        case .all:       "All Notes"
        case .byTag:     "By Tags"
        case .favorites: "Favorites"
        }
    }
}
