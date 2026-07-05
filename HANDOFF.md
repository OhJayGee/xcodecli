# Handoff

## Repository State

- Branch: `simplify-and-harden`
- HEAD before this handoff cleanup: `55f49e8` (`Apply tool-specific timeouts in MCP serve`)
- Upstream: `origin/simplify-and-harden`
- Remote: `https://github.com/OhJayGee/xcodecli`
- The previous handoff drift has been resolved in README: clone instructions now use the current origin, and the active maintenance line is `v1.2.x`.

## Architecture

`xcodecli` is a Swift 6/macOS 15+ CLI around Xcode's `xcrun mcpbridge`.

The default long-lived MCP path is:

```text
Claude Code / Codex / Agy
  -> stable installed xcodecli serve
  -> per-user xcodecli LaunchAgent
  -> pooled xcrun mcpbridge
  -> Xcode MCP tools
```

The LaunchAgent keeps the Xcode-facing backend stable across client restarts. Authorization reuse depends on preserving the pooled session key:

```text
{XcodePID, SessionID, DeveloperDir}
```

Changing that key, changing the registered binary path, changing the binary signature, or stopping/uninstalling the agent can trigger another Xcode approval prompt.

## Recent Changes

Commit `315b809` fixed pooled MCP proxy reliability:

- Replaced the buffered `FileHandle.readData(ofLength:)` path with POSIX partial reads so short MCP responses return while `mcpbridge` keeps stdout open.
- Repaired MCP client aliases such as `xcodecli mcp codex`.
- Made same-session concurrency coverage deterministic.
- Made release channel selection compile-time based without editing `Version.swift`.

Commit `856c197` completed issue #24 and related hardening:

- `doctor` bounds the `mcpbridge` smoke test to two seconds and reports a specific timeout.
- `SystemProcessRunner` is cancellation-aware and terminates a running child.
- Subprocesses with no supplied stdin use `FileHandle.nullDevice`, preventing installers such as `claude mcp` from inheriting stdin and hanging.
- Agent socket writes use `MSG_NOSIGNAL`, preventing process termination when a client disconnects before reading a response.
- `tool inspect` documents why a `tools/list` round trip is intentional.
- `TODO.md` was renamed to `SECURITY_REVIEW.md`; all findings are resolved or closed by design.
- README setup was added for Claude Code, Codex, and Agy.

Commit `82644d5` documents that release binaries copied from this external-volume checkout should be re-signed:

```bash
codesign -f -s - ~/.local/bin/xcodecli
```

Commit `fe4ba5d` hardened Xcode MCP bridge timeout handling:

- `MCPClient` uses timeout-aware POSIX reads and aborts `xcrun mcpbridge` child processes after connect/init failure.
- `AgentServer` applies a backend timeout margin so it can return a structured timeout error before the caller's socket timeout.
- Timed-out backend sessions are discarded instead of returned to the pool.
- Timeout diagnostics now identify the MCP method and backend wait budget.

Commit `55f49e8` applied tool-specific timeouts to `xcodecli serve`:

- `tools/list` uses the 60 second list timeout.
- `tools/call` uses the same tool-specific timeout policy as the CLI convenience commands.
- Long-running build and test tools keep the 30 minute client-facing timeout while the backend gets a one second response margin.

## Client Setup

Claude Code:

```bash
xcodecli mcp claude --install
claude mcp get xcodecli
```

Codex:

```bash
xcodecli mcp codex --install
codex mcp get xcodecli
```

Agy reads global MCP configuration from:

```text
~/.gemini/config/mcp_config.json
```

The README contains the required `mcpServers.xcodecli` entry using an absolute stable binary path and `["serve"]` arguments.

## Verification

Run after the timeout fixes:

```bash
swift test
```

Result: passed, 203 tests in 29 suites.

Production binary verification:

```bash
scripts/build-swift.sh /Users/olv/.local/bin/xcodecli
codesign -f -s - /Users/olv/.local/bin/xcodecli
xcodecli tools list --timeout 20
xcodecli tool call XcodeListWindows --json '{}' --timeout 20
```

The LaunchAgent was restarted with `xcodecli agent stop`; `agent status --json` then reported a running agent with matching binary path and no warnings. A direct stdio MCP probe against `/Users/olv/.local/bin/xcodecli serve` succeeded for `initialize` and `tools/list`.

## Remaining Work

No security-review, issue #24, timeout-hardening, live MCP verification, or README drift work remains from this handoff.

If Claude Code still reports a stale `Connected / tools fetch failed` state, restart Claude Code so it drops cached MCP health and starts the newly installed `xcodecli serve` binary.
