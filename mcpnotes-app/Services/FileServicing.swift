import Foundation

public protocol FileServicing {
    func loadAllNotes() async throws -> [Note]
    func saveNote(_ note: Note) throws
    func createNote(baseName: String) throws -> Note
    func deleteNote(_ note: Note) throws
    func renameNote(_ note: Note, to newName: String) throws -> Note
}
