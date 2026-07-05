import Testing
@testable import XcodeCLICore

/// Pins the timeout-fallback policy that `AgentClient.doRPC` applies to its
/// `SO_RCVTIMEO`/`SO_SNDTIMEO` `setsockopt` calls. The previous behaviour was
/// "no timeoutMS in the request -> no socket timeout at all", which left the
/// caller wedged forever on a frozen agent. The contract is now: every RPC
/// gets a finite timeout, falling back to `defaultAgentRPCTimeoutMS` when no
/// override is supplied.
@Suite("AgentClient RPC timeout policy")
struct AgentClientTimeoutTests {

    @Test("nil request timeout falls back to the default")
    func nilFallsBackToDefault() {
        #expect(effectiveAgentRPCTimeoutMS(requested: nil) == defaultAgentRPCTimeoutMS)
    }

    @Test("zero request timeout falls back to the default")
    func zeroFallsBackToDefault() {
        // Zero is treated as "no override", not as "infinite". This matters
        // because Darwin's setsockopt(SO_RCVTIMEO, {0,0}) actually means "no
        // timeout" — the original bug.
        #expect(effectiveAgentRPCTimeoutMS(requested: 0) == defaultAgentRPCTimeoutMS)
    }

    @Test("negative request timeout falls back to the default")
    func negativeFallsBackToDefault() {
        // A programmer error elsewhere (e.g. adjustTimeout subtracting too
        // much elapsed time) must not result in setsockopt receiving a
        // garbage value.
        #expect(effectiveAgentRPCTimeoutMS(requested: -42) == defaultAgentRPCTimeoutMS)
    }

    @Test("positive request timeout passes through unchanged")
    func positivePassesThrough() {
        #expect(effectiveAgentRPCTimeoutMS(requested: 5_000) == 5_000)
        #expect(effectiveAgentRPCTimeoutMS(requested: 1) == 1)
        #expect(effectiveAgentRPCTimeoutMS(requested: 1_800_000) == 1_800_000)
    }

    @Test("backend MCP timeout leaves room for agent response")
    func backendTimeoutLeavesResponseMargin() {
        #expect(effectiveMCPBackendTimeoutMS(requested: nil) == nil)
        #expect(effectiveMCPBackendTimeoutMS(requested: 0) == nil)
        #expect(effectiveMCPBackendTimeoutMS(requested: 100) == 50)
        #expect(effectiveMCPBackendTimeoutMS(requested: 20_000) == 19_000)
        #expect(effectiveMCPBackendTimeoutMS(requested: 1_800_000) == 1_799_000)
    }

    @Test("default is finite and at least one second")
    func defaultIsSane() {
        // A regression that drops the constant to 0 or to a sub-second value
        // would silently re-introduce the original wedge / cause spurious
        // timeouts; pin both ends.
        #expect(defaultAgentRPCTimeoutMS >= 1_000)
        #expect(defaultAgentRPCTimeoutMS <= 5 * 60 * 1_000) // sanity upper bound
    }
}
