import MCPNotesCore
import SwiftUI

struct StorageSettingsView: View {
    @Environment(NoteStore.self) private var store
    @State private var notesPath = FileService.notesDirectoryURL.path(percentEncoded: false)
    @State private var isCustomDirectory = FileService.customNotesDirectoryURL != nil

    var body: some View {
        Form {
            Section("Notes Folder") {
                Text(notesPath)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Change Folder…") { chooseFolder() }
                    if isCustomDirectory {
                        Button("Reset to Default", role: .destructive) { resetToDefault() }
                    }
                }

                Button("Reveal in Finder") {
                    NSWorkspace.shared.open(FileService.notesDirectoryURL)
                }
            }

            Section("iCloud Sync") {
                if isCustomDirectory {
                    Label("Custom folder — sync depends on the chosen location.", systemImage: "folder")
                        .foregroundStyle(.secondary)
                } else {
                    Label("Sync is managed automatically by iCloud.", systemImage: "checkmark.icloud")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = String(localized: "Choose a folder to store your notes")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FileService.setCustomNotesDirectory(url)
            notesPath = url.path(percentEncoded: false)
            isCustomDirectory = true
            Task { await store.switchDirectory() }
        } catch {
            // TODO: surface error to user
        }
    }

    private func resetToDefault() {
        FileService.clearCustomNotesDirectory()
        notesPath = FileService.notesDirectoryURL.path(percentEncoded: false)
        isCustomDirectory = false
        Task { await store.switchDirectory() }
    }
}
