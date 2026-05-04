import Testing
@testable import mcpnotes_mac

@Suite("SidebarMode")
struct SidebarModeTests {

    @Test func hasExactlyFourCases() {
        #expect(SidebarMode.allCases.count == 4)
    }

    @Test func symbolNamesMatchExpected() {
        #expect(SidebarMode.all.symbolName == "note.text")
        #expect(SidebarMode.byTag.symbolName == "tag")
        #expect(SidebarMode.favorites.symbolName == "bookmark")
        #expect(SidebarMode.search.symbolName == "magnifyingglass")
    }

    @Test func allSymbolNamesAreNonEmpty() {
        for mode in SidebarMode.allCases {
            #expect(!mode.symbolName.isEmpty)
        }
    }

    @Test func rawValuesAreDistinct() {
        let rawValues = SidebarMode.allCases.map(\.rawValue)
        #expect(Set(rawValues).count == SidebarMode.allCases.count)
    }
}
