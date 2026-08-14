## ADDED Requirements

### Requirement: Warning-aligned context percentage source

The context segment SHALL derive a single "selected context percentage" that every context form consumes (the CTX_BAR bar form, the `ctx:N%` text form, the bare `N%` compact form, the budget-aware coloring input, and the cliff-marker hosting gate). WHEN all four `context_window.current_usage` token fields (`input_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, `output_tokens`) are numeric AND `context_window.context_window_size` is numeric and strictly greater than the context reserve constant, THEN the selected context percentage MUST be computed locally on the warning-aligned basis: T = the sum of the four token fields; P = `context_window_size` minus the reserve; R = round-half-up of 100 × (P − T) / P, with (P − T) clamped to a minimum of 0; selected percentage N = 100 − R. This makes N the exact integer complement of the "Context low (R% remaining)" figure Claude Code computes for the same usage snapshot on its auto-compact-off basis. WHEN that eligibility gate fails (any of the five fields absent or non-numeric, or `context_window_size` not above the reserve), THEN the selected context percentage MUST fall back to the legacy `context_window.used_percentage` value through `fmt_pct`, producing output byte-identical to the pre-change behavior.

The reserve SHALL be a named constant with value 20000 defined in the configuration area at the top of statusline-command.sh, carrying a provenance comment that names the Claude Code version and date against which the value was verified (2.1.232, 2026-08-14); it SHALL NOT be documented as a user preference knob. The percentage computation MUST use pure bash integer arithmetic with no external process fork and MUST live in lib/render.sh as presentation logic. The five new fields MUST be read only through `parse_input` (the single sanitization entry point), appended at the tail of the jq extraction array with the positional `read` order extended one-for-one.

Interaction with hard rules: no second stdin reader (only `parse_input`'s jq consumes stdin); no `set -e`; `LC_ALL=C` stays pinned so integer formatting is stable; all five counters MUST be evaluated as base-10 integers regardless of leading zeros (bash's octal interpretation of zero-prefixed values MUST be defeated); the division's denominator is guaranteed positive by the eligibility gate; any parse or arithmetic failure MUST degrade silently to the fallback path (the statusline's output is the screen, so no error text is ever emitted).

#### Scenario: Aligned basis wins when eligible fields are present

- **WHEN** the `current_usage` token fields sum to 960400, `context_window_size` is 1000000, and `used_percentage` is 96
- **THEN** the selected context percentage MUST be 98 (P = 980000, R = 2), not the upstream 96

##### Example: 1M edge frame matching the Context low warning

- GIVEN input_tokens + cache_creation_input_tokens + cache_read_input_tokens + output_tokens = 960400 and context_window_size = 1000000 and used_percentage = 96
- WHEN the context segment computes the selected context percentage
- THEN P = 1000000 − 20000 = 980000 and R = round(100 × 19600 / 980000) = 2
- THEN the displayed percentage is 98, the exact complement of the "Context low (2% remaining)" warning

#### Scenario: Fallback frame renders byte-identical to legacy behavior

- **WHEN** `current_usage` or `context_window_size` is absent or non-numeric and `used_percentage` is 96
- **THEN** the selected context percentage MUST be 96 via the legacy `fmt_pct` path and the rendered context segment MUST be byte-identical to the pre-change output

#### Scenario: Usage at or beyond the reserved window clamps to 100

- **WHEN** T is greater than or equal to P
- **THEN** R MUST clamp to 0 and the selected context percentage MUST be 100

##### Example: saturation past the reserve boundary

- GIVEN T = 985000 and context_window_size = 1000000
- WHEN P = 980000 and P − T is negative
- THEN P − T clamps to 0, R = 0, and the displayed percentage is 100

#### Scenario: Window not above the reserve falls back

- **WHEN** `context_window_size` is absent, non-numeric, or not strictly greater than 20000
- **THEN** the warning-aligned computation MUST NOT run and the selected context percentage MUST come from the `used_percentage` fallback path

#### Scenario: Integer complement holds at rounding boundaries

- **WHEN** the exact remaining percentage lands on a .5 boundary
- **THEN** R MUST round half-up and N MUST equal 100 − R, so the pair always sums to 100

##### Example: half-up boundary

- GIVEN context_window_size = 1000000 (P = 980000) and T = 955500
- WHEN the exact remaining percentage is 100 × 24500 / 980000 = 2.5
- THEN R = 3 (half-up) and N = 97; an independently rounded used percentage (round of 97.5 = 98) would break the complement, which is why N is defined as 100 − R

<!-- @trace
source: align-ctx-with-context-low
updated: 2026-08-14
code:
  - statusline-command.sh
  - lib/collect.sh
  - lib/render.sh
  - tests/run-tests.sh
-->

## MODIFIED Requirements

### Requirement: Model-context-size-aware usage alerting

The context-window usage meter SHALL evaluate its red alert threshold against the active model's context-window budget and SHALL NOT apply a single fixed 80% red threshold to every model. WHEN the model exposes an extended (1M) context window, THEN a given selected context percentage (per the warning-aligned context percentage source requirement) MUST be evaluated against the larger budget, so a value such as 85% MUST NOT be flagged red merely for exceeding 80%. The meter MUST source the budget signal from the stdin JSON the statusline already parses (the model display name carrying a "1M context" marker, mirroring the existing `model/ (1M context)/ (1M)` handling in `build_left`), and MUST default to the standard (200k-class) budget when no extended-context signal is present.

Interaction with hard rules: the model/budget signal MUST be read only through `parse_input` (the single sanitization entry point), keeping `parse_input`'s positional `read` order one-for-one with the jq array and respecting the 256-codepoint cap; no `set -e`; `LC_ALL=C` stays pinned so `%.0f` percentage formatting and byte-counting are unchanged; any new collected field MUST follow the concurrency contract (a background job redirected from `</dev/null`). The numeric comparison MUST be integer-based on the selected context percentage, identical in mechanism to the existing `_pct -gt 80` test, only with a budget-derived threshold.

#### Scenario: 85% on a 1M-context model is not red

- **WHEN** the active model reports an extended (1M) context window and the selected context percentage is 85
- **THEN** the context percentage MUST be rendered in the normal (non-alert) text color and MUST NOT use the red alert color

##### Example: 1M model at 85%

- GIVEN model display name = `Opus 4.8 (1M context)` and selected context percentage = 85
- WHEN `build_left` colors the context percentage
- THEN the threshold used is the 1M-budget threshold (not the fixed 80%), so 85 is below it
- THEN `ctx_color` = WH (normal text), NOT RD

#### Scenario: High percentage on a 200k-context model is red

- **WHEN** the active model reports a standard (200k-class) context window and the selected context percentage is 85
- **THEN** the context percentage MUST be rendered in the red alert color

##### Example: 200k model at 85%

- GIVEN model display name = `Sonnet 4.6` (no extended-context marker) and selected context percentage = 85
- WHEN `build_left` colors the context percentage
- THEN the standard-budget threshold applies (the established 80% boundary for 200k-class models)
- THEN 85 exceeds the threshold, so `ctx_color` = RD

#### Scenario: Threshold selection is driven by budget, not a constant

- **WHEN** two frames render the identical selected context percentage differing only in whether the model carries the 1M-context marker
- **THEN** the standard-budget frame MUST be capable of flagging red at a percentage where the extended-budget frame MUST NOT, proving the threshold is budget-derived rather than a single fixed constant

<!-- @trace
source: align-ctx-with-context-low
updated: 2026-08-14
code:
  - statusline-command.sh
  - .spectra.yaml
  - lib/render.sh
  - lib/collect.sh
  - tests/run-tests.sh
  - CLAUDE.md
-->

### Requirement: 200k cost/cache cliff marker

The statusline SHALL mark the genuine 200k cost/cache cliff when it has been crossed, using the upstream over-200k indicator supplied on stdin, and SHALL render this cliff marker independently of the percentage-based context coloring. The marker MUST appear if and only if the upstream over-200k indicator is true AND a numeric selected context percentage is present (produced by either the warning-aligned computation or the `used_percentage` fallback), regardless of the numeric value or color of that percentage or of which budget the percentage threshold selected. The cliff marker text MUST be emitted only through the established rendering path (appended within `build_left`'s context segment using palette roles), and the over-200k indicator MUST be read via `parse_input` so it passes the single sanitization entry point with the positional `read` order preserved and the 256-codepoint cap applied.

Interaction with hard rules: reading the indicator MUST NOT introduce a second stdin reader (only `parse_input`'s jq consumes stdin); if the field is collected via any background job, that job MUST redirect stdin from `</dev/null`; no `set -e`; `LC_ALL=C` pinned; jq extraction MUST follow the existing single-pass array convention with explode/implode control-character filtering for any string-typed field.

#### Scenario: Over-200k indicator true shows the cliff marker

- **WHEN** the upstream over-200k indicator on stdin is true
- **THEN** the statusline MUST render the 200k cliff marker in the context segment, independently of the percentage color

##### Example: over-200k crossed

- GIVEN the stdin over-200k indicator = true and the selected context percentage = 70
- WHEN `build_left` builds the context segment
- THEN the cliff marker is present (driven solely by the indicator = true)
- THEN the marker's presence does NOT depend on whether 70% was colored normal or red

#### Scenario: Over-200k indicator false shows no cliff marker

- **WHEN** the upstream over-200k indicator on stdin is false or absent
- **THEN** the statusline MUST NOT render the 200k cliff marker, even when the selected context percentage is high

##### Example: not crossed at high percent

- GIVEN the stdin over-200k indicator = false and the selected context percentage = 95
- WHEN `build_left` builds the context segment
- THEN no cliff marker is rendered
- THEN the high percentage still drives `ctx_color` per the budget-aware threshold rule, unaffected by the absent marker

<!-- @trace
source: align-ctx-with-context-low
updated: 2026-08-14
code:
  - statusline-command.sh
  - .spectra.yaml
  - lib/render.sh
  - lib/collect.sh
  - tests/run-tests.sh
  - CLAUDE.md
-->

### Requirement: Coloring and cliff marker are decoupled

The percentage-based context coloring and the 200k cliff marker SHALL be computed from independent inputs (the selected context percentage plus the model budget for coloring; the upstream over-200k indicator for the marker) and SHALL NOT be conflated, so that each can be true or false without forcing the state of the other. A red percentage MUST NOT imply the cliff marker, and the cliff marker MUST NOT imply a red percentage.

#### Scenario: Marker present while percentage is normal-colored

- **WHEN** the over-200k indicator is true on a 1M-context model whose selected context percentage (85) is below the extended-budget red threshold
- **THEN** the percentage MUST render in normal color AND the cliff marker MUST still be shown

##### Example: decoupled states matrix

| model budget | selected % | over-200k indicator | percentage color | cliff marker |
| --- | --- | --- | --- | --- |
| 1M | 85 | false | normal (not red) | absent |
| 1M | 85 | true | normal (not red) | present |
| 200k | 85 | false | red | absent |
| 200k | 85 | true | red | present |

<!-- @trace
source: align-ctx-with-context-low
updated: 2026-08-14
code:
  - statusline-command.sh
  - .spectra.yaml
  - lib/render.sh
  - lib/collect.sh
  - tests/run-tests.sh
  - CLAUDE.md
-->

### Requirement: CTX_BAR gradient context bar

When the `CTX_BAR` configuration knob is enabled, the context segment's full form SHALL prepend a fixed-width 12-cell solid progress bar before the percentage text, assembled in `build_left`. The number of filled cells SHALL be computed as `_pct * 12 / 100` (integer floor), where `_pct` is the selected context percentage (per the warning-aligned context percentage source requirement), matching `filled=$(( _pct * BAR_W / 100 ))`. Each filled cell SHALL be rendered as a solid background-colored block (a background SGR code immediately followed by a space so the cell paints edge-to-edge with no font gap) and each unfilled cell SHALL be rendered with the grey `TRK` track background followed by a space. The filled cells SHALL be colored by cell position in four equal zones (the quarters of the 12-cell bar): cells 0-2 green (`GR`), cells 3-5 yellow (`YL`), cells 6-8 orange (`OG`), cells 9-11 red (`RD`), matching the established `GR→YL→OG→RD` semantic ladder. Each zone's color MUST be applied by converting the palette role's foreground SGR prefix (`38;2;…`) to the corresponding background SGR prefix (`48;2;…`); the statusline SHALL NOT render the zone as foreground glyph text. After the 12 cells the bar SHALL emit a reset then a single space, then the percentage number colored by the budget-aware `ctx_color`, then `%`, then the cliff marker (if any). The palette roles `GR`, `YL`, `OG`, `RD`, and `TRK` MUST be sourced from `load_palette`, so the bar tracks the active theme rather than hard-coding colors.

Interaction with hard rules: the bar MUST be built only within `build_left`'s context segment; `LC_ALL=C` stays pinned so the integer rounding and cell arithmetic are stable; no `set -e`; and the emitted bar MUST consist solely of the statusline's own SGR codes and spaces so `vis_width`'s cell accounting stays correct.

#### Scenario: Bar at 50% fills six cells across green and yellow zones

- **WHEN** `CTX_BAR` is enabled and the selected context percentage is 50
- **THEN** exactly 6 cells MUST be filled (cells 0-2 in the green zone, cells 3-5 in the yellow zone) rendered as background-colored blocks, and cells 6-11 MUST be drawn with the grey `TRK` track, with the orange and red zones showing no filled cells

##### Example: 50% bar

- GIVEN `CTX_BAR=true` and the selected context percentage = 50
- WHEN `build_left` builds the context segment
- THEN `filled` = `50 * 12 / 100` = 6
- THEN cells 0-2 use the `GR` background, cells 3-5 use the `YL` background, cells 6-11 use the `TRK` background
- THEN the bar is followed by a reset, a space, and the `ctx_color`-colored `50%`

#### Scenario: Full bar reaches the red zone

- **WHEN** `CTX_BAR` is enabled and the selected context percentage is 100
- **THEN** all 12 cells MUST be filled, so cells 9-11 render in the red (`RD`) background zone and no `TRK` track cell remains

##### Example: 100% bar reaches red

- GIVEN `CTX_BAR=true` and the selected context percentage = 100
- WHEN `build_left` builds the context segment
- THEN `filled` = 12, the last three cells (9-11) use the `RD` background, and every zone color appears in position order green→yellow→orange→red

#### Scenario: Zone color is driven by cell position, not fill count

- **WHEN** two frames render bars filled to different cell counts
- **THEN** each filled cell's color MUST be selected from its own position index against the fixed quarter boundaries (3, 6, 9), so a partially filled bar shows only the zones its filled cells reach and never recolors earlier cells based on the total fill

<!-- @trace
source: align-ctx-with-context-low
updated: 2026-08-14
code:
  - statusline-command.sh
  - lib/render.sh
  - tests/run-tests.sh
-->

### Requirement: Context meter text and compact forms

The context segment SHALL provide, in addition to the `CTX_BAR` bar form, a text full form and a bare compact form, all assembled in `build_left`. When the `CTX_BAR` knob is disabled, the full form SHALL be the text `ctx:N%`, where `N` is the selected context percentage (per the warning-aligned context percentage source requirement), colored by the budget-aware `ctx_color`. A compact form SHALL always be produced as the bare `N%` (the same selected percentage colored by `ctx_color`, without the bar prefix and without the `ctx:` label) and SHALL be produced regardless of the `CTX_BAR` setting. The 200k cost/cache cliff marker (the `⚑` glyph carrying the red alert role) SHALL be appended to every context form (the `CTX_BAR` bar full form, the `ctx:N%` text full form, and the bare `N%` compact form) and SHALL NOT be attached to only the bar form. The marker's presence SHALL remain governed solely by the upstream over-200k indicator per the existing 200k cliff marker requirement, independent of which of the three forms is being rendered.

Interaction with hard rules: all three forms MUST be composed only from the statusline's own SGR roles and the sanitized numeric percentage; the `⚑` glyph is one of the narrow multibyte characters folded by `vis_width`, so appending it to any form MUST NOT disturb width accounting; no `set -e`.

#### Scenario: CTX_BAR disabled yields the ctx:N% text form

- **WHEN** `CTX_BAR` is disabled and the selected context percentage is `N`
- **THEN** the full form MUST be the text `ctx:N%` colored by `ctx_color`, with no bar prepended

##### Example: text full form at 42%

- GIVEN `CTX_BAR=false` and the selected context percentage = 42
- WHEN `build_left` builds the context segment
- THEN the full form is `ctx:42%` (the `ctx:` prefix present, no bar), colored by the budget-aware `ctx_color`

#### Scenario: Bare compact form omits both bar and ctx prefix

- **WHEN** any numeric selected context percentage `N` is present
- **THEN** the compact form MUST be the bare `N%` colored by `ctx_color`, carrying neither the bar nor the `ctx:` label, and MUST be produced whether `CTX_BAR` is enabled or disabled

#### Scenario: Cliff marker appears on all three forms

- **WHEN** the upstream over-200k indicator is true and a numeric selected context percentage is present
- **THEN** the `⚑` cliff marker MUST be appended equally to the bar full form, the `ctx:N%` text form, and the bare `N%` compact form, and MUST NOT be restricted to the bar form alone

##### Example: cliff marker across forms

- GIVEN the over-200k indicator = true, the selected context percentage = 88
- WHEN `build_left` composes the bar form, the `ctx:88%` text form, and the bare `88%` compact form
- THEN each of the three forms ends with the red-role `⚑` marker

<!-- @trace
source: align-ctx-with-context-low
updated: 2026-08-14
code:
  - statusline-command.sh
  - lib/render.sh
  - tests/run-tests.sh
-->

### Requirement: Context segment suppression on absent or non-numeric usage

When NO numeric selected context percentage can be produced (the warning-aligned computation is ineligible AND `context_window.used_percentage` is absent or non-numeric such that `fmt_pct` yields an empty rounded value), the ENTIRE context segment SHALL be suppressed by `build_left`: no bar, no `ctx:N%` text form, no bare `N%` compact form, AND no `⚑` cliff marker, because the whole segment, including the cliff-marker computation, is gated behind a present numeric percentage. This suppression SHALL hold even when the upstream over-200k indicator is true: with no numeric percentage there is no context segment to host the marker, so the `⚑` marker SHALL NOT be emitted. Conversely, WHEN the warning-aligned computation is eligible, THEN the segment MUST render even if `used_percentage` itself is absent, because the aligned computation supplies the numeric percentage. This requirement reconciles the existing "cliff marker appears if and only if the over-200k indicator is true, regardless of the percentage" wording, which presumes a present percentage: the "regardless" independence applies to the percentage's VALUE and its COLOR (any numeric value, red or normal, still shows the marker), and SHALL NOT be read to force the marker when no numeric percentage exists.

Interaction with hard rules: the numeric-presence gate MUST use the final selected percentage's empty-string result (the `fmt_pct` empty cases for the fallback path, or the helper returning empty when both sources fail) rather than a separate parse; no `set -e`; and all percentage inputs reach `build_left` only through `parse_input`'s single sanitized, positionally-ordered read.

#### Scenario: Both sources absent suppresses the whole segment

- **WHEN** `used_percentage` is absent from the stdin JSON and the warning-aligned fields are absent or non-numeric
- **THEN** the selected context percentage is empty and `build_left` MUST emit no context segment at all: no bar, no text form, no compact form, and no `⚑` marker

#### Scenario: Non-numeric percentage with ineligible aligned fields suppresses the whole segment

- **WHEN** `used_percentage` is present but non-numeric and the warning-aligned computation is ineligible
- **THEN** the selected context percentage is empty and the entire context segment, including any cliff marker, MUST be suppressed

#### Scenario: Aligned fields alone keep the segment alive

- **WHEN** `used_percentage` is absent but all warning-aligned fields are numeric and `context_window_size` exceeds the reserve
- **THEN** the segment MUST render with the warning-aligned percentage and MUST NOT be suppressed

#### Scenario: Over-200k true but no numeric percentage shows no marker

- **WHEN** the upstream over-200k indicator is true but no numeric selected context percentage can be produced from either source
- **THEN** the `⚑` cliff marker MUST NOT be rendered, because there is no context segment to host it

##### Example: over-200k with no percentage from either source

- GIVEN the over-200k indicator = true, `used_percentage` absent, and `current_usage` absent
- WHEN `build_left` reaches the context segment
- THEN the selected percentage is empty, the numeric-presence gate is false, and neither the percentage nor the `⚑` marker is emitted

<!-- @trace
source: align-ctx-with-context-low
updated: 2026-08-14
code:
  - statusline-command.sh
  - lib/render.sh
  - lib/collect.sh
  - tests/run-tests.sh
-->

### Requirement: CTX_BAR configuration knob

The statusline SHALL expose a boolean `CTX_BAR` configuration knob at the top of statusline-command.sh, defaulting to enabled (`true`). When `CTX_BAR` is `true`, the context segment's full form SHALL be the 12-cell gradient bar followed by the colored percentage; when `CTX_BAR` is `false`, the full form SHALL be the `ctx:N%` text. The knob SHALL select only between these two FULL forms and SHALL NOT alter the bare `N%` compact form (which is identical under either setting) nor the cliff-marker behavior. The knob's value MUST be a shell boolean, because `build_left` evaluates it as a command (`if $CTX_BAR; then …`); it MUST be exactly `true` or `false` and SHALL NOT be any other string.

Interaction with hard rules: because the knob is executed as a command, a non-boolean value would fail the `if`; it MUST therefore stay a literal `true`/`false`; no `set -e`; the knob is read from the `READS` config contract that `render.sh` documents.

#### Scenario: Enabled knob renders the gradient bar

- **WHEN** `CTX_BAR` is `true`
- **THEN** the context full form MUST be the 12-cell gradient bar plus the colored percentage

#### Scenario: Disabled knob renders the text form

- **WHEN** `CTX_BAR` is `false`
- **THEN** the context full form MUST be the `ctx:N%` text and MUST NOT prepend a bar

#### Scenario: Knob does not affect the compact form

- **WHEN** `CTX_BAR` is toggled between `true` and `false` with the same selected context percentage
- **THEN** the bare `N%` compact form MUST be identical under both settings, and the cliff-marker behavior MUST be unchanged by the knob

<!-- @trace
source: align-ctx-with-context-low
updated: 2026-08-14
code:
  - statusline-command.sh
  - lib/render.sh
  - tests/run-tests.sh
-->
