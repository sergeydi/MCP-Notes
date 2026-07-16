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

    private var snippet: String {
        switch selectedClient {
        case .claudeDesktop:
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
        case .claudeCode:
            return "claude mcp add mcpnotes --env MCPNOTES_DIR=\"\(notesPath)\" -- \(serverPath)"
        case .chatGPTDesktop, .codex:
            return """
            [mcp_servers.mcpnotes]
            command = "\(serverPath)"

            [mcp_servers.mcpnotes.env]
            MCPNOTES_DIR = "\(notesPath)"
            """
        case .openCode:
            return """
            {
              "$schema": "https://opencode.ai/config.json",
              "mcp": {
                "servers": {
                  "mcpnotes": {
                    "type": "local",
                    "command": ["\(serverPath)"],
                    "environment": {
                      "MCPNOTES_DIR": "\(notesPath)"
                    }
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
            "Add this to your Claude Desktop config file, then restart Claude Desktop:\n~/Library/Application Support/Claude/claude_desktop_config.json"
        case .claudeCode:
            "Run this command in your terminal to register the server:"
        case .chatGPTDesktop:
            "Enable Developer Mode (Settings → Security and login), then add a server via the gear menu → MCP servers → Add server (STDIO transport). ChatGPT Desktop shares its MCP configuration with Codex CLI, so you can also add this directly to ~/.codex/config.toml:"
        case .codex:
            "Add this to ~/.codex/config.toml:"
        case .openCode:
            "Add this to opencode.json (project) or ~/.config/opencode/opencode.json (global):"
        }
    }
}
