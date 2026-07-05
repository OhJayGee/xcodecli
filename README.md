# xcodecli

`xcodecli` is a macOS CLI wrapper around `xcrun mcpbridge` for local use.

## Install

Requires macOS 15+ with Xcode (Swift toolchain).

```bash
git clone https://github.com/OhJayGee/xcodecli.git
cd xcodecli
swift build -c release
cp .build/release/xcodecli ~/.local/bin/   # or any directory on $PATH
codesign -f -s - ~/.local/bin/xcodecli     # resign to prevent macOS SIGKILL (exit code 137)
```

To update later: `git pull && swift build -c release && cp .build/release/xcodecli ~/.local/bin/ && codesign -f -s - ~/.local/bin/xcodecli`.

For MCP authorization reuse, same-session behavior, and repeated-prompt recovery, see:
- English: `docs/authorization-troubleshooting.md`
- Korean: `docs/authorization-troubleshooting.kr.md`

## Build from source

```bash
swift build
swift test
./scripts/build-swift.sh .tmp/xcodecli
```

Force a dev-channel release build:

```bash
BUILD_CHANNEL=dev ./scripts/build-swift.sh .tmp/xcodecli
```

## Usage

Running `xcodecli` with no arguments prints help. Use `bridge` for raw passthrough to `xcrun mcpbridge`, or `serve` when an MCP client should talk to `xcodecli` directly while reusing the LaunchAgent-backed runtime.

In the default long-lived proxy mode, an MCP client launches the stable installed
`xcodecli serve` binary. Each `serve` process forwards tool requests to a per-user
LaunchAgent, and that agent owns the reusable `xcrun mcpbridge` process. Client
restarts or upgrades therefore do not replace the Xcode-facing backend while the
same `{XcodePID, SessionID, DeveloperDir}` key remains active. Xcode authorization
is still session-scoped rather than a permanent trust grant for the executable, so
changing that key or stopping the agent can trigger another approval prompt.

```bash
./xcodecli
./xcodecli version
./xcodecli --xcode-pid 12345
./xcodecli bridge --session-id 11111111-1111-1111-1111-111111111111
./xcodecli serve --session-id 11111111-1111-1111-1111-111111111111
```

Run environment diagnostics:

```bash
./xcodecli doctor
./xcodecli doctor --json
MCP_XCODE_PID=12345 ./xcodecli doctor --json
```

Generate MCP registration commands for supported clients:

```bash
./xcodecli mcp codex
./xcodecli mcp claude
./xcodecli mcp gemini
./xcodecli mcp codex --install
./xcodecli mcp claude --install --json
```

### Claude Code

Register the stable installed binary and verify the entry:

```bash
xcodecli mcp claude --install
claude mcp get xcodecli
```

### Codex

Register the stable installed binary and verify the entry:

```bash
xcodecli mcp codex --install
codex mcp get xcodecli
```

### Agy

Agy discovers global MCP servers from `~/.gemini/config/mcp_config.json`.
Merge this entry into that file, preserving any existing `mcpServers`. The
`command` must be the absolute path reported by `command -v xcodecli`; `~` is
not expanded because Agy launches the command directly.

```json
{
  "mcpServers": {
    "xcodecli": {
      "command": "/Users/YOU/.local/bin/xcodecli",
      "args": ["serve"]
    }
  }
}
```

Restart Agy after changing the file. Agy builds without an `mcp` subcommand
must be configured this way rather than through `xcodecli mcp ... --install`.

Notes:
- `mcp config` targets `xcodecli serve` by default so MCP clients reuse the LaunchAgent-backed pooled runtime.
- Use `--mode bridge` if you explicitly want raw `xcodecli bridge` passthrough instead.
- `xcodecli mcp codex|claude|gemini` are shorthand aliases for `xcodecli mcp config --client ...`.
- `mcp config` warns when the current `xcodecli` executable path looks unstable for long-lived MCP registration (for example `.build`, `Cellar`, `/tmp`, or external-volume paths).
- Add `--strict-stable-path` if you want `mcp config` to fail instead of warn when the current executable path looks unstable.
- Output-only mode prints a ready-to-paste registration command and does **not** create or reuse `xcodecli`'s persistent session file.
- The first actual `serve` run creates or reuses `xcodecli`'s persistent session ID at runtime if you did not pass `--session-id`.
- `--install` registers the MCP server with the target client CLI.
- Gemini defaults to `--scope user` so it does not write `.gemini/settings.json` into the current project unless you explicitly choose `--scope project`.
- For long-lived MCP usage, register a **stable xcodecli path** (for example `/opt/homebrew/bin/xcodecli` or `~/.local/bin/xcodecli`). Switching between different binaries or checkout paths forces the LaunchAgent to recycle its backend session, which can surface fresh Xcode authorization prompts.
- Avoid changing `MCP_XCODE_PID` or `DEVELOPER_DIR` between runs unless you intentionally want a separate pooled session.
- In practice, `xcodecli` can usually avoid repeated Xcode authorization only while you keep using the **same pooled session key**. That key is `{XcodePID, SessionID, DeveloperDir}`.
- By default, `xcodecli` reuses a persistent session ID from `~/Library/Application Support/xcodecli/session-id`; keep using that default if you want repeated calls from different shells to stay on the same pooled session.
- Passing a different `--session-id`, changing `MCP_XCODE_PID`, changing `DEVELOPER_DIR`, alternating between different installed binaries, or forcing `agent stop` / `agent uninstall` can all push the next request onto a fresh backend session, which may trigger a fresh Xcode authorization prompt.
- Treat Xcode authorization as **best-effort reusable within one pooled session**, not as a global one-time machine-wide grant across every possible session configuration.

Operational rules for minimizing re-authorization:

1. Register one **stable installed** `xcodecli` path with your MCP client and keep using it.
2. Prefer the default agent mode (`xcodecli serve` via `mcp config`) over raw bridge mode for long-lived work.
3. Reuse the default persistent session ID; do not pass `--session-id` unless you intentionally want a new backend session.
4. Avoid setting `MCP_XCODE_PID` or `DEVELOPER_DIR` unless you need to target a different Xcode instance/toolchain on purpose.
5. Avoid `agent stop` / `agent uninstall` except for troubleshooting, because they discard the warm backend session.
6. If you need to verify whether you are still on the same pooled session, compare `agent status --json` and avoid changing the three session-key inputs above.

For a focused FAQ and troubleshooting checklist, see:
- English: `docs/authorization-troubleshooting.md`
- Korean: `docs/authorization-troubleshooting.kr.md`

Quick authorization FAQ:
- One Xcode approval should be treated as reusable only within one pooled session, not as a machine-wide forever grant.
- "Same session" means the same `{XcodePID, SessionID, DeveloperDir}`, not merely the same terminal window.
- New shells can still reuse the same warm backend session if those three values stay unchanged.
- A different `--session-id`, different `MCP_XCODE_PID`, different `DEVELOPER_DIR`, a different registered binary path, or an `agent stop` / `agent uninstall` can all lead to a fresh backend session and a fresh prompt.

Quick authorization reuse check:

```bash
# Same pooled session (repeat in another shell if you want)
./xcodecli tool call XcodeListWindows --json '{}'
./xcodecli tool call XcodeRead --json '{"tabIdentifier":"windowtab1","filePath":"Project/App.swift","limit":5}'

# Deliberate fresh-session comparison
./xcodecli tool call XcodeListWindows --session-id "$(uuidgen | tr '[:upper:]' '[:lower:]')" --json '{}'
```

Expected interpretation:
- the first two commands are the normal "same pooled session" path if you keep the same default session ID, Xcode instance, and `DEVELOPER_DIR`
- the last command should be treated as a fresh backend-session test and may surface a fresh Xcode authorization prompt

List tools through the MCP bridge:

```bash
./xcodecli tools list
./xcodecli tools list --json --timeout 60
```

Inspect a single tool before calling it:

```bash
./xcodecli tool inspect XcodeListWindows
./xcodecli tool inspect XcodeListWindows --json --timeout 60
```

Call a single tool with JSON arguments:

```bash
./xcodecli tool call XcodeListWindows --json '{}'
./xcodecli tool call BuildProject --timeout 1800 --json @/tmp/payload.json
printf '{}' | ./xcodecli tool call XcodeListWindows --json-stdin
```

Inspect the LaunchAgent used by `tools` commands:

```bash
./xcodecli agent status
./xcodecli agent status --json
./xcodecli agent stop
./xcodecli agent uninstall
```

## LLM agent workflow

```bash
./xcodecli tools list
./xcodecli tool inspect XcodeListWindows --json
./xcodecli tool call XcodeListWindows --json '{}'
./xcodecli tool call BuildProject --json '{"tabIdentifier":"<tabIdentifier from above>"}'
```

Many Xcode MCP tools require a `tabIdentifier`; calling `XcodeListWindows` first surfaces the live identifiers you can pass to subsequent tools.

## Agent onboarding

- Quick rules for first-time agents: `AGENTS.md`

## Security review

- Completed security and code-quality findings: `SECURITY_REVIEW.md`

## Git workflow

- `main`: stable baseline branch
- `codex/*`: implementation branches for agent-driven changes
- Open pull requests from `codex/*` into `main`


## Versioning strategy

The project now uses stable semantic versioning tags with the following release policy:

- `v1.0.1`, `v1.0.2`, ...: patch releases for bug fixes, CI/test hardening, documentation corrections, and internal refactors that do not intentionally expand the public CLI surface.
- `v1.1.0`, `v1.2.0`, ...: minor releases for new commands, new flags, new output modes, default-behavior expansions, or materially new LaunchAgent / MCP capabilities.
- Breaking CLI behavior is avoided when possible. Any unavoidable breaking change should ship in a new major release and must be called out explicitly in `CHANGELOG.md` and the GitHub Release notes.
- Tags should remain annotated `vMAJOR.MINOR.PATCH` tags, and GitHub Releases should continue to use generated notes unless a release needs hand-written upgrade guidance.
- The active maintenance line is `v1.2.x`. Small fixes should prefer the next patch tag on that line before opening a new minor series.

## Notes

- `--xcode-pid` overrides `MCP_XCODE_PID`.
- `--session-id` overrides `MCP_XCODE_SESSION_ID`.
- If no `--session-id` flag or `MCP_XCODE_SESSION_ID` environment variable is provided, `xcodecli` automatically creates and reuses a persistent session ID at `~/Library/Application Support/xcodecli/session-id`.
- In bridge mode, **stdout is protocol-only**. Wrapper logs and diagnostics go to stderr.
- Convenience commands (`tools list`, `tool inspect`, `tool call`) automatically install and bootstrap a per-user LaunchAgent at `~/Library/LaunchAgents/io.oozoofrog.xcodecli.plist`.
- `--timeout` is the **request timeout**. It includes first-use LaunchAgent startup, `mcpbridge` session initialization, and any auth prompts.
- The default **mcpbridge session idle timeout** is `24h`. It controls how long pooled `mcpbridge` sessions stay alive while idle.
- Active requests are **not** interrupted by the `mcpbridge session idle timeout`.
- `doctor` will warn when the registered LaunchAgent binary path is relative, missing, or differs from the current binary because those drifts are common causes of LaunchAgent bootstrap failures and unexpected re-authorization churn.
- `agent status` surfaces the same stale-registration warnings in human-readable mode so you can triage LaunchAgent drift without running the full doctor flow first.
- `doctor --json` now includes structured `recommendations` alongside raw checks so automation can act on common remediation paths directly.
- Default request timeouts are `60s` for `tools list` and `tool inspect`; `tool call` uses tool-specific defaults (`60s` list/read/search/log, `120s` update/write/refresh, `30m` build/test, `5m` fallback). `xcodecli serve` applies the same tool-specific defaults when proxying MCP `tools/call` requests through the LaunchAgent.
- `tool call` accepts exactly one payload source: inline `--json`, `--json @file`, or `--json-stdin`.
