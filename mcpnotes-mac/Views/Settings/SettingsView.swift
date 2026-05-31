import MCPNotesCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("RAG", systemImage: "brain") {
                RAGSettingsView()
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
                Button("Re-index All Notes") {
                    Task { await store.reindexAll() }
                }
                .disabled(store.indexingState.isIndexing)
            }

            if ragEnabled {
                Section("MCP Configuration") {
                    Text(mcpConfigSnippet)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(6)
                        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                }
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
    private var notesPath: String {
        FileService.notesDirectoryURL.path(percentEncoded: false)
    }

    var body: some View {
        Form {
            Section("Notes Folder") {
                Text(notesPath)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)

                Button("Reveal in Finder") {
                    NSWorkspace.shared.open(FileService.notesDirectoryURL)
                }
            }

            Section("iCloud Sync") {
                Label("Sync is managed automatically by iCloud.", systemImage: "checkmark.icloud")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
