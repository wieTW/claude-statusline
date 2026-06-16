# context-meter Specification

## Purpose

TBD - created by archiving change 'statusline-tokens-burn-and-fixes'. Update Purpose after archive.

## Requirements

### Requirement: Model-context-size-aware usage alerting

The context-window usage meter SHALL evaluate its red alert threshold against the active model's context-window budget and SHALL NOT apply a single fixed 80% red threshold to every model. WHEN the model exposes an extended (1M) context window, THEN a given `used_percentage` MUST be evaluated against the larger budget, so a value such as 85% MUST NOT be flagged red merely for exceeding 80%. The meter MUST source the budget signal from the stdin JSON the statusline already parses (the model display name carrying a "1M context" marker, mirroring the existing `model/ (1M context)/ (1M)` handling in `build_left`), and MUST default to the standard (200k-class) budget when no extended-context signal is present.

Interaction with hard rules: the model/budget signal MUST be read only through `parse_input` (the single sanitization entry point), keeping `parse_input`'s positional `read` order one-for-one with the jq array and respecting the 256-codepoint cap; no `set -e`; `LC_ALL=C` stays pinned so `%.0f` percentage formatting and byte-counting are unchanged; any new collected field MUST follow the concurrency contract (a background job redirected from `</dev/null`). The numeric comparison MUST be integer-based after `fmt_pct` rounding, identical in mechanism to the existing `_pct -gt 80` test, only with a budget-derived threshold.

#### Scenario: 85% on a 1M-context model is not red

- **WHEN** the active model reports an extended (1M) context window and `context_window.used_percentage` is 85
- **THEN** the context percentage MUST be rendered in the normal (non-alert) text color and MUST NOT use the red alert color

##### Example: 1M model at 85%

- GIVEN model display name = `Opus 4.8 (1M context)` and `used_percentage` = 85
- WHEN `build_left` colors the context percentage
- THEN the threshold used is the 1M-budget threshold (not the fixed 80%), so 85 is below it
- THEN `ctx_color` = WH (normal text), NOT RD

#### Scenario: High percentage on a 200k-context model is red

- **WHEN** the active model reports a standard (200k-class) context window and `context_window.used_percentage` is 85
- **THEN** the context percentage MUST be rendered in the red alert color

##### Example: 200k model at 85%

- GIVEN model display name = `Sonnet 4.6` (no extended-context marker) and `used_percentage` = 85
- WHEN `build_left` colors the context percentage
- THEN the standard-budget threshold applies (the established 80% boundary for 200k-class models)
- THEN 85 exceeds the threshold, so `ctx_color` = RD

#### Scenario: Threshold selection is driven by budget, not a constant

- **WHEN** two frames render the identical `used_percentage` value differing only in whether the model carries the 1M-context marker
- **THEN** the standard-budget frame MUST be capable of flagging red at a percentage where the extended-budget frame MUST NOT, proving the threshold is budget-derived rather than a single fixed constant


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

---
### Requirement: 200k cost/cache cliff marker

The statusline SHALL mark the genuine 200k cost/cache cliff when it has been crossed, using the upstream over-200k indicator supplied on stdin, and SHALL render this cliff marker independently of the percentage-based context coloring. The marker MUST appear if and only if the upstream over-200k indicator is true, regardless of the value of `used_percentage` or of which budget the percentage threshold selected. The cliff marker text MUST be emitted only through the established rendering path (appended within `build_left`'s context segment using palette roles), and the over-200k indicator MUST be read via `parse_input` so it passes the single sanitization entry point with the positional `read` order preserved and the 256-codepoint cap applied.

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

---
### Requirement: Coloring and cliff marker are decoupled

The percentage-based context coloring and the 200k cliff marker SHALL be computed from independent inputs (`used_percentage` plus the model budget for coloring; the upstream over-200k indicator for the marker) and SHALL NOT be conflated, so that each can be true or false without forcing the state of the other. A red percentage MUST NOT imply the cliff marker, and the cliff marker MUST NOT imply a red percentage.

#### Scenario: Marker present while percentage is normal-colored

- **WHEN** the over-200k indicator is true on a 1M-context model whose `used_percentage` (85) is below the extended-budget red threshold
- **THEN** the percentage MUST render in normal color AND the cliff marker MUST still be shown

##### Example: decoupled states matrix

| model budget | used% | over-200k indicator | percentage color | cliff marker |
| --- | --- | --- | --- | --- |
| 1M | 85 | false | normal (not red) | absent |
| 1M | 85 | true | normal (not red) | present |
| 200k | 85 | false | red | absent |
| 200k | 85 | true | red | present |

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