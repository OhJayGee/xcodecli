import ArgumentParser
import Foundation
import XcodeCLICore

struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run a stdio MCP server backed by the LaunchAgent runtime"
    )

    @Option(name: .customLong("xcode-pid"), help: "Override MCP_XCODE_PID")
    var xcodePID: String?

    @Option(name: .customLong("session-id"), help: "Override MCP_XCODE_SESSION_ID")
    var sessionID: String?

    @Flag(name: .customLong("debug"), help: "Emit server debug logs to stderr")
    var debug = false

    func run() async throws {
        let env = envDictionary()
        let sessionPath = (try? PathUtilities.sessionFilePath()) ?? ""

        let overrides = EnvOptions(
            xcodePID: xcodePID ?? "",
            sessionID: sessionID ?? ""
        )

        let resolved = try SessionManager.resolve(
            baseEnv: env, overrides: overrides, sessionPath: sessionPath
        )

        if debug {
            logResolvedSession(resolved, to: FileHandle.standardError)
        }

        let effective = resolved.envOptions
        let bridgeEnv = EnvOptions.applyOverrides(baseEnv: env, opts: effective)

        // Base agent request for tool operations via LaunchAgent. Each handler
        // below applies the timeout that matches the MCP operation.
        let agentRequest = buildAgentRequest(
            env: bridgeEnv, effective: effective, timeout: 0, debug: debug
        )

        let handler = MCPServerHandler(
            listTools: {
                try await AgentClient.listTools(
                    request: serveListToolsRequest(base: agentRequest)
                )
            },
            callTool: { name, arguments in
                try await AgentClient.callTool(
                    request: serveToolCallRequest(base: agentRequest, toolName: name),
                    name: name,
                    arguments: arguments
                )
            }
        )

        try await serveMCPStdio(
            config: MCPServerConfig(debug: debug),
            handler: handler
        )
    }
}
