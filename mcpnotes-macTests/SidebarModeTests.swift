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

    @Test(arguments: SidebarMode.allCases)
    func symbolNameIsNonEmpty(mode: SidebarMode) {
        #expect(mode.symbolName.isEmpty == false)
    }

    @Test func rawValuesAreDistinct() {
        let rawValues = SidebarMode.allCases.map(\.rawValue)
        #expect(Set(rawValues).count == SidebarMode.allCases.count)
    }
}
