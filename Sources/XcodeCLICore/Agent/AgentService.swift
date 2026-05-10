import Foundation

/// Default idle timeout for agent sessions (24 hours, in nanoseconds for Go compatibility).
public let defaultAgentIdleTimeoutNs: Int64 = 24 * 60 * 60 * 1_000_000_000

/// Default idle timeout for agent sessions (24 hours).
public let defaultAgentIdleTimeout: TimeInterval = 24 * 60 * 60

/// Default per-call socket timeout (read and write) when an `AgentRequest`
/// does not specify `timeoutMS`. A wedged agent must not produce an
/// indefinite hang in `Darwin.read`/`Darwin.write`; 30s is a generous bound
/// that covers any realistic in-bridge tool call while still failing fast on
/// a stuck process.
public let defaultAgentRPCTimeoutMS: Int64 = 30 * 1000

/// Resolve the effective per-call agent RPC timeout for `setsockopt`.
///
/// - `nil` and `0` are treated identically: "no override", so the default is
///   used. Neither value means "wait forever" — the whole point of this fix
///   is that the previous "no timeoutMS = no socket timeout" path wedged the
///   caller when the agent stopped responding.
/// - Negative values (a programmer error) are also coerced to the default.
/// - Positive values pass through unchanged so callers like
///   `buildAgentRequest` keep their existing semantics.
public func effectiveAgentRPCTimeoutMS(requested: Int64?) -> Int64 {
    guard let value = requested, value > 0 else { return defaultAgentRPCTimeoutMS }
    return value
}

/// Agent RPC request for communicating with the LaunchAgent.
public struct AgentRequest: Codable, Sendable {
    public var method: String
    public var toolName: String?
    public var arguments: [String: JSONValue]?
    public var timeoutMS: Int64?
    public var xcodePID: String?
    public var sessionID: String?
    public var developerDir: String?
    public var debug: Bool?

    public init(
        method: String,
        toolName: String? = nil,
        arguments: [String: JSONValue]? = nil,
        timeoutMS: Int64? = nil,
        xcodePID: String? = nil,
        sessionID: String? = nil,
        developerDir: String? = nil,
        debug: Bool? = nil
    ) {
        self.method = method
        self.toolName = toolName
        self.arguments = arguments
        self.timeoutMS = timeoutMS
        self.xcodePID = xcodePID
        self.sessionID = sessionID
        self.developerDir = developerDir
        self.debug = debug
    }
}

/// Runtime status from the agent server (wire format, Go-compatible).
public struct RuntimeStatus: Codable, Sendable {
    public var pid: Int
    public var idleTimeoutMs: Int64
    public var backendSessions: Int

    public init(pid: Int = 0, idleTimeoutMs: Int64 = 0, backendSessions: Int = 0) {
        self.pid = pid
        self.idleTimeoutMs = idleTimeoutMs
        self.backendSessions = backendSessions
    }
}

/// Agent RPC response.
public struct AgentResponse: Codable, Sendable {
    public var tools: [JSONValue]?
    public var result: [String: JSONValue]?
    public var isError: Bool?
    public var error: String?
    public var status: RuntimeStatus?

    public init(
        tools: [JSONValue]? = nil,
        result: [String: JSONValue]? = nil,
        isError: Bool? = nil,
        error: String? = nil,
        status: RuntimeStatus? = nil
    ) {
        self.tools = tools
        self.result = result
        self.isError = isError
        self.error = error
        self.status = status
    }
}

/// Build an agent request from resolved environment options.
public func buildAgentRequest(
    env: [String: String],
    effective: EnvOptions,
    timeout: TimeInterval,
    debug: Bool
) -> AgentRequest {
    AgentRequest(
        method: "",
        timeoutMS: Int64(timeout * 1000),
        xcodePID: effective.xcodePID.isEmpty ? nil : effective.xcodePID,
        sessionID: effective.sessionID.isEmpty ? nil : effective.sessionID,
        developerDir: env["DEVELOPER_DIR"],
        debug: debug
    )
}
