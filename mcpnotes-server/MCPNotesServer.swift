import Foundation
import MCP

@main
struct MCPNotesServer {
    static func main() async {
        do {
            try await run()
        } catch {
            fputs("MCPNotesServer fatal error: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run() async throws {
        let server = Server(
            name: "mcpnotes",
            version: "1.0.0",
            capabilities: Server.Capabilities(tools: .init())
        )

        let service = NotesService()
        let searcher = RAGSearcher()

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: NotesToolHandler.tools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            try await NotesToolHandler.call(params, service: service, searcher: searcher)
        }

        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }
}
