## MODIFIED Requirements

### Requirement: Last-message timestamp with cache-freshness-colored delta

The statusline SHALL render, as the time segment in `build_left`, a PRIMARY text optionally followed by a parenthesized delta `(Δ)`. The primary text SHALL be selected by a THREE-LEVEL fallback chain evaluated in order:

1. WHEN `cost.total_api_duration_ms` is present AND numerically greater than zero (the code guard `[ -n "$api_ms" ] && [ "$api_ms" -gt 0 ]`), the primary SHALL be that value — the cumulative API-wait ("thinking") milliseconds Claude spent producing responses this session, EXCLUDING idle time and EXCLUDING local tool execution — divided to whole seconds and formatted by the `fmt_dur_s` helper.
2. OTHERWISE WHEN `cost.total_duration_ms` is present AND numerically greater than zero (the code guard `[ -n "$dur_ms" ] && [ "$dur_ms" -gt 0 ]`), the primary SHALL be the session wall-clock duration (idle included) divided to whole seconds and formatted by the existing `fmt_dur` helper (for example `1H15m`, `40m`, `2D3H`).
3. OTHERWISE the primary SHALL fall back to the last user prompt's `HH:MM` clock label when a last-message file exists, preserving backward compatibility with hosts that provide neither `cost` duration field. (When no last-message file exists either, the time segment is omitted entirely — that omission is owned normatively by the "Time segment omitted when no timestamp inputs are available" requirement below.)

Both formatted-duration primaries SHALL be rendered dim and SHALL replace the absolute last-prompt `HH:MM` clock as the segment's leading text. The API-time primary and the session-duration primary SHALL both land in the same `dur_str` variable in `build_left`, so the downstream segment-emit guard, the `(Δ)` delta logic, and the clock-fallback branch are shared and unchanged by the addition of the API-time level.

The `fmt_dur_s` helper SHALL format a non-negative integer number of seconds as: `<s>s` when under 60 seconds (for example `45s`; and `0s` for a sub-second millisecond value that still passed the `-gt 0` guard); `<m>m<s>s` when at least 60 seconds and under one hour (for example `3m45s`, `1m0s`, `59m59s`); and SHALL delegate to `fmt_dur` at one hour or more so the `1H15m` / `1D3H` forms are byte-for-byte identical to the session-duration primary. The existing `fmt_dur` helper SHALL NOT be modified.

The delta `(Δ)` SHALL be appended only when the elapsed time since the last user prompt is at least 60 seconds, and SHALL represent how long ago that prompt occurred. The delta's COLOR SHALL signal prompt-cache freshness using the existing two-tier idle thresholds (`LASTMSG_WARN` and `LASTMSG_STALE`): dim (`DM`) while the default prompt cache is still warm, yellow (`YL`) once `LASTMSG_WARN` has elapsed, and red (`RD`) once `LASTMSG_STALE` has elapsed. A delta under one minute SHALL be hidden, leaving the bare primary text. WHEN the elapsed time is negative (clock skew between the prompt-writing host and the render), it SHALL be clamped to 0 and the delta SHALL be hidden. Both the primary text and the delta SHALL be honest elapsed time; only the delta color asserts the cache read.

This requirement MUST be implemented inside `build_left` in `lib/render.sh`, which reads the per-session last-message file. That file is the one external string that does NOT pass through `parse_input`, so `build_left` MUST re-strip the same control-character set (C0 `0x01`–`0x1F`, DEL `0x7F`, and the 2-byte UTF-8 C1 block `0xC2 0x80`–`0x9F`), keeping that filter in sync with `parse_input`'s `select(. >= 32 and (. < 127 or . > 159))`; `_sanitize_field` re-applies a 256-BYTE cap via the `${REPLY:0:256}` substring (`LC_ALL=C` counts bytes), and the glob substitutions do the control-char strip only; the implementation MUST NOT introduce `set -e`, MUST keep `LC_ALL=C` byte-counting intact for `vis_width`, and MUST remain bash 3.2 compatible.

#### Scenario: API thinking time is the primary and replaces both the clock and the session duration

- **WHEN** `cost.total_api_duration_ms` is present AND numerically greater than zero (the `[ -n "$api_ms" ] && [ "$api_ms" -gt 0 ]` guard passes)
- **THEN** the time segment's primary text SHALL be `fmt_dur_s(cost.total_api_duration_ms / 1000)` rendered dim; the session-duration `fmt_dur` form SHALL NOT appear even when `cost.total_duration_ms` is also present; and the absolute last-prompt `HH:MM` clock SHALL NOT appear

##### Example: API-time primary overrides duration, with a colored delta

- **GIVEN** `cost.total_api_duration_ms = 225000`, `cost.total_duration_ms = 4521000`, and the last-message file holds `09:30 <epoch>` with `now - epoch = 600` and `LASTMSG_WARN = 300`
- **WHEN** `build_left` renders the time segment
- **THEN** the output is the dim `3m45s` followed by a yellow `(10m)`; neither `1H15m` (the duration form) nor `09:30` (the clock) appears

#### Scenario: fmt_dur_s renders seconds precision below one hour and delegates above

- **WHEN** `fmt_dur_s` formats the whole-seconds value derived from `cost.total_api_duration_ms`
- **THEN** the output SHALL follow the boundary table below

##### Example: fmt_dur_s boundary table

| total_api_duration_ms | whole seconds | fmt_dur_s output | Notes |
| --------------------- | ------------- | ---------------- | ----- |
| 500                   | 0             | `0s`             | sub-second but ms > 0 |
| 45000                 | 45            | `45s`            | under one minute, no minute prefix |
| 60000                 | 60            | `1m0s`           | exact minute keeps `s` |
| 225000                | 225           | `3m45s`          | typical case |
| 3599000               | 3599          | `59m59s`         | just under one hour |
| 4500000               | 4500          | `1H15m`          | ≥ 1h delegates to fmt_dur |
| 97200000              | 97200         | `1D3H`           | ≥ 1 day delegates to fmt_dur |

#### Scenario: Invalid API time falls back to the session duration

- **WHEN** `cost.total_api_duration_ms` is absent, non-numeric, zero, or nonpositive (so its guard fails) AND `cost.total_duration_ms` is present and numerically greater than zero
- **THEN** the primary text SHALL be the session-duration `fmt_dur` form exactly as before this change (the API-time level is skipped)

##### Example: zero API time falls back to duration

- **GIVEN** `cost.total_api_duration_ms = 0` and `cost.total_duration_ms = 4521000`
- **WHEN** `build_left` renders the time segment
- **THEN** the primary text is the dim `1H15m`

#### Scenario: Clock fallback when both duration fields are unavailable

- **WHEN** both `cost.total_api_duration_ms` and `cost.total_duration_ms` are absent, non-numeric, or not greater than zero
- **THEN** the primary text SHALL be the last user prompt's dim `HH:MM` clock label when a last-message file exists, with the same `(Δ)` delta rules applied

##### Example: no cost fields fall back to the clock

- **GIVEN** the stdin JSON has no `cost` object and the last-message file holds `09:30 <epoch>` with `now - epoch = 600`
- **WHEN** `build_left` renders the time segment
- **THEN** the output is the dim `09:30` followed by a yellow `(10m)`

#### Scenario: Last prompt within the same minute shows the bare primary

- **WHEN** the last prompt's stored epoch is less than 60 seconds before the current time `now`
- **THEN** the time segment SHALL render only the dim primary text (API time, session duration, or the clock fallback) with no parenthesized delta

##### Example: sub-minute prompt with API-time primary

- **GIVEN** `cost.total_api_duration_ms = 225000` and the last-message file holds `14:05 <epoch>` where `now - epoch = 30`
- **WHEN** `build_left` renders the time segment
- **THEN** the output is the dim `3m45s` with no `(Δ)` suffix

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

WHEN the primary text is the `HH:MM` clock fallback (that is, BOTH `cost.total_api_duration_ms` and `cost.total_duration_ms` are unavailable) AND the last prompt's local calendar day differs from the current local calendar day, the displayed clock MUST include the date (only when the delta is shown, i.e. `lm_age >= 60s`, matching the clock-fallback + delta branch) so that a prior-day time is not misread as today; when the last prompt occurred on the current local calendar day, a bare `HH:MM` MUST be shown. Both the API-time primary and the session-duration primary are elapsed spans, not wall clocks, and MUST NOT receive a date prefix.

The calendar-day comparison MUST be computed from the local calendar date of `lm_epoch` versus the local calendar date of `now` (a difference in local calendar day, NOT a fixed 24-hour age threshold), so a prompt at `23:50` followed by a render at `00:10` the next day is treated as cross-day even though the age is 20 minutes. The date-prefixed form MUST NOT change the delta computation or its color tier; only the clock text gains a date prefix.

#### Scenario: An elapsed-span primary is never date-prefixed

- **WHEN** either `cost.total_api_duration_ms` or `cost.total_duration_ms` supplies the primary text (an elapsed span) and the last prompt occurred on a prior local calendar day
- **THEN** the primary text SHALL remain the bare `fmt_dur_s` / `fmt_dur` duration with its colored delta, and SHALL NOT gain a `MM-DD` date prefix

##### Example: cross-day prompt with API-time primary

- **GIVEN** `cost.total_api_duration_ms = 225000` (3m45s) and `lm_epoch` is `2026-06-14 12:00` local while `now` is `2026-06-15 14:00` local (26 hours earlier)
- **WHEN** `build_left` renders the time segment
- **THEN** the primary text is the dim `3m45s` followed by a red `(1D2H)` delta, with no date prefix

#### Scenario: Same local calendar day shows bare HH:MM under clock fallback

- **WHEN** the primary text is the clock fallback and `lm_epoch` and `now` fall on the same local calendar day
- **THEN** the clock text SHALL be the bare `HH:MM` form (optionally followed by the colored delta)

##### Example: same-day prompt 10 minutes ago

- **GIVEN** neither `cost` duration field is present, today is `2026-06-15`, `lm_epoch` is `2026-06-15 14:00` local, and `now` is `2026-06-15 14:10` local
- **WHEN** `build_left` renders the time segment
- **THEN** the clock text is `14:00` (bare, no date) and the delta is `(10m)`

#### Scenario: Different local calendar day prefixes the date under clock fallback

- **WHEN** the primary text is the clock fallback and `lm_epoch` and `now` fall on different local calendar days (only when the delta is shown, i.e. `lm_age >= 60s`)
- **THEN** the clock text SHALL include the date prefix (for example `MM-DD HH:MM`) ahead of the time, so the prior-day prompt is not read as today

##### Example: prompt 26 hours ago carries the date

- **GIVEN** neither `cost` duration field is present, `now` is `2026-06-15 14:00` local and `lm_epoch` is `2026-06-14 12:00` local (26 hours earlier)
- **WHEN** `build_left` renders the time segment
- **THEN** the clock text is the date-prefixed form `06-14 12:00` (NOT a bare `12:00`) and the delta is the red `(1D2H)` form because `lm_age >= LASTMSG_STALE`

##### Example: cross-midnight prompt under one hour

- **GIVEN** neither `cost` duration field is present, `lm_epoch` is `2026-06-14 23:50` local and `now` is `2026-06-15 00:10` local
- **WHEN** `build_left` renders the time segment
- **THEN** the clock text is date-prefixed `06-14 23:50` because the local calendar day differs, and the delta `(20m)` is yellow because `lm_age = 1200 >= LASTMSG_WARN`

#### Scenario: Legacy file format without a numeric epoch is shown verbatim under clock fallback

- **WHEN** both `cost` duration fields are unavailable and the last-message file holds an older format whose trailing token is not an all-digit epoch (so `lm_epoch` resolves empty)
- **THEN** the stored string SHALL be displayed verbatim as the dim primary text with no delta and no added date prefix, preserving backward compatibility for sessions whose file has not yet been rewritten

### Requirement: Time segment omitted when no timestamp inputs are available

WHEN neither timestamp input is available — that is, `build_left` reads no per-session last-message string (`last_msg` empty because the `session_id` is empty or path-traversal-shaped, or no last-message file exists) AND the duration chain produces no primary (`dur_str` empty because NEITHER `cost.total_api_duration_ms` NOR `cost.total_duration_ms` is present, numeric, and greater than zero) — the time segment SHALL be omitted entirely and SHALL NOT be appended to the left parts. The segment SHALL be emitted only when at least one of the two inputs is present, matching the code guard `[ -n "$last_msg" ] || [ -n "$dur_str" ]` in `build_left`. This omission MUST NOT introduce `set -e`, MUST remain bash 3.2 compatible, and MUST leave the remaining left segments and the right-align algorithm unaffected (an absent time segment is simply not present in `parts`).

#### Scenario: Both timestamp inputs absent omits the time segment

- **WHEN** no last-message file is available (so `last_msg` is empty) AND neither `cost.total_api_duration_ms` nor `cost.total_duration_ms` yields a positive duration (so `dur_str` is empty)
- **THEN** `build_left` SHALL append no time segment to `parts`, and the rendered line SHALL contain neither a duration nor a clock nor a `(Δ)` delta

##### Example: fresh session with no last-message file and no duration fields

- **GIVEN** the stdin JSON has no `cost` object and no last-message file exists for the current `session_id`
- **WHEN** `build_left` builds the left parts
- **THEN** no `seg_lastmsg` is appended and the time segment does not appear anywhere on the line

#### Scenario: Either input alone keeps the time segment present

- **WHEN** exactly one input is available — either a positive duration from the API-time-or-session-duration chain with no last-message file, or a last-message file with no positive duration
- **THEN** the time segment SHALL be emitted, showing the available primary text (the dim `fmt_dur_s` API time, the dim `fmt_dur` session duration, or the dim `HH:MM` clock label), with the `(Δ)` delta applied only when its ≥60s rule is met

##### Example: API time present but no last-message file

- **GIVEN** `cost.total_api_duration_ms = 225000` and no last-message file exists for the current `session_id`
- **WHEN** `build_left` renders the time segment
- **THEN** the output is the dim `3m45s` with no `(Δ)` suffix, and the time segment IS present on the line
