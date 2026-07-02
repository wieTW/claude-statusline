## MODIFIED Requirements

### Requirement: Cross-day timestamps include the date

WHEN the primary text is the `HH:MM` clock fallback (that is, `cost.total_duration_ms` is unavailable) AND the last prompt's local calendar day differs from the current local calendar day, the displayed clock MUST include the date (only when the delta is shown, i.e. `lm_age >= 60s`, matching the clock-fallback + delta branch) so that a prior-day time is not misread as today; when the last prompt occurred on the current local calendar day, a bare `HH:MM` MUST be shown. The session-duration primary text is an elapsed span, not a wall clock, and MUST NOT receive a date prefix.

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

- **WHEN** the primary text is the clock fallback and `lm_epoch` and `now` fall on different local calendar days (only when the delta is shown, i.e. `lm_age >= 60s`)
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
