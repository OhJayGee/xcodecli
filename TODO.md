# TODO — Security & Code-Quality Findings

Generated from an adversarial security review and a code-quality review of `main` (working tree clean). Severity ordering reflects exploitability and user impact, not effort.

Note: a previously suggested bug at `Sources/xcodecli/MCPConfigCommand.swift:240` (`appendingPathComponent` "double join") was investigated and is **a false positive** — `found` is the PATH directory, so the join correctly produces `<dir>/<argv0>`. Do not change.

---

## Critical

### [x] 1. Auto-updater executes `build.sh` from a downloaded tarball with no integrity check [RESOLVED in Phase A — auto-updater removed (commit dfb72ab)]
- **Location:** `internal/update/update.go:228-265`; same pattern in `scripts/install.sh`
- **Resolution:** Auto-updater module, install.sh, and Go tree all deleted. Distribution is now `git pull && swift build -c release`.

### [x] 2. Tar extraction has no path-traversal guard [RESOLVED in Phase A — auto-updater removed (commit dfb72ab); also Phase C deleted Go tree (commit 292ad90)]
- **Location:** `internal/update/update.go:238-244`
- **Resolution:** No tarball is downloaded or extracted anywhere in the surviving codebase.

---

## High

### [x] 3. `release_homebrew.sh` derives the formula SHA from a re-download [RESOLVED in Phase A — release_homebrew.sh deleted (commit 70472c6)]
- **Location:** `scripts/release_homebrew.sh:179`
- **Resolution:** All Homebrew/release scripts removed; no formula generation path remains.

### [x] 4. `build-swift.sh` does racy in-place `sed` of `Version.swift` with a predictable tmp backup [RESOLVED in Phase A — build-swift.sh trimmed of version-sync hook (commit 70472c6)]
- **Location:** `scripts/build-swift.sh:20-32`
- **Resolution:** The version-sync invocation was removed. `build-swift.sh` no longer mutates `Version.swift` via in-place `sed`; the `VERSION` env var is consumed directly by Swift sources at build time.

### [x] 5. Agent socket TOCTOU + chmod-after-listen window [RESOLVED in Phase D1 (commit d5d67f7)]
- **Location:** `internal/agent/server.go:75-85` (Go tree gone); analogous Swift fix in `Sources/XcodeCLICore/Agent/AgentServer.swift`
- **Resolution:** Support directory verified owned by current user with mode 0700 before bind; `umask(0o077)` wraps socket creation; post-bind `lstat` validates the file is a real socket owned by us with mode 0600. Pinned by `Tests/XcodeCLICoreTests/AgentServerSocketTests.swift`.

### [x] 6. Swift `Updater.runDirectUpdate` is a literal stub [RESOLVED in Phase A — Updater.swift deleted (commit dfb72ab)]
- **Location:** `Sources/XcodeCLICore/Update/Updater.swift:95-99`
- **Resolution:** Updater module entirely removed.

### [ ] 7. `AgentServer` does not hold the pooled session lock across MCP client calls (Swift)
- **Location:** `Sources/XcodeCLICore/Agent/AgentServer.swift:220-255`
- **Issue:** Two concurrent requests on the same `SessionKey` can both pass `getOrCreateClient` and call `client.listTools()` / `client.callTool()` concurrently, interleaving JSON-RPC reads on the shared connection. Go held `pooled.mu` for the entire `fn(client)` duration; Swift does not.
- **Fix:** Acquire a per-session lock that wraps `getOrCreateClient` + the RPC + `finishSession`.

---

## Medium

### [ ] 8. Swift `MCPClient.readEnvelope` reads one byte at a time
- **Location:** `Sources/XcodeCLICore/MCP/MCPClient.swift:246-270`
- **Issue:** `readData(ofLength: 1)` in a tight loop — thousands of syscalls per tool response (file reads, build logs). Real perf regression.
- **Fix:** Buffered read (`FileHandle.bytes`, `DispatchIO`, or read-and-split-on-newline).

### [ ] 9. Swift `AgentClient.doRPC` has no timeout fallback when `req.timeoutMS` is nil/0
- **Location:** `Sources/XcodeCLICore/Agent/AgentClient.swift:155-173`
- **Issue:** A wedged agent causes an indefinite hang; `Darwin.read()` never returns.
- **Fix:** Apply a default `SO_RCVTIMEO`/`SO_SNDTIMEO` or wrap reads in a `Task` with a timeout.

### [ ] 10. Swift `MCPClient` stderr capture polls and is never awaited at shutdown
- **Location:** `Sources/XcodeCLICore/MCP/MCPClient.swift:87-98`
- **Issue:** Detached `Task` reads `availableData` in `while true`; can spin between partial reads, and stderr captured after termination is lost because the task is never awaited before `close`/`abort`.
- **Fix:** Use `pipe.fileHandleForReading.bytes` and structured concurrency; await the task during shutdown.

### [x] 11. Missing `--` separator before MCP server name for `claude` and `gemini` [RESOLVED — file deleted in Phase C (commit 292ad90)]
- **Location:** `cmd/xcodecli/mcp_config.go:178-195`
- **Resolution:** Go CLI tree deleted. The Swift `MCPConfigCommand` already passes the name as a discrete argument list element, so the original UX bug does not apply to the surviving implementation.

### [x] 12. `release_homebrew.sh --dry-run` keeps the auto-cloned tap dir with the GitHub token embedded in `.git/config` [RESOLVED in Phase A — release_homebrew.sh deleted (commit 70472c6)]
- **Location:** `scripts/release_homebrew.sh:165-169, 205-217`
- **Resolution:** Script no longer exists.

---

## Low / Structural

### [x] 13. Version constants are duplicated and only sync-checked by the Swift build [RESOLVED in Phase C — Go tree deleted (commit 292ad90)]
- **Location:** `cmd/xcodecli/version.go:5`, `Sources/XcodeCLICore/Shared/Version.swift:2`
- **Resolution:** Only `Sources/XcodeCLICore/Shared/Version.swift` remains; there is no second source of truth to drift from.

### [x] 14. Status warnings/next-steps are derived in two places [RESOLVED in Phase C — Go tree deleted (commit 292ad90)]
- **Location:** `cmd/xcodecli/main.go:413-459`
- **Resolution:** The Go-side duplicate is gone. Swift `formatAgentStatus` consumes the structured `Warnings`/`NextSteps` fields without re-derivation.

### [x] 15. Architecture intent (Go vs Swift) is undocumented [RESOLVED in Phase C — Go tree deleted (commit 292ad90)]
- **Location:** none — should be in `CLAUDE.md` or new `docs/architecture.md`
- **Resolution:** Only the Swift implementation remains. `CLAUDE.md` now states: "`xcodecli` is a Swift package; the build entrypoint is `./scripts/build-swift.sh`."

### [x] 16. `internal/agent/server.go` has zero unit tests [RESOLVED — file deleted in Phase C (commit 292ad90)]
- **Location:** `internal/agent/server.go`
- **Resolution:** File no longer exists. The Swift `AgentServer` is now covered by `AgentServerSocketTests`, `AgentSessionPoolTests`, and other suites.

### [x] 17. `agent_guide.go` is 1326 lines flat [RESOLVED — file deleted in Phase B (commit 974b19b) and Phase C (commit 292ad90)]
- **Location:** `cmd/xcodecli/agent_guide.go`
- **Resolution:** `agent guide` command and supporting code removed from both Swift and Go trees.

### [x] 18. `classifyGuideIntent` confidence floor of 0.35 makes the score uninformative [RESOLVED — code deleted in Phase B (commit 974b19b)]
- **Location:** `cmd/xcodecli/agent_guide.go:323-335, 392`
- **Resolution:** Intent classification removed with the `agent guide` subcommand.

### [x] 19. Swift `UpdaterTests` hardcode `/usr/local/bin/brew` [RESOLVED in Phase A — UpdaterTests.swift deleted (commit dfb72ab)]
- **Location:** `Tests/XcodeCLICoreTests/UpdaterTests.swift:164, 175, 188, ...`
- **Resolution:** Updater test file removed alongside the updater.

### [x] 20. `agent status` field labels differ between Go and Swift text output [RESOLVED in Phase C — Go tree deleted (commit 292ad90)]
- **Location:** Go `cmd/xcodecli/main.go:398`; Swift `Sources/xcodecli/AgentCommand.swift:204`
- **Resolution:** No second implementation to drift against.

### [x] 21. `agent/server.go:runSessionOp` leaks the operation goroutine on context cancellation [RESOLVED — file deleted in Phase C (commit 292ad90)]
- **Location:** `internal/agent/server.go:224-241`
- **Resolution:** Go file no longer exists.

### [x] 22. Test stub helper restores globals without locking [RESOLVED — file deleted in Phase C (commit 292ad90)]
- **Location:** `cmd/xcodecli/main_test.go:1073-1143`
- **Resolution:** Go test file no longer exists.

### [ ] 23. Swift `AgentClient.uninstall` reports cleanup errors confusingly
- **Location:** `Sources/XcodeCLICore/Agent/AgentClient.swift:88-109`
- **Issue:** Continues removing files after errors and joins all messages — bootout failures appear in the final error even when file removal succeeded.
- **Fix:** Return on first real removal failure; ignore `Stop`/`Bootout` errors.

### [~] 24. Minor cleanups (group)
- **Duplicate dedupe helpers** [RESOLVED — Go side deleted in Phase C]: `cmd/xcodecli/mcp_config.go:576-590` and `internal/agent/status_warnings.go:36-50` no longer exist.
- **Bespoke UUID v4** [RESOLVED — file deleted in Phase C]: `internal/bridge/session.go:106-119` no longer exists.
- **`tool inspect` round-trip:** [keep] `Sources/xcodecli/ToolCommand.swift` still lists every tool to find one — fine since the bridge tool set is fixed, but worth a comment so future readers don't think it's a bug.
- **`doctor` smoke-test branch ordering:** [keep — verify in Swift] Defensive `smokeCtx.Err()` check in the Swift doctor smoke runner remains worth confirming.

---

## Codex findings (post-simplification sweep)

### [x] M3. `release_homebrew.sh` invokes `swift build --disable-sandbox` [RESOLVED in Phase A — script deleted (commit 70472c6)]
- **Location:** `scripts/release_homebrew.sh`
- **Resolution:** Script removed; no surviving caller passes `--disable-sandbox` to `swift build`.

### [x] M5/M6. AgentServer accepts any local connection without peer authentication [RESOLVED in Phase D2 (commit c40c689)]
- **Location:** `Sources/XcodeCLICore/Agent/AgentServer.swift`
- **Resolution:** Each accepted fd has its peer effective UID looked up via `getpeereid` and is closed if it does not match `getuid()`. Lookup failures fail closed. Same-UID end-to-end ping covered by `AgentServerSocketTests`.

### [x] M7/M8. AgentServer reads request frames with no size or time bound [RESOLVED in Phase D3 (commit d8cf642)]
- **Location:** `Sources/XcodeCLICore/Agent/AgentServer.swift`
- **Resolution:** Request frame capped at 1 MiB; per-read `SO_RCVTIMEO` of 5 s applied to accepted fds (mirrors the `AgentClient` pattern). Oversized payload returns an error response and closes the connection. Pinned by `AgentServerSocketTests.oversizedRequestRejected`.

---

## Suggested execution order (remaining items)

1. **#7** — Swift session-lock parity gap.
2. **#9** — agent client default timeout.
3. **#8, #10** — MCP client perf and shutdown cleanliness.
4. **#23** — uninstall error reporting.
5. **#24** — `tool inspect` comment + doctor smoke-test defensive check.
