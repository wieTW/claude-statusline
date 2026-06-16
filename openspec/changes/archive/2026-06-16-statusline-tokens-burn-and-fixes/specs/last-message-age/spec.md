## ADDED Requirements

### Requirement: Last-message timestamp with cache-freshness-colored delta

The statusline SHALL display the time of the last user prompt as `HH:MM` followed, when the elapsed time is at least one minute, by a parenthesized delta `(Δ)`; the timestamp text SHALL be rendered dim and the delta's COLOR SHALL signal prompt-cache freshness using the existing two-tier idle thresholds (`LASTMSG_WARN` and `LASTMSG_STALE`), so the displayed duration is the honest elapsed time while only the color asserts the cache read.

The delta SHALL render warm/dim while the default prompt cache is still warm, yellow once the default cache idle window (`LASTMSG_WARN`) has elapsed, and red once the extended cache idle window (`LASTMSG_STALE`) has elapsed; a delta under one minute SHALL be hidden, leaving the bare timestamp.

This requirement MUST be implemented inside `build_left` in `lib/render.sh`, which reads the per-session last-message file. That file is the one external string that does NOT pass through `parse_input`, so `build_left` MUST re-strip the same control-character set (C0 `0x01`–`0x1F`, DEL `0x7F`, and the 2-byte UTF-8 C1 block `0xC2 0x80`–`0x9F`) and re-apply the 256-codepoint cap via glob, keeping that filter in sync with `parse_input`'s `select(. >= 32 and (. < 127 or . > 159))`; the implementation MUST NOT introduce `set -e`, MUST keep `LC_ALL=C` byte-counting intact for `vis_width`, and MUST remain bash 3.2 compatible.

#### Scenario: Last prompt within the same minute shows bare timestamp

- **WHEN** the last prompt's stored epoch is less than 60 seconds before the current time `now`
- **THEN** the time segment SHALL render only the dim `HH:MM` timestamp with no parenthesized delta

##### Example: sub-minute prompt

- GIVEN the last-message file contains `14:05 <epoch>` where `now - epoch = 30`
- WHEN `build_left` renders the time segment
- THEN the output is the dim string `14:05` with no `(Δ)` suffix

#### Scenario: Delta color tiers preserved across the two cache windows

- **WHEN** the elapsed time `lm_age = now - lm_epoch` is at least 60 seconds
- **THEN** the delta SHALL be colored dim (`DM`) for `lm_age < LASTMSG_WARN`, yellow (`YL`) for `LASTMSG_WARN <= lm_age < LASTMSG_STALE`, and red (`RD`) for `lm_age >= LASTMSG_STALE`

##### Example: delta color boundaries with default thresholds

| lm_age (seconds) | tier            | delta color |
| ---------------- | --------------- | ----------- |
| 120              | warm            | DM (dim)    |
| 300              | default idle    | YL (yellow) |
| 1800             | default idle    | YL (yellow) |
| 3600             | extended idle   | RD (red)    |
| 7200             | extended idle   | RD (red)    |

- GIVEN `LASTMSG_WARN = 300` and `LASTMSG_STALE = 3600`
- WHEN each `lm_age` above is rendered
- THEN the delta uses the listed color while the `HH:MM` (or date-prefixed) timestamp stays dim

#### Scenario: Negative elapsed time is clamped

- **WHEN** the stored epoch is greater than `now` (clock skew between the prompt-writing host and the render)
- **THEN** `lm_age` SHALL be clamped to 0, the delta SHALL be hidden, and the bare timestamp SHALL be shown

### Requirement: Cross-day timestamps include the date

When the last prompt's local calendar day differs from the current local calendar day, the displayed timestamp MUST include the date so that a prior-day time is not misread as today; when the last prompt occurred on the current local calendar day, a bare `HH:MM` MUST be shown.

The calendar-day comparison MUST be computed from the local calendar date of `lm_epoch` versus the local calendar date of `now` (a difference in local calendar day, NOT a fixed 24-hour age threshold), so a prompt at `23:50` followed by a render at `00:10` the next day is treated as cross-day even though the age is 20 minutes. The date-prefixed form MUST NOT change the delta computation or its color tier; only the timestamp text gains a date prefix.

#### Scenario: Same local calendar day shows bare HH:MM

- **WHEN** `lm_epoch` and `now` fall on the same local calendar day
- **THEN** the timestamp text SHALL be the bare `HH:MM` form (optionally followed by the colored delta)

##### Example: same-day prompt 10 minutes ago

- GIVEN today is `2026-06-15`, `lm_epoch` is `2026-06-15 14:00` local, and `now` is `2026-06-15 14:10` local
- WHEN `build_left` renders the time segment
- THEN the timestamp text is `14:00` (bare, no date) and the delta is `(10m)`

#### Scenario: Different local calendar day prefixes the date

- **WHEN** `lm_epoch` and `now` fall on different local calendar days
- **THEN** the timestamp text SHALL include the date prefix (for example `MM-DD HH:MM`) ahead of the time, so the prior-day prompt is not read as today

##### Example: prompt 26 hours ago carries the date

- GIVEN `now` is `2026-06-15 14:00` local and `lm_epoch` is `2026-06-14 12:00` local (26 hours earlier)
- WHEN `build_left` renders the time segment
- THEN the timestamp text is the date-prefixed form `06-14 12:00` (NOT a bare `12:00`) and the delta is the red `(1D2H)` form because `lm_age >= LASTMSG_STALE`

##### Example: cross-midnight prompt under one hour

- GIVEN `lm_epoch` is `2026-06-14 23:50` local and `now` is `2026-06-15 00:10` local
- WHEN `build_left` renders the time segment
- THEN the timestamp is date-prefixed `06-14 23:50` because the local calendar day differs, and the delta `(20m)` is yellow because `lm_age = 1200 >= LASTMSG_WARN`

#### Scenario: Legacy file format without a numeric epoch is shown verbatim

- **WHEN** the last-message file holds an older format whose trailing token is not an all-digit epoch (so `lm_epoch` resolves empty)
- **THEN** the stored string SHALL be displayed verbatim as the dim timestamp with no delta and no added date prefix, preserving backward compatibility for sessions whose file has not yet been rewritten
