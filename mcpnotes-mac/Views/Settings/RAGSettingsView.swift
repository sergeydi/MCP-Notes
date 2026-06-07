import MCPNotesCore
import SwiftUI

struct RAGSettingsView: View {
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
