import MCPNotesCore
import SwiftUI

struct MCPSettingsView: View {
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
