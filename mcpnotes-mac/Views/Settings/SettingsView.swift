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
            Tab("Import", systemImage: "square.and.arrow.down") {
                ImportSettingsView()
            }
        }
        .frame(width: 480, height: 360)
    }
}
