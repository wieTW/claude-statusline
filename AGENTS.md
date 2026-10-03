<!-- SPECTRA:START v1.0.2 -->

# Spectra Instructions

This project uses Spectra for Spec-Driven Development(SDD). Specs live in `openspec/specs/`, change proposals in `openspec/changes/`.

## Use `$spectra-*` skills when:

- A discussion needs structure before coding → `$spectra-discuss`
- User wants to plan, propose, or design a change → `$spectra-propose`
- Tasks are ready to implement → `$spectra-apply`
- There's an in-progress change to continue → `$spectra-ingest`
- User asks about specs or how something works → `$spectra-ask`
- Implementation is done → `$spectra-archive`
- Commit only files related to a specific change → `$spectra-commit`

## Workflow

discuss? → propose → apply ⇄ ingest → archive

- `discuss` is optional — skip if requirements are clear
- Requirements change mid-work? `ingest` → resume `apply`

## Parked Changes

Changes can be parked（暫存）— temporarily moved out of `openspec/changes/`. Parked changes won't appear in `spectra list` but can be found with `spectra list --parked`. To restore: `spectra unpark <name>`. The `$spectra-apply` and `$spectra-ingest` skills handle parked changes automatically.

<!-- SPECTRA:END -->

# AGENTS.md

The full project guide is CLAUDE.md in this directory. Read it before changing anything. It is longer than the 32 KiB that Codex loads on its own, so open it with your tools. If this file and CLAUDE.md disagree, CLAUDE.md wins.

Two rules that protect live sessions (full text in CLAUDE.md):

- Never run `statusline-command.sh` or `subagent-status-line.sh` against the real `$HOME`. Use `scripts/sandbox-run.sh`.
- Change those scripts or `lib/` only in a git worktree under `.claude/worktrees/`, never in this checkout.
