# CONTEXT.md

## Scope
- This directory contains operational shell scripts for building `xcodecli`.

## Why This Exists
- These scripts are the destructive edge of the repository.
- The CLI code can be changed safely in isolation, but script changes affect build outputs and version injection.

## Key Files
- [scripts/build-swift.sh](./build-swift.sh): local reproducible Swift build entrypoint; version/build-channel injection happens via edits to [Sources/XcodeCLICore/Shared/Version.swift](../Sources/XcodeCLICore/Shared/Version.swift).

## Local Rules
- Destructive steps come last.
- `.tmp/` is an operational scratch area, not part of the context tree and not a documentation source of truth.

## Change Coupling
- If [scripts/build-swift.sh](./build-swift.sh) changes version or output behavior, review:
  - [README.md](../README.md)
  - [docs/agent-quickstart.md](../docs/agent-quickstart.md)

## Verification Notes
- For build changes, run the script locally rather than assuming documentation is enough.

## Child Contexts
- None.
