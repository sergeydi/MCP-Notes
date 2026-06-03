import MCPNotesCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("RAG", systemImage: "brain") {
                RAGSettingsView()
            }
            Tab("MCP", systemImage: "terminal") {
                MCPSettingsView()
            }
            Tab("Storage", systemImage: "externaldrive.badge.icloud") {
                StorageSettingsView()
            }
        }
        .frame(width: 480, height: 320)
    }
}

// MARK: - RAG

private struct RAGSettingsView: View {
    @Environment(NoteStore.self) private var store
    @AppStorage("ragEnabled") private var ragEnabled = false

    var body: some View {
        Form {
            Section {
                Toggle("Enable RAG", isOn: $ragEnabled)
                Text("Semantic search indexes your notes locally and exposes them via MCP.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Indexer Status") {
                indexerStatusRow
                if store.indexWasRecovered {
                    Label("Search index was corrupted and has been rebuilt from scratch.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
                Button("Re-index All Notes") {
                    Task { await store.reindexAll() }
                }
                .disabled(store.indexingState.isIndexing)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var indexerStatusRow: some View {
        switch store.indexingState {
        case .idle:
            Label("Not started", systemImage: "clock")
                .foregroundStyle(.secondary)
        case .indexing(let indexed, let total):
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.75)
                Text("Indexing notes… \(indexed) / \(total)")
                    .foregroundStyle(.secondary)
            }
        case .ready(let count):
            Label(String(localized: "\(count) notes indexed"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Label("Indexing failed", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}

// MARK: - MCP

private struct MCPSettingsView: View {
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Text(mcpConfigSnippet)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(6)
                    .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                HStack(alignment: .top) {
                    Text("The path above reflects the current app location and must be updated if you reinstall or move the app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(mcpConfigSnippet, forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .animation(.easeInOut(duration: 0.2), value: copied)
                }
            } header: {
                Text("MCP Configuration")
            }
        }
        .formStyle(.grouped)
    }

    private var mcpConfigSnippet: String {
        let serverPath = Bundle.main.bundlePath + "/Contents/MacOS/mcpnotes-server"
        let notesPath = FileService.notesDirectoryURL.path(percentEncoded: false)
        return """
        {
          "mcpServers": {
            "mcpnotes": {
              "command": "\(serverPath)",
              "env": {
                "MCPNOTES_DIR": "\(notesPath)"
              }
            }
          }
        }
        """
    }
}

// MARK: - Storage

private struct StorageSettingsView: View {
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
