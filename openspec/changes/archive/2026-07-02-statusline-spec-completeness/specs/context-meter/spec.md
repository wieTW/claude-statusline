## ADDED Requirements

### Requirement: CTX_BAR gradient context bar

When the `CTX_BAR` configuration knob is enabled, the context segment's full form SHALL prepend a fixed-width 12-cell solid progress bar before the percentage text, assembled in `build_left`. The number of filled cells SHALL be computed as `_pct * 12 / 100` (integer floor), where `_pct` is the `fmt_pct`-rounded percentage, matching `filled=$(( _pct * BAR_W / 100 ))`. Each filled cell SHALL be rendered as a solid background-colored block — a background SGR code immediately followed by a space so the cell paints edge-to-edge with no font gap — and each unfilled cell SHALL be rendered with the grey `TRK` track background followed by a space. The filled cells SHALL be colored by cell position in four equal zones (the quarters of the 12-cell bar): cells 0–2 green (`GR`), cells 3–5 yellow (`YL`), cells 6–8 orange (`OG`), cells 9–11 red (`RD`), matching the established `GR→YL→OG→RD` semantic ladder. Each zone's color MUST be applied by converting the palette role's foreground SGR prefix (`38;2;…`) to the corresponding background SGR prefix (`48;2;…`); the statusline SHALL NOT render the zone as foreground glyph text. After the 12 cells the bar SHALL emit a reset then a single space, then the percentage number colored by the budget-aware `ctx_color`, then `%`, then the cliff marker (if any). The palette roles `GR`, `YL`, `OG`, `RD`, and `TRK` MUST be sourced from `load_palette`, so the bar tracks the active theme rather than hard-coding colors.

Interaction with hard rules: the bar MUST be built only within `build_left`'s context segment; `LC_ALL=C` stays pinned so the integer `%.0f` rounding via `fmt_pct` and cell arithmetic are stable; no `set -e`; and the emitted bar MUST consist solely of the statusline's own SGR codes and spaces so `vis_width`'s cell accounting stays correct.

#### Scenario: Bar at 50% fills six cells across green and yellow zones

- **WHEN** `CTX_BAR` is enabled and `context_window.used_percentage` is 50
- **THEN** exactly 6 cells MUST be filled (cells 0–2 in the green zone, cells 3–5 in the yellow zone) rendered as background-colored blocks, and cells 6–11 MUST be drawn with the grey `TRK` track, with the orange and red zones showing no filled cells

##### Example: 50% bar

- GIVEN `CTX_BAR=true` and `used_percentage` = 50
- WHEN `build_left` builds the context segment
- THEN `filled` = `50 * 12 / 100` = 6
- THEN cells 0–2 use the `GR` background, cells 3–5 use the `YL` background, cells 6–11 use the `TRK` background
- THEN the bar is followed by a reset, a space, and the `ctx_color`-colored `50%`

#### Scenario: Full bar reaches the red zone

- **WHEN** `CTX_BAR` is enabled and `used_percentage` is 100
- **THEN** all 12 cells MUST be filled, so cells 9–11 render in the red (`RD`) background zone and no `TRK` track cell remains

##### Example: 100% bar reaches red

- GIVEN `CTX_BAR=true` and `used_percentage` = 100
- WHEN `build_left` builds the context segment
- THEN `filled` = 12, the last three cells (9–11) use the `RD` background, and every zone color appears in position order green→yellow→orange→red

#### Scenario: Zone color is driven by cell position, not fill count

- **WHEN** two frames render bars filled to different cell counts
- **THEN** each filled cell's color MUST be selected from its own position index against the fixed quarter boundaries (3, 6, 9), so a partially filled bar shows only the zones its filled cells reach and never recolors earlier cells based on the total fill

<!-- @trace
source: statusline-spec-completeness
updated: 2026-07-02
code:
  - statusline-command.sh
  - lib/render.sh
  - tests/run-tests.sh
-->

---
### Requirement: Context meter text and compact forms

The context segment SHALL provide, in addition to the `CTX_BAR` bar form, a text full form and a bare compact form, all assembled in `build_left`. When the `CTX_BAR` knob is disabled, the full form SHALL be the text `ctx:N%`, where `N` is the `fmt_pct`-rounded percentage, colored by the budget-aware `ctx_color`. A compact form SHALL always be produced as the bare `N%` — the same rounded percentage colored by `ctx_color`, without the bar prefix and without the `ctx:` label — and SHALL be produced regardless of the `CTX_BAR` setting. The 200k cost/cache cliff marker (the `⚑` glyph carrying the red alert role) SHALL be appended to every context form — the `CTX_BAR` bar full form, the `ctx:N%` text full form, and the bare `N%` compact form — and SHALL NOT be attached to only the bar form. The marker's presence SHALL remain governed solely by the upstream over-200k indicator per the existing 200k cliff marker requirement, independent of which of the three forms is being rendered.

Interaction with hard rules: all three forms MUST be composed only from the statusline's own SGR roles and the sanitized numeric percentage; the `⚑` glyph is one of the narrow multibyte characters folded by `vis_width`, so appending it to any form MUST NOT disturb width accounting; no `set -e`.

#### Scenario: CTX_BAR disabled yields the ctx:N% text form

- **WHEN** `CTX_BAR` is disabled and `used_percentage` rounds to `N`
- **THEN** the full form MUST be the text `ctx:N%` colored by `ctx_color`, with no bar prepended

##### Example: text full form at 42%

- GIVEN `CTX_BAR=false` and `used_percentage` = 42
- WHEN `build_left` builds the context segment
- THEN the full form is `ctx:42%` (the `ctx:` prefix present, no bar), colored by the budget-aware `ctx_color`

#### Scenario: Bare compact form omits both bar and ctx prefix

- **WHEN** any numeric `used_percentage` rounds to `N`
- **THEN** the compact form MUST be the bare `N%` colored by `ctx_color`, carrying neither the bar nor the `ctx:` label, and MUST be produced whether `CTX_BAR` is enabled or disabled

#### Scenario: Cliff marker appears on all three forms

- **WHEN** the upstream over-200k indicator is true and a numeric percentage is present
- **THEN** the `⚑` cliff marker MUST be appended equally to the bar full form, the `ctx:N%` text form, and the bare `N%` compact form, and MUST NOT be restricted to the bar form alone

##### Example: cliff marker across forms

- GIVEN the over-200k indicator = true, `used_percentage` = 88
- WHEN `build_left` composes the bar form, the `ctx:88%` text form, and the bare `88%` compact form
- THEN each of the three forms ends with the red-role `⚑` marker

<!-- @trace
source: statusline-spec-completeness
updated: 2026-07-02
code:
  - statusline-command.sh
  - lib/render.sh
  - tests/run-tests.sh
-->

---
### Requirement: Context segment suppression on absent or non-numeric usage

When `context_window.used_percentage` is absent or non-numeric such that `fmt_pct` yields an empty rounded value, the ENTIRE context segment SHALL be suppressed by `build_left` — no bar, no `ctx:N%` text form, no bare `N%` compact form, AND no `⚑` cliff marker — because the whole segment, including the cliff-marker computation, is gated behind a present numeric percentage. This suppression SHALL hold even when the upstream over-200k indicator is true: with no numeric percentage there is no context segment to host the marker, so the `⚑` marker SHALL NOT be emitted. This requirement reconciles the existing "cliff marker appears if and only if the over-200k indicator is true, regardless of `used_percentage`" wording, which presumes a present percentage — the "regardless of `used_percentage`" independence applies to the percentage's VALUE and its COLOR (any numeric value, red or normal, still shows the marker), and SHALL NOT be read to force the marker when the percentage is ABSENT.

Interaction with hard rules: the numeric-presence gate MUST use the `fmt_pct` empty-string result (produced for the `''` and `*[!0-9.]*` cases) rather than a separate parse; no `set -e`; and `used_percentage` reaches `build_left` only through `parse_input`'s single sanitized, positionally-ordered read.

#### Scenario: Absent percentage suppresses the whole segment

- **WHEN** `used_percentage` is absent from the stdin JSON
- **THEN** `fmt_pct` yields an empty value and `build_left` MUST emit no context segment at all — no bar, no text form, no compact form, and no `⚑` marker

#### Scenario: Non-numeric percentage suppresses the whole segment

- **WHEN** `used_percentage` is present but non-numeric
- **THEN** `fmt_pct` yields an empty value and the entire context segment, including any cliff marker, MUST be suppressed

#### Scenario: Over-200k true but percentage absent shows no marker

- **WHEN** the upstream over-200k indicator is true but `used_percentage` is absent or non-numeric
- **THEN** the `⚑` cliff marker MUST NOT be rendered, because there is no context segment to host it

##### Example: over-200k with no percentage

- GIVEN the over-200k indicator = true and `used_percentage` absent
- WHEN `build_left` reaches the context segment
- THEN `fmt_pct` produces an empty value, the `[ -n "$_pct" ]` gate is false, and neither the percentage nor the `⚑` marker is emitted

<!-- @trace
source: statusline-spec-completeness
updated: 2026-07-02
code:
  - statusline-command.sh
  - lib/render.sh
  - tests/run-tests.sh
-->

---
### Requirement: CTX_BAR configuration knob

The statusline SHALL expose a boolean `CTX_BAR` configuration knob at the top of `statusline-command.sh`, defaulting to enabled (`true`). When `CTX_BAR` is `true`, the context segment's full form SHALL be the 12-cell gradient bar followed by the colored percentage; when `CTX_BAR` is `false`, the full form SHALL be the `ctx:N%` text. The knob SHALL select only between these two FULL forms and SHALL NOT alter the bare `N%` compact form (which is identical under either setting) nor the cliff-marker behavior. The knob's value MUST be a shell boolean, because `build_left` evaluates it as a command (`if $CTX_BAR; then …`); it MUST be exactly `true` or `false` and SHALL NOT be any other string.

Interaction with hard rules: because the knob is executed as a command, a non-boolean value would fail the `if`; it MUST therefore stay a literal `true`/`false`; no `set -e`; the knob is read from the `READS` config contract that `render.sh` documents.

#### Scenario: Enabled knob renders the gradient bar

- **WHEN** `CTX_BAR` is `true`
- **THEN** the context full form MUST be the 12-cell gradient bar plus the colored percentage

#### Scenario: Disabled knob renders the text form

- **WHEN** `CTX_BAR` is `false`
- **THEN** the context full form MUST be the `ctx:N%` text and MUST NOT prepend a bar

#### Scenario: Knob does not affect the compact form

- **WHEN** `CTX_BAR` is toggled between `true` and `false` with the same `used_percentage`
- **THEN** the bare `N%` compact form MUST be identical under both settings, and the cliff-marker behavior MUST be unchanged by the knob

<!-- @trace
source: statusline-spec-completeness
updated: 2026-07-02
code:
  - statusline-command.sh
  - lib/render.sh
  - tests/run-tests.sh
-->

## MODIFIED Requirements

### Requirement: 200k cost/cache cliff marker

The statusline SHALL mark the genuine 200k cost/cache cliff when it has been crossed, using the upstream over-200k indicator supplied on stdin, and SHALL render this cliff marker independently of the percentage-based context coloring. The marker MUST appear if and only if the upstream over-200k indicator is true AND a numeric `used_percentage` is present, regardless of the numeric value or color of that percentage or of which budget the percentage threshold selected. The cliff marker text MUST be emitted only through the established rendering path (appended within `build_left`'s context segment using palette roles), and the over-200k indicator MUST be read via `parse_input` so it passes the single sanitization entry point with the positional `read` order preserved and the 256-codepoint cap applied.

Interaction with hard rules: reading the indicator MUST NOT introduce a second stdin reader (only `parse_input`'s jq consumes stdin); if the field is collected via any background job, that job MUST redirect stdin from `</dev/null`; no `set -e`; `LC_ALL=C` pinned; jq extraction MUST follow the existing single-pass array convention with explode/implode control-character filtering for any string-typed field.

#### Scenario: Over-200k indicator true shows the cliff marker

- **WHEN** the upstream over-200k indicator on stdin is true
- **THEN** the statusline MUST render the 200k cliff marker in the context segment, independently of the percentage color

##### Example: over-200k crossed

- GIVEN the stdin over-200k indicator = true and `used_percentage` = 70
- WHEN `build_left` builds the context segment
- THEN the cliff marker is present (driven solely by the indicator = true)
- THEN the marker's presence does NOT depend on whether 70% was colored normal or red

#### Scenario: Over-200k indicator false shows no cliff marker

- **WHEN** the upstream over-200k indicator on stdin is false or absent
- **THEN** the statusline MUST NOT render the 200k cliff marker, even when `used_percentage` is high

##### Example: not crossed at high percent

- GIVEN the stdin over-200k indicator = false and `used_percentage` = 95
- WHEN `build_left` builds the context segment
- THEN no cliff marker is rendered
- THEN the high percentage still drives `ctx_color` per the budget-aware threshold rule, unaffected by the absent marker


<!-- @trace
source: statusline-tokens-burn-and-fixes
updated: 2026-06-16
code:
  - statusline-command.sh
  - .spectra.yaml
  - lib/render.sh
  - lib/collect.sh
  - tests/run-tests.sh
  - CLAUDE.md
-->

