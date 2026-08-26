import Testing
@testable import mcpnotes_app

@Suite("SidebarMode")
struct SidebarModeTests {

    @Test func hasExactlyThreeCases() {
        #expect(SidebarMode.allCases.count == 3)
    }

    @Test func symbolNamesMatchExpected() {
        #expect(SidebarMode.all.symbolName == "note.text")
        #expect(SidebarMode.byTag.symbolName == "tag")
        #expect(SidebarMode.favorites.symbolName == "bookmark")
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
