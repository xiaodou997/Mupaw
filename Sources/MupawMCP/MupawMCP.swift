import Foundation
import MCP

@main
struct MupawMCP {
    static func main() async throws {
        let router = MupawToolRouter()
        let server = Server(
            name: "Mupaw",
            version: "0.1.0-dev",
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: MupawToolCatalog.tools)
        }
        await server.withMethodHandler(CallTool.self) { parameters in
            await router.handle(name: parameters.name, arguments: parameters.arguments)
        }

        let transport = StdioTransport()
        try await server.start(transport: transport)

        do {
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(3_600))
            }
        } catch is CancellationError {
            // Normal process cancellation.
        }
        await server.stop()
    }
}
