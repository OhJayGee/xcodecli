import Foundation
import XcodeCLICore

/// Resolve bridge options from the given environment dictionary and optional overrides.
func resolveOptions(
    env: [String: String],
    xcodePID: String?,
    sessionID: String?
) throws -> (EnvOptions, ResolvedOptions) {
    let sessionPath = (try? PathUtilities.sessionFilePath()) ?? ""
    let overrides = EnvOptions(
        xcodePID: xcodePID ?? "",
        sessionID: sessionID ?? ""
    )
    let resolved = try SessionManager.resolve(
        baseEnv: env, overrides: overrides, sessionPath: sessionPath
    )
    let effective = resolved.envOptions
    try effective.validate()
    return (effective, resolved)
}

/// Build an AgentRequest by resolving session options from the given environment dictionary.
func buildBridgeRequest(
    env: [String: String],
    xcodePID: String?,
    sessionID: String?,
    timeout: TimeInterval,
    debug: Bool
) throws -> AgentRequest {
    let (effective, _) = try resolveOptions(env: env, xcodePID: xcodePID, sessionID: sessionID)
    let bridgeEnv = EnvOptions.applyOverrides(baseEnv: env, opts: effective)
    return buildAgentRequest(env: bridgeEnv, effective: effective, timeout: timeout, debug: debug)
}

/// Convenience overload that reads the process environment automatically.
func buildBridgeRequest(
    xcodePID: String?,
    sessionID: String?,
    timeout: TimeInterval,
    debug: Bool
) throws -> AgentRequest {
    try buildBridgeRequest(
        env: envDictionary(),
        xcodePID: xcodePID, sessionID: sessionID,
        timeout: timeout, debug: debug
    )
}

/// Return a copy of an agent request with a concrete per-request timeout.
func agentRequestWithTimeout(_ request: AgentRequest, timeout: TimeInterval) -> AgentRequest {
    var adjusted = request
    adjusted.timeoutMS = Int64(timeout * 1000)
    return adjusted
}

/// Timeout policy for the `tools/list` request used by `xcodecli serve`.
func serveListToolsRequest(base request: AgentRequest) -> AgentRequest {
    agentRequestWithTimeout(request, timeout: TimeoutPolicy.readTimeout)
}

/// Timeout policy for a proxied `tools/call` request used by `xcodecli serve`.
func serveToolCallRequest(base request: AgentRequest, toolName: String) -> AgentRequest {
    agentRequestWithTimeout(
        request,
        timeout: TimeoutPolicy.defaultToolCallTimeout(toolName: toolName)
    )
}
