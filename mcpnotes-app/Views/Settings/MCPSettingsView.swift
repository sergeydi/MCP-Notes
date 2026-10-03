import SwiftUI

struct MCPSettingsView: View {
    @State private var copied = false
    @State private var selectedClient: MCPClient = .claudeDesktop

    var body: some View {
        Form {
            Section {
                Picker("Client", selection: $selectedClient) {
                    ForEach(MCPClient.allCases) { client in
                        Text(client.displayName).tag(client)
                    }
                }
            } header: {
                Text("MCP Client")
            }

            Section {
                Text(selectedClient.instructions)
                    .font(.callout)
                Text(snippet)
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
                        copySnippet()
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .animation(.easeInOut(duration: 0.2), value: copied)
                }
            } header: {
                Text("Setup")
            }
        }
        .formStyle(.grouped)
    }

    private func copySnippet() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private var serverPath: String {
        Bundle.main.bundlePath + "/Contents/MacOS/mcpnotes-server"
    }

    private var notesPath: String {
        FileService.notesDirectoryURL.path(percentEncoded: false)
    }

    /// Wraps a value in single quotes so paths with spaces (e.g. "MCP Notes.app") survive the shell as one argument.
    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Double-quoted string literal valid in both JSON and TOML basic strings (escapes backslash and quote).
    private func stringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }

    private var snippet: String {
        switch selectedClient {
        case .claudeDesktop:
            return """
            {
              "mcpServers": {
                "mcpnotes": {
                  "command": \(stringLiteral(serverPath)),
                  "env": {
                    "MCPNOTES_DIR": \(stringLiteral(notesPath))
                  }
                }
              }
            }
            """
        case .claudeCode:
            return "claude mcp add -s user mcpnotes --env MCPNOTES_DIR=\(shellQuoted(notesPath)) -- \(shellQuoted(serverPath))"
        case .chatGPTDesktop:
            return """
            [mcp_servers.mcpnotes]
            command = \(stringLiteral(serverPath))

            [mcp_servers.mcpnotes.env]
            MCPNOTES_DIR = \(stringLiteral(notesPath))
            """
        case .codex:
            return "codex mcp add mcpnotes --env MCPNOTES_DIR=\(shellQuoted(notesPath)) -- \(shellQuoted(serverPath))"
        case .openCode:
            return """
            {
              "$schema": "https://opencode.ai/config.json",
              "mcp": {
                "mcpnotes": {
                  "type": "local",
                  "command": [\(stringLiteral(serverPath))],
                  "enabled": true,
                  "environment": {
                    "MCPNOTES_DIR": \(stringLiteral(notesPath))
                  }
                }
              }
            }
            """
        }
    }
}

enum MCPClient: CaseIterable, Identifiable {
    case claudeDesktop
    case claudeCode
    case chatGPTDesktop
    case codex
    case openCode

    var id: Self { self }

    var displayName: String {
        switch self {
        case .claudeDesktop: "Claude Desktop"
        case .claudeCode: "Claude Code"
        case .chatGPTDesktop: "ChatGPT Desktop"
        case .codex: "Codex"
        case .openCode: "OpenCode"
        }
    }

    var instructions: String {
        switch self {
        case .claudeDesktop:
            "Add the \"mcpnotes\" entry to the \"mcpServers\" object in your Claude Desktop config file (keep any servers already there; create the file if it doesn't exist), then restart Claude Desktop:\n~/Library/Application Support/Claude/claude_desktop_config.json"
        case .claudeCode:
            "Run this command in your terminal to register the server for all projects (user scope):"
        case .chatGPTDesktop:
            "ChatGPT Desktop shares its MCP configuration with Codex. Add this to ~/.codex/config.toml (or pick Codex above for an equivalent terminal command), then restart ChatGPT Desktop:"
        case .codex:
            "Run this command in your terminal to register the server. It writes to ~/.codex/config.toml, which ChatGPT Desktop and the IDE extension share:"
        case .openCode:
            "Add this to opencode.json (project) or ~/.config/opencode/opencode.json (global):"
        }
    }
}
