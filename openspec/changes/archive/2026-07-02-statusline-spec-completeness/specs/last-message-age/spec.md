## MODIFIED Requirements

### Requirement: Last-message timestamp with cache-freshness-colored delta

The statusline SHALL render, as the time segment in `build_left`, a PRIMARY text optionally followed by a parenthesized delta `(Δ)`. The primary text SHALL be the session duration sourced from the stdin JSON field `cost.total_duration_ms` (the upstream wall-clock milliseconds since the session started, idle included), and this session duration SHALL be used as the primary text ONLY when `cost.total_duration_ms` is present AND numerically greater than zero — the code guard in `build_left` is `[ -n "$dur_ms" ] && [ "$dur_ms" -gt 0 ]`. When that guard passes, the value SHALL be divided to whole seconds and formatted by the existing `fmt_dur` helper (for example `1H15m`, `40m`, `2D3H`) and rendered dim, and this session-duration primary SHALL replace the absolute last-prompt `HH:MM` clock as the segment's leading text.

WHEN `cost.total_duration_ms` is absent, non-numeric, or not greater than zero (a zero or nonpositive value fails the `-gt 0` guard), the primary text SHALL fall back to the last user prompt's `HH:MM` clock label when a last-message file exists, preserving backward compatibility with hosts that do not provide the field. (When no last-message file exists either, the time segment is omitted entirely — that omission is stated normatively by the "Time segment omitted when no timestamp inputs are available" requirement below, which is the sole owner of the both-inputs-empty SHALL.)

The delta `(Δ)` SHALL be appended only when the elapsed time since the last user prompt is at least 60 seconds, and SHALL represent how long ago that prompt occurred. The delta's COLOR SHALL signal prompt-cache freshness using the existing two-tier idle thresholds (`LASTMSG_WARN` and `LASTMSG_STALE`): dim (`DM`) while the default prompt cache is still warm, yellow (`YL`) once `LASTMSG_WARN` has elapsed, and red (`RD`) once `LASTMSG_STALE` has elapsed. A delta under one minute SHALL be hidden, leaving the bare primary text. WHEN the elapsed time is negative (clock skew between the prompt-writing host and the render), it SHALL be clamped to 0 and the delta SHALL be hidden. Both the primary text and the delta SHALL be honest elapsed time; only the delta color asserts the cache read.

This requirement MUST be implemented inside `build_left` in `lib/render.sh`, which reads the per-session last-message file. That file is the one external string that does NOT pass through `parse_input`, so `build_left` MUST re-strip the same control-character set (C0 `0x01`–`0x1F`, DEL `0x7F`, and the 2-byte UTF-8 C1 block `0xC2 0x80`–`0x9F`), keeping that filter in sync with `parse_input`'s `select(. >= 32 and (. < 127 or . > 159))`; `_sanitize_field` re-applies a 256-BYTE cap via the `${REPLY:0:256}` substring (`LC_ALL=C` counts bytes), and the glob substitutions do the control-char strip only; the implementation MUST NOT introduce `set -e`, MUST keep `LC_ALL=C` byte-counting intact for `vis_width`, and MUST remain bash 3.2 compatible.

#### Scenario: Session duration is the primary text and replaces the clock

- **WHEN** `cost.total_duration_ms` is present AND numerically greater than zero (the `[ -n "$dur_ms" ] && [ "$dur_ms" -gt 0 ]` guard passes)
- **THEN** the time segment's primary text SHALL be `fmt_dur(cost.total_duration_ms / 1000)` rendered dim, and the absolute last-prompt `HH:MM` clock SHALL NOT appear

##### Example: duration primary with a colored delta

- **GIVEN** `cost.total_duration_ms = 4521000` and the last-message file holds `09:30 <epoch>` with `now - epoch = 600` and `LASTMSG_WARN = 300`
- **WHEN** `build_left` renders the time segment
- **THEN** the output is the dim `1H15m` followed by a yellow `(10m)`, and `09:30` does not appear

#### Scenario: Zero or nonpositive duration does not become the primary

- **WHEN** `cost.total_duration_ms` is present but is zero or a nonpositive value (so `[ "$dur_ms" -gt 0 ]` is false and `dur_str` stays empty)
- **THEN** the session duration SHALL NOT be used as the primary text; the primary text SHALL fall back to the `HH:MM` clock label when a last-message file exists (when no last-message file exists either, the time segment is omitted entirely, as owned by the "Time segment omitted when no timestamp inputs are available" requirement — not restated normatively here)

##### Example: zero duration falls back to the clock

- **GIVEN** `cost.total_duration_ms = 0` and the last-message file holds `09:30 <epoch>` with `now - epoch = 600`
- **WHEN** `build_left` renders the time segment
- **THEN** the output is the dim `09:30` followed by a yellow `(10m)`, exactly as if no `cost` field were present

#### Scenario: Clock fallback when the duration field is unavailable

- **WHEN** `cost.total_duration_ms` is absent from the stdin JSON or is non-numeric
- **THEN** the primary text SHALL be the last user prompt's dim `HH:MM` clock label, with the same `(Δ)` delta rules applied

##### Example: no cost field falls back to the clock

- **GIVEN** the stdin JSON has no `cost` object and the last-message file holds `09:30 <epoch>` with `now - epoch = 600`
- **WHEN** `build_left` renders the time segment
- **THEN** the output is the dim `09:30` followed by a yellow `(10m)`

#### Scenario: Last prompt within the same minute shows the bare primary

- **WHEN** the last prompt's stored epoch is less than 60 seconds before the current time `now`
- **THEN** the time segment SHALL render only the dim primary text (session duration, or the clock fallback) with no parenthesized delta

##### Example: sub-minute prompt with duration primary

- **GIVEN** `cost.total_duration_ms = 4521000` and the last-message file holds `14:05 <epoch>` where `now - epoch = 30`
- **WHEN** `build_left` renders the time segment
- **THEN** the output is the dim `1H15m` with no `(Δ)` suffix

#### Scenario: Delta color tiers preserved across the two cache windows

- **WHEN** the elapsed time `lm_age = now - lm_epoch` is at least 60 seconds
- **THEN** the delta SHALL be colored dim (`DM`) for `lm_age < LASTMSG_WARN`, yellow (`YL`) for `LASTMSG_WARN <= lm_age < LASTMSG_STALE`, and red (`RD`) for `lm_age >= LASTMSG_STALE`

##### Example: delta color boundaries with default thresholds

| lm_age (seconds) | tier          | delta color |
| ---------------- | ------------- | ----------- |
| 120              | warm          | DM (dim)    |
| 300              | default idle  | YL (yellow) |
| 1800             | default idle  | YL (yellow) |
| 3600             | extended idle | RD (red)    |
| 7200             | extended idle | RD (red)    |

- **GIVEN** `LASTMSG_WARN = 300` and `LASTMSG_STALE = 3600`
- **WHEN** each `lm_age` above is rendered
- **THEN** the delta uses the listed color while the primary text stays dim

#### Scenario: Negative elapsed time is clamped

- **WHEN** the stored epoch is greater than `now` (clock skew between the prompt-writing host and the render)
- **THEN** `lm_age` SHALL be clamped to 0, the delta SHALL be hidden, and the bare primary text SHALL be shown

## ADDED Requirements

### Requirement: Time segment omitted when no timestamp inputs are available

WHEN neither timestamp input is available — that is, `build_left` reads no per-session last-message string (`last_msg` empty because the `session_id` is empty or path-traversal-shaped, or no last-message file exists) AND `cost.total_duration_ms` produces no duration primary (`dur_str` empty because the field is absent, non-numeric, zero, or nonpositive) — the time segment SHALL be omitted entirely and SHALL NOT be appended to the left parts. The segment SHALL be emitted only when at least one of the two inputs is present, matching the code guard `[ -n "$last_msg" ] || [ -n "$dur_str" ]` in `build_left`. This omission MUST NOT introduce `set -e`, MUST remain bash 3.2 compatible, and MUST leave the remaining left segments and the right-align algorithm unaffected (an absent time segment is simply not present in `parts`).

#### Scenario: Both timestamp inputs absent omits the time segment

- **WHEN** no last-message file is available (so `last_msg` is empty) AND `cost.total_duration_ms` yields no positive duration (so `dur_str` is empty)
- **THEN** `build_left` SHALL append no time segment to `parts`, and the rendered line SHALL contain neither a duration nor a clock nor a `(Δ)` delta

##### Example: fresh session with no last-message file and no duration

- **GIVEN** the stdin JSON has no `cost` object and no last-message file exists for the current `session_id`
- **WHEN** `build_left` builds the left parts
- **THEN** no `seg_lastmsg` is appended and the time segment does not appear anywhere on the line

#### Scenario: Either input alone keeps the time segment present

- **WHEN** exactly one input is available — either a positive `cost.total_duration_ms` with no last-message file, or a last-message file with no positive duration
- **THEN** the time segment SHALL be emitted, showing the available primary text (the dim `fmt_dur` duration, or the dim `HH:MM` clock label), with the `(Δ)` delta applied only when its ≥60s rule is met

##### Example: duration present but no last-message file

- **GIVEN** `cost.total_duration_ms = 4521000` and no last-message file exists for the current `session_id`
- **WHEN** `build_left` renders the time segment
- **THEN** the output is the dim `1H15m` with no `(Δ)` suffix, and the time segment IS present on the line

<!-- @trace
source: statusline-spec-completeness
updated: 2026-07-02
code:
  - lib/render.sh
  - statusline-command.sh
-->

