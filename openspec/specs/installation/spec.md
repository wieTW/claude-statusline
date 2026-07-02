# installation Specification

## Purpose

The installation capability defines how the statusline is wired into Claude Code and kept updating while the session is idle. It owns the idempotent jq-merge installer — which preserves every other setting, backs the file up first, and refuses to touch invalid JSON — and the refreshInterval cadence: its default of 60, its argument/environment override, its zero-omit semantics, and its interaction with the burn-projection sampling gate.

## Requirements

### Requirement: Idempotent settings merge

The installer SHALL wire the statusline into `~/.claude/settings.json` by MERGING a `statusLine` object into the existing settings, never replacing the whole file. It SHALL read the entire settings document and reassign only the `statusLine` key as `(existing statusLine // {}) + {type:"command", command:<abs path>, refreshInterval:<n>}`, so that every other top-level key (permissions, hooks, model, …) and any pre-existing `statusLine` sub-key (such as `padding` or `hideVimModeIndicator`) is preserved. When no settings file exists, the installer SHALL create a minimal file containing only the `statusLine` object. The installer SHALL be idempotent — safe to run repeatedly with the same result.

#### Scenario: Merge preserves unrelated settings

- **WHEN** `~/.claude/settings.json` already contains other keys (for example `model` and `permissions`) and a `statusLine` with a `padding` sub-key, and the installer runs
- **THEN** `model`, `permissions`, and `statusLine.padding` SHALL be unchanged, while `statusLine.command` (and `refreshInterval`) SHALL be set to the installed values

##### Example: existing keys survive

- GIVEN settings `{"model":"opus","permissions":{...},"statusLine":{"type":"command","command":"/old","padding":2}}`
- WHEN the installer runs with a 30s interval
- THEN the result keeps `model`, `permissions`, and `statusLine.padding=2`, and sets `statusLine.command` to the absolute script path and `statusLine.refreshInterval=30`

#### Scenario: Fresh create when no settings file exists

- **WHEN** `~/.claude/settings.json` does not exist and the installer runs
- **THEN** it SHALL create the file containing only a `statusLine` object with `type`, `command`, and (by default) `refreshInterval`

<!-- @trace
source: statusline-install-and-refresh
updated: 2026-07-02
code:
  - install.sh
  - README.md
-->

---
### Requirement: Backup and invalid-JSON refusal

Before modifying an existing settings file, the installer SHALL validate that the file is valid JSON and SHALL refuse to touch it (exit non-zero, leaving it byte-for-byte unchanged) when it is not, so a hand-broken settings file is never overwritten or further corrupted. When the file is valid, the installer SHALL first copy it to a timestamped backup (`settings.json.bak.<timestamp>`) and SHALL write the new contents atomically (temp file + `mv`).

#### Scenario: Invalid JSON is left untouched

- **WHEN** the existing settings file is not valid JSON
- **THEN** the installer SHALL print a refusal message, make no change to the file, and exit non-zero

##### Example: broken file preserved

- GIVEN a settings file whose contents are `{not json`
- WHEN the installer runs against it
- THEN the file still contains `{not json` afterward and the installer exits non-zero

#### Scenario: A backup is written before a valid change

- **WHEN** the existing settings file is valid JSON and the installer applies a change
- **THEN** a `settings.json.bak.<timestamp>` copy SHALL exist afterward and the live file SHALL be updated atomically

<!-- @trace
source: statusline-install-and-refresh
updated: 2026-07-02
code:
  - install.sh
-->

---
### Requirement: Dependency check and absolute-path resolution

The installer SHALL require `jq` and SHALL fail with a clear message and install hint when it is absent (the statusline itself parses its stdin with jq, so jq is already a hard dependency). It SHALL resolve the statusline script's ABSOLUTE path from the installer's own location, SHALL fail clearly if the script is not found beside it, and SHALL ensure the script is executable (`chmod +x`). The path SHALL be written such that spaces or special characters in it are safe (passed via `jq --arg`).

#### Scenario: The written command is an executable absolute path

- **WHEN** the installer completes successfully
- **THEN** `statusLine.command` SHALL be an absolute path to `statusline-command.sh` that exists and is executable

#### Scenario: Missing jq fails clearly

- **WHEN** `jq` is not on PATH
- **THEN** the installer SHALL print an error naming jq (with an install hint) and exit non-zero without modifying any settings

<!-- @trace
source: statusline-install-and-refresh
updated: 2026-07-02
code:
  - install.sh
-->

---
### Requirement: Refresh interval default, override, and omit semantics

The installer SHALL set `statusLine.refreshInterval` to 60 by default. The interval SHALL be overridable via the first positional argument or the `REFRESH_INTERVAL` environment variable, and a non-integer / negative value SHALL be rejected with an error. A value of `0` SHALL mean "no refresh timer": on a fresh create the `refreshInterval` key SHALL be omitted, and on a merge into an existing file any stale `refreshInterval` key SHALL be deleted, so `0` truly reverts to event-only updates rather than leaving an old value behind.

#### Scenario: Custom interval via argument

- **WHEN** the installer is run with a positional interval argument of 30
- **THEN** `statusLine.refreshInterval` SHALL be 30

#### Scenario: Zero omits and deletes the key

- **WHEN** the installer is run with `REFRESH_INTERVAL=0` against a settings file that already has a `refreshInterval`
- **THEN** the resulting `statusLine` SHALL NOT contain a `refreshInterval` key

##### Example: 0 deletes a stale key

- GIVEN an existing `statusLine` with `refreshInterval: 60`
- WHEN the installer runs with `REFRESH_INTERVAL=0`
- THEN the resulting `statusLine` has no `refreshInterval` key (event-only updates)

<!-- @trace
source: statusline-install-and-refresh
updated: 2026-07-02
code:
  - install.sh
  - README.md
-->

---
### Requirement: Refresh cadence interacts with burn-projection sampling

The `refreshInterval` cadence SHALL be understood as the sampling frequency that feeds the rate-limit burn-projection alarm. Because that alarm requires a minimum 60-second interval between the two slope samples (see the rate-burn-projection capability) and keeps only a small bounded series, a refresh interval far below that minimum would collapse the entire sample series into under a minute and silently disable the alarm. The default of 60 seconds SHALL be the value that simultaneously satisfies the line's whole-minute display granularity and keeps the burn sample series valid; intervals below roughly 15 seconds risk starving the alarm, and roughly 30 seconds is the safe lower bound without code changes.

#### Scenario: The default cadence keeps the burn alarm feedable

- **WHEN** `refreshInterval` is the default 60 seconds
- **THEN** consecutive renders SHALL produce burn samples spaced far enough apart to satisfy the burn-projection minimum-interval gate, so the alarm remains able to fire

<!-- @trace
source: statusline-install-and-refresh
updated: 2026-07-02
code:
  - install.sh
  - README.md
  - lib/collect.sh
-->
