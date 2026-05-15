import Foundation
import Testing
@testable import mcpnotes_mac

@Suite("EditorViewModel")
@MainActor
struct EditorViewModelTests {

    func makeNote(body: String = "Hello", tags: [String] = ["a", "b"]) -> Note {
        Note(
            id: UUID(),
            filename: "Test",
            tags: tags,
            body: body,
            fileURL: URL(fileURLWithPath: "/tmp/test.md")
        )
    }

    // MARK: load

    @Test func loadSetsBodyTagsAndNoteID() {
        let vm = EditorViewModel()
        let note = makeNote()
        vm.load(note: note)
        #expect(vm.body == "Hello")
        #expect(vm.tags == ["a", "b"])
        #expect(vm.noteID == note.id)
    }

    @Test func loadReplacesExistingState() {
        let vm = EditorViewModel()
        vm.load(note: makeNote(body: "Old", tags: ["old"]))
        let next = makeNote(body: "New", tags: ["new"])
        vm.load(note: next)
        #expect(vm.body == "New")
        #expect(vm.tags == ["new"])
        #expect(vm.noteID == next.id)
    }

    @Test func loadWithEmptyTagsAndBody() {
        let vm = EditorViewModel()
        vm.load(note: makeNote(body: "", tags: []))
        #expect(vm.body == "")
        #expect(vm.tags.isEmpty)
    }

    // MARK: flushAutosave

    @Test func flushCallsOnSaveImmediately() {
        let vm = EditorViewModel()
        var savedBody: String?
        var savedTags: [String]?
        vm.onSave = { body, tags in savedBody = body; savedTags = tags }
        vm.body = "Draft"
        vm.tags = ["draft"]
        vm.flushAutosave()
        #expect(savedBody == "Draft")
        #expect(savedTags == ["draft"])
    }

    @Test func flushWithoutOnSaveDoesNotCrash() {
        let vm = EditorViewModel()
        vm.body = "anything"
        vm.flushAutosave() // onSave is nil — must not crash
    }

    // MARK: scheduleAutosave

    @Test func scheduleAutosaveDoesNotCallOnSaveImmediately() async {
        let vm = EditorViewModel()
        var called = false
        vm.onSave = { _, _ in called = true }
        vm.scheduleAutosave()
        #expect(called == false)
    }

    @Test func scheduleAutosaveCallsOnSaveAfterDelay() async throws {
        let vm = EditorViewModel()
        var callCount = 0
        vm.onSave = { _, _ in callCount += 1 }
        vm.body = "Content"
        vm.scheduleAutosave()
        try await Task.sleep(for: .milliseconds(1300))
        #expect(callCount == 1)
    }

    @Test func scheduleAutosaveDebouncesRapidCalls() async throws {
        let vm = EditorViewModel()
        var callCount = 0
        vm.onSave = { _, _ in callCount += 1 }
        vm.scheduleAutosave()
        vm.scheduleAutosave()
        vm.scheduleAutosave()
        try await Task.sleep(for: .milliseconds(1300))
        #expect(callCount == 1)
    }

    @Test func loadCancelsPendingAutosave() async throws {
        let vm = EditorViewModel()
        var callCount = 0
        vm.onSave = { _, _ in callCount += 1 }
        vm.scheduleAutosave()
        vm.load(note: makeNote())
        try await Task.sleep(for: .milliseconds(1300))
        #expect(callCount == 0)
    }
}
