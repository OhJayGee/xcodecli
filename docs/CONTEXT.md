# CONTEXT.md

## Scope
- This directory contains canonical long-form user documentation.
- It explains workflows that are too detailed for `CLAUDE.md` or `AGENTS.md`.

## Why This Exists
- The repository needs two different document types:
  - user-facing explanations and procedures
  - AI/operator-facing rules
- This directory owns the former. Context documents should point here rather than duplicate long procedures.

## Key Files
- `authorization-troubleshooting.md` / `authorization-troubleshooting.kr.md`: MCP authorization reuse, same-session behavior, and repeated-prompt recovery (English / Korean).

## Local Rules
- Keep these docs user-facing and procedural.
- Do not copy long CLI help text into these files; summarize and show representative commands.
- If CLI examples change, update the docs that teach those workflows rather than leaving the README as the only source.
- Version examples in this directory should track the current release line.

## Change Coupling
- CLI onboarding changes should review:
  - [README.md](../README.md)

## Canonical Source Notes
- [README.md](../README.md) is the repository landing page and the canonical first-time walkthrough.
- Context documents should link to README, not replace it.

## Verification Notes
- When commands or version strings change, scan docs for stale examples.
- Prefer small, representative command examples over exhaustive duplication of help output.
