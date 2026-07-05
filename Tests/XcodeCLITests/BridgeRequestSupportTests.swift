import Testing
import Foundation
@testable import xcodecli
import XcodeCLICore

@Suite("Bridge Request Support")
struct BridgeRequestSupportTests {
    @Test("buildBridgeRequest wires PID, sessionID, timeout, and debug into AgentRequest")
    func wiresFieldsCorrectly() throws {
        let request = try buildBridgeRequest(
            env: ["DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"],
            xcodePID: "12345",
            sessionID: "11111111-1111-1111-1111-111111111111",
            timeout: 90,
            debug: true
        )

        #expect(request.xcodePID == "12345")
        #expect(request.sessionID == "11111111-1111-1111-1111-111111111111")
        #expect(request.timeoutMS == 90_000)
        #expect(request.debug == true)
        #expect(request.developerDir == "/Applications/Xcode.app/Contents/Developer")
    }

    @Test("buildBridgeRequest leaves PID nil when not provided")
    func nilPID() throws {
        let request = try buildBridgeRequest(
            env: [:],
            xcodePID: nil,
            sessionID: "22222222-2222-2222-2222-222222222222",
            timeout: 60,
            debug: false
        )

        #expect(request.xcodePID == nil)
        #expect(request.sessionID == "22222222-2222-2222-2222-222222222222")
        #expect(request.debug == false)
    }

    @Test("buildBridgeRequest propagates validation error for invalid PID")
    func invalidPIDThrows() {
        #expect(throws: XcodeCLIError.self) {
            _ = try buildBridgeRequest(
                env: [:],
                xcodePID: "notANumber",
                sessionID: "33333333-3333-3333-3333-333333333333",
                timeout: 60,
                debug: false
            )
        }
    }

    @Test("buildBridgeRequest propagates validation error for invalid session ID")
    func invalidSessionIDThrows() {
        #expect(throws: XcodeCLIError.self) {
            _ = try buildBridgeRequest(
                env: [:],
                xcodePID: nil,
                sessionID: "not-a-valid-uuid",
                timeout: 60,
                debug: false
            )
        }
    }

    @Test("serve tools/list request uses read timeout and preserves session fields")
    func serveListToolsTimeout() {
        let base = AgentRequest(
            method: "",
            timeoutMS: 0,
            xcodePID: "12345",
            sessionID: "11111111-1111-1111-1111-111111111111",
            developerDir: "/Applications/Xcode.app/Contents/Developer",
            debug: true
        )

        let request = serveListToolsRequest(base: base)

        #expect(request.timeoutMS == 60_000)
        #expect(request.xcodePID == base.xcodePID)
        #expect(request.sessionID == base.sessionID)
        #expect(request.developerDir == base.developerDir)
        #expect(request.debug == base.debug)
    }

    @Test("serve tools/call request uses tool-specific timeout")
    func serveToolCallTimeout() {
        let base = AgentRequest(method: "", timeoutMS: 0)

        #expect(serveToolCallRequest(base: base, toolName: "RunAllTests").timeoutMS == 1_800_000)
        #expect(serveToolCallRequest(base: base, toolName: "RunSomeTests").timeoutMS == 1_800_000)
        #expect(serveToolCallRequest(base: base, toolName: "BuildProject").timeoutMS == 1_800_000)
        #expect(serveToolCallRequest(base: base, toolName: "XcodeRead").timeoutMS == 60_000)
        #expect(serveToolCallRequest(base: base, toolName: "XcodeWrite").timeoutMS == 120_000)
        #expect(serveToolCallRequest(base: base, toolName: "UnknownTool").timeoutMS == 300_000)
    }
}
