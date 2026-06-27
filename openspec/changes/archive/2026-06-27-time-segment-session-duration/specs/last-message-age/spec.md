## MODIFIED Requirements

### Requirement: Last-message timestamp with cache-freshness-colored delta

The statusline SHALL render, as the time segment in `build_left`, a PRIMARY text optionally followed by a parenthesized delta `(Δ)`. The primary text SHALL be the session duration sourced from the stdin JSON field `cost.total_duration_ms` (the upstream wall-clock milliseconds since the session started, idle included): the value SHALL be divided to whole seconds and formatted by the existing `fmt_dur` helper (for example `1H15m`, `40m`, `2D3H`) and rendered dim. This session-duration primary SHALL replace the absolute last-prompt `HH:MM` clock as the segment's leading text.

WHEN `cost.total_duration_ms` is absent or non-numeric, the primary text SHALL fall back to the last user prompt's `HH:MM` clock label, preserving backward compatibility with hosts that do not provide the field.

The delta `(Δ)` SHALL be appended only when the elapsed time since the last user prompt is at least 60 seconds, and SHALL represent how long ago that prompt occurred. The delta's COLOR SHALL signal prompt-cache freshness using the existing two-tier idle thresholds (`LASTMSG_WARN` and `LASTMSG_STALE`): dim (`DM`) while the default prompt cache is still warm, yellow (`YL`) once `LASTMSG_WARN` has elapsed, and red (`RD`) once `LASTMSG_STALE` has elapsed. A delta under one minute SHALL be hidden, leaving the bare primary text. WHEN the elapsed time is negative (clock skew between the prompt-writing host and the render), it SHALL be clamped to 0 and the delta SHALL be hidden. Both the primary text and the delta SHALL be honest elapsed time; only the delta color asserts the cache read.

This requirement MUST be implemented inside `build_left` in `lib/render.sh`, which reads the per-session last-message file. That file is the one external string that does NOT pass through `parse_input`, so `build_left` MUST re-strip the same control-character set (C0 `0x01`–`0x1F`, DEL `0x7F`, and the 2-byte UTF-8 C1 block `0xC2 0x80`–`0x9F`) and re-apply the 256-codepoint cap via glob, keeping that filter in sync with `parse_input`'s `select(. >= 32 and (. < 127 or . > 159))`; the implementation MUST NOT introduce `set -e`, MUST keep `LC_ALL=C` byte-counting intact for `vis_width`, and MUST remain bash 3.2 compatible.

#### Scenario: Session duration is the primary text and replaces the clock

- **WHEN** `cost.total_duration_ms` is present and numeric
- **THEN** the time segment's primary text SHALL be `fmt_dur(cost.total_duration_ms / 1000)` rendered dim, and the absolute last-prompt `HH:MM` clock SHALL NOT appear

##### Example: duration primary with a colored delta

- **GIVEN** `cost.total_duration_ms = 4521000` and the last-message file holds `09:30 <epoch>` with `now - epoch = 600` and `LASTMSG_WARN = 300`
- **WHEN** `build_left` renders the time segment
- **THEN** the output is the dim `1H15m` followed by a yellow `(10m)`, and `09:30` does not appear

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

### Requirement: Cross-day timestamps include the date

WHEN the primary text is the `HH:MM` clock fallback (that is, `cost.total_duration_ms` is unavailable) AND the last prompt's local calendar day differs from the current local calendar day, the displayed clock MUST include the date so that a prior-day time is not misread as today; when the last prompt occurred on the current local calendar day, a bare `HH:MM` MUST be shown. The session-duration primary text is an elapsed span, not a wall clock, and MUST NOT receive a date prefix.

The calendar-day comparison MUST be computed from the local calendar date of `lm_epoch` versus the local calendar date of `now` (a difference in local calendar day, NOT a fixed 24-hour age threshold), so a prompt at `23:50` followed by a render at `00:10` the next day is treated as cross-day even though the age is 20 minutes. The date-prefixed form MUST NOT change the delta computation or its color tier; only the clock text gains a date prefix.

#### Scenario: Session-duration primary is never date-prefixed

- **WHEN** `cost.total_duration_ms` is present (the primary text is the session duration) and the last prompt occurred on a prior local calendar day
- **THEN** the primary text SHALL remain the bare `fmt_dur` duration with its colored delta, and SHALL NOT gain a `MM-DD` date prefix

##### Example: cross-day prompt with duration primary

- **GIVEN** `cost.total_duration_ms = 180000000` (2D2H) and `lm_epoch` is `2026-06-14 12:00` local while `now` is `2026-06-15 14:00` local (26 hours earlier)
- **WHEN** `build_left` renders the time segment
- **THEN** the primary text is the dim `2D2H` followed by a red `(1D2H)` delta, with no date prefix

#### Scenario: Same local calendar day shows bare HH:MM under clock fallback

- **WHEN** the primary text is the clock fallback and `lm_epoch` and `now` fall on the same local calendar day
- **THEN** the clock text SHALL be the bare `HH:MM` form (optionally followed by the colored delta)

##### Example: same-day prompt 10 minutes ago

- **GIVEN** `cost.total_duration_ms` is absent, today is `2026-06-15`, `lm_epoch` is `2026-06-15 14:00` local, and `now` is `2026-06-15 14:10` local
- **WHEN** `build_left` renders the time segment
- **THEN** the clock text is `14:00` (bare, no date) and the delta is `(10m)`

#### Scenario: Different local calendar day prefixes the date under clock fallback

- **WHEN** the primary text is the clock fallback and `lm_epoch` and `now` fall on different local calendar days
- **THEN** the clock text SHALL include the date prefix (for example `MM-DD HH:MM`) ahead of the time, so the prior-day prompt is not read as today

##### Example: prompt 26 hours ago carries the date

- **GIVEN** `cost.total_duration_ms` is absent, `now` is `2026-06-15 14:00` local and `lm_epoch` is `2026-06-14 12:00` local (26 hours earlier)
- **WHEN** `build_left` renders the time segment
- **THEN** the clock text is the date-prefixed form `06-14 12:00` (NOT a bare `12:00`) and the delta is the red `(1D2H)` form because `lm_age >= LASTMSG_STALE`

##### Example: cross-midnight prompt under one hour

- **GIVEN** `cost.total_duration_ms` is absent, `lm_epoch` is `2026-06-14 23:50` local and `now` is `2026-06-15 00:10` local
- **WHEN** `build_left` renders the time segment
- **THEN** the clock text is date-prefixed `06-14 23:50` because the local calendar day differs, and the delta `(20m)` is yellow because `lm_age = 1200 >= LASTMSG_WARN`

#### Scenario: Legacy file format without a numeric epoch is shown verbatim under clock fallback

- **WHEN** `cost.total_duration_ms` is unavailable and the last-message file holds an older format whose trailing token is not an all-digit epoch (so `lm_epoch` resolves empty)
- **THEN** the stored string SHALL be displayed verbatim as the dim primary text with no delta and no added date prefix, preserving backward compatibility for sessions whose file has not yet been rewritten
