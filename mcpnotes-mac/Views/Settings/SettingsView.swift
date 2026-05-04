import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gear") {
                GeneralSettingsView()
            }
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

// MARK: - General

private struct GeneralSettingsView: View {
    @AppStorage("appLanguage") private var appLanguage = "system"
    @AppStorage("colorScheme") private var colorSchemePreference = "auto"

    var body: some View {
        Form {
            Picker("Language", selection: $appLanguage) {
                Text("System Default").tag("system")
                Text("English").tag("en")
                Text("Русский").tag("ru")
                Text("Українська").tag("uk")
                Text("Deutsch").tag("de")
            }

            Picker("Appearance", selection: $colorSchemePreference) {
                Text("Auto").tag("auto")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - RAG

private struct RAGSettingsView: View {
    @AppStorage("ragEnabled") private var ragEnabled = false

    var body: some View {
        Form {
            Section {
                Toggle("Enable RAG", isOn: $ragEnabled)
                Text("Semantic search indexes your notes locally and exposes them via MCP.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private var mcpConfigSnippet: String {
        """
        {
          "mcpServers": {
            "mcpnotes": {
              "command": "/path/to/MCPNotesServer"
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
