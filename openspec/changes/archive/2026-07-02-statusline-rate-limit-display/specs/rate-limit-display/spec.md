## ADDED Requirements

### Requirement: Rate-Limit Window Segment Content

For each of the two rate-limit windows (the 5-hour window and the 7-day window), the statusline SHALL render one segment consisting of a reset-countdown prefix followed by the remaining-quota percentage. The countdown SHALL be produced by `ttl` from `resets_at` minus the current time and formatted by `fmt_dur` (the shared `D`/`H`/`m` cascade, e.g. `2H15m`, `5m`), and SHALL be rendered in the neutral white role (`WH`) ahead of the percentage. The remaining percentage SHALL be `100` minus the rounded `used%` (`fmt_pct` rounds `used%` to the nearest integer via `%.0f`), and SHALL be clamped so it is never rendered below `0` even when the upstream `used%` exceeds `100`. When the window's `resets_at` is already in the past (its value minus now is `≤ 0`), the countdown prefix SHALL be the literal `0m`. When `resets_at` is empty or non-numeric, `ttl` SHALL yield an empty countdown and the segment SHALL omit the prefix while still showing the remaining percentage. `build_rate` SHALL assemble these into `_rate_full`, and `build_left` SHALL call `build_rate` directly and append the resulting `seg_5h_full`/`seg_7d` inline to the left half only when the segment is non-empty. (`add_rate` is an equivalent unused/reusable helper that wraps the same `build_rate`-then-append behaviour but is not on the live append path.) The 5-hour segment alone SHALL carry the burn-projection indicator (passed as the third argument from `build_burn`'s `_burn`) appended inside the segment; the 7-day segment SHALL NOT carry any burn indicator. The base segment SHALL NOT define the burn indicator's own content, colour, or gating (owned by rate-burn-projection); it SHALL only place the already-built indicator inside the 5-hour segment.

#### Scenario: Full 5-hour segment with countdown and remaining percentage

- **WHEN** `build_rate` is called with a numeric `used%` of `24` and a `resets_at` that is `8100` seconds in the future
- **THEN** the countdown SHALL read `2H15m` in the neutral white role
- **AND** the remaining percentage SHALL read `76%` (`100 - 24`) immediately after the countdown

##### Example: Reset already past yields 0m countdown

- **GIVEN** a window whose `resets_at` minus the current time is `-30` (already elapsed)
- **WHEN** `ttl` computes the countdown for `build_rate`
- **THEN** the countdown prefix SHALL be the literal `0m`
- **AND** the remaining percentage SHALL still be shown after it

##### Example: Remaining clamps to zero when used exceeds 100

- **GIVEN** an upstream `used%` of `112`
- **WHEN** `build_rate` computes remaining as `100 - 112`
- **THEN** the remaining percentage SHALL be clamped to `0%` and MUST NOT render a negative number

#### Scenario: Non-numeric reset time drops only the countdown

- **WHEN** `build_rate` receives a valid numeric `used%` but a `resets_at` that is empty or non-numeric
- **THEN** `ttl` SHALL yield an empty countdown and the segment SHALL omit the prefix
- **AND** the remaining percentage SHALL still be rendered (the full form equals the compact form)

#### Scenario: Burn alarm rides inside the 5-hour segment only

- **WHEN** `build_left` builds the 5-hour segment with a non-empty `_burn` indicator and the 7-day segment with no indicator
- **THEN** the burn indicator SHALL appear appended inside the 5-hour segment after the remaining percentage
- **AND** the 7-day segment SHALL NOT contain any burn indicator

### Requirement: Remaining-Percentage Colour Ladder

The remaining-quota percentage SHALL be coloured strictly by its own value using a four-tier ladder: a remaining value greater than `75` SHALL use green (`GR`); greater than `50` (but not greater than `75`) SHALL use yellow (`YL`); greater than `25` (but not greater than `50`) SHALL use orange (`OG`); and any value of `25` or below SHALL use red (`RD`). The colour SHALL apply only to the percentage token; the countdown prefix SHALL remain the neutral white role regardless of the remaining value. The clamped value of `0` SHALL fall in the red tier.

#### Scenario: Green tier for healthy remaining quota

- **WHEN** the remaining percentage is `76`
- **THEN** the percentage SHALL be rendered green (`GR`)

#### Scenario: Boundary values select the lower tier

- **WHEN** the remaining percentage is exactly `75`
- **THEN** the percentage SHALL be rendered yellow (`YL`), because the green tier requires a value strictly greater than `75`

##### Example: Red tier at and below the 25 boundary

- **GIVEN** a remaining percentage of `25`
- **WHEN** `build_rate` selects the colour
- **THEN** it SHALL use red (`RD`), and any remaining value below `25` (including the clamped `0`) SHALL likewise use red

### Requirement: Empty Segment On Non-Numeric Used Percentage

When a window's `used%` is empty or non-numeric, `build_rate` SHALL leave both `_rate_full` and `_rate_compact` empty and return without emitting anything (via `fmt_pct` yielding an empty `_pct`), and `build_left` SHALL NOT append the segment to the left half. A missing or malformed `used%` SHALL therefore render as nothing on screen rather than a placeholder, a zero, or a partial segment. This SHALL hold independently of whether `resets_at` is valid.

#### Scenario: Empty used percentage produces no segment

- **WHEN** `build_rate` is called with an empty `used%`
- **THEN** `fmt_pct` SHALL yield an empty `_pct` and `build_rate` SHALL return with both `_rate_full` and `_rate_compact` empty
- **AND** `build_left` SHALL NOT push the segment onto the left half

##### Example: Non-numeric used percentage is silent even with a valid reset time

- **GIVEN** a `used%` of `n/a` and a valid future `resets_at`
- **WHEN** `build_rate` runs
- **THEN** no rate-limit segment SHALL be emitted for that window

### Requirement: Compact Form Without Countdown

`build_rate` SHALL additionally produce a compact form (`_rate_compact`) consisting of the coloured remaining percentage plus any burn indicator, with the reset-countdown prefix dropped. This compact form SHALL exist whenever the full form exists and SHALL retain the same remaining-percentage value, colour, and (for the 5-hour window) burn indicator as the full form, differing only by the absence of the countdown. The compact form SHALL be available for the 5-hour window's collapsed rendering; the trigger and width conditions under which the compact form is chosen instead of the full form SHALL be owned by adaptive-layout and SHALL NOT be defined here.

#### Scenario: Compact form keeps remaining percentage and burn, drops countdown

- **WHEN** `build_rate` builds the 5-hour segment with a countdown, a remaining percentage, and a burn indicator
- **THEN** `_rate_compact` SHALL contain the coloured remaining percentage followed by the burn indicator
- **AND** `_rate_compact` SHALL NOT contain the reset-countdown prefix

##### Example: Compact form preserves colour and value

- **GIVEN** a full 5-hour segment whose remaining percentage is `76%` in green with a burn indicator
- **WHEN** the compact form is produced
- **THEN** it SHALL read the same `76%` in green plus the burn indicator, only without the leading countdown

<!-- @trace
source: statusline-rate-limit-display
updated: 2026-07-02
code:
  - lib/render.sh
-->

