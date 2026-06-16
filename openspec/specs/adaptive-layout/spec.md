# adaptive-layout Specification

## Purpose

TBD - created by archiving change 'statusline-tokens-burn-and-fixes'. Update Purpose after archive.

## Requirements

### Requirement: Drawable-width invariant

The rendered status line MUST NOT exceed the drawable terminal width, defined as `term_cols - EDGE_PAD`, at any terminal width, with perl present or absent, and including the pathological 1–2 column case. The renderer MUST achieve this without ever wrapping the single line into two physical rows. This invariant is the topmost constraint and every degradation tier below it MUST hold it.

The visible-column accounting that enforces this invariant (`vis_width`) MUST count bytes under the pinned `LC_ALL=C` locale and MUST assume every escape sequence reaching it is a self-emitted SGR code that ends in `m`; the design relies on `parse_input` being the only external-string sanitizer and on the 256-codepoint cap that bounds `vis_width`'s O(n²) ASCII strip. The renderer MUST NOT use `set -e`, and every background collection job feeding the renderer MUST redirect stdin from `/dev/null`.

#### Scenario: line stays within the drawable width on a wide terminal

- **WHEN** the full segment set is rendered at a terminal width far wider than the assembled content
- **THEN** the visible width of the emitted line is less than or equal to `term_cols - EDGE_PAD`
- **AND** no `…` truncation suffix is present on any segment

#### Scenario: line stays within the drawable width on a narrow terminal

- **WHEN** the assembled content is wider than `term_cols - EDGE_PAD`
- **THEN** the renderer degrades per the fixed sacrifice order until the emitted line's visible width is less than or equal to `term_cols - EDGE_PAD`
- **AND** the terminal does not hard-wrap the line into a second row

#### Scenario: width accounting overestimates safely, never underestimates

- **WHEN** `vis_width` estimates the visible width of a segment containing non-ASCII or wide characters
- **THEN** the estimate is greater than or equal to the true visible width
- **AND** the resulting right-align gap only shrinks, so the line never grows past the drawable width

##### Example: drawable width derivation

- GIVEN `term_cols = 140` and `EDGE_PAD = 3`
- WHEN the renderer computes available width
- THEN `avail = 137`, and the emitted line's visible width is `<= 137`


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
### Requirement: Per-segment priority and forms

Each renderable segment MUST be assigned a fixed priority and, where a shorter rendering exists, a compact form in addition to its full form. The renderer MUST prefer rendering a segment in its compact form (shrink or truncate) over dropping that segment, and MUST use a segment's priority only to decide drop order as a last resort. The core, defined as the path basename plus the context percentage, MUST be assigned the highest priority and MUST be exempt from every drop tier.

#### Scenario: compact form preferred over drop

- **WHEN** a segment that has both a compact and a full form does not fit in its full form, but its compact form fits
- **THEN** the renderer emits the compact form of that segment
- **AND** the renderer does not drop the segment

##### Example: model name compacts instead of dropping

- GIVEN the model segment `Opus 4.8 (1M)` does not fit in full form but its compact form `Opus` fits in the remaining width
- WHEN the renderer handles the model segment
- THEN the renderer emits `Opus` and SHALL NOT drop the model segment

#### Scenario: drop used only when no form fits

- **WHEN** a segment has been reduced to its compact form and still does not fit
- **THEN** the renderer drops that segment according to the fixed sacrifice order
- **AND** the renderer continues with the next-narrower tier

##### Example: segments that carry a compact form

| Segment | Full form | Compact form |
| --- | --- | --- |
| context bar | 12-cell gradient bar + `N%` | plain `N%` text |
| model name | `Opus 4.8 (1M)` | `Opus` |
| session name | full name | head form with `…` |
| 5-hour quota | `2H2m 76%` | `76%` (countdown dropped, burn alarm kept) |


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
### Requirement: Fixed sacrifice order

As available drawable width decreases, the renderer MUST degrade by removing or compacting segments in exactly the following fixed order, from the widest configuration down to the narrowest, applying each step only when the prior configuration still does not fit. The renderer MUST NOT reorder, skip ahead, or apply a later step before an earlier one when an earlier one would suffice.

The order MUST be:

1. Close the inter-half whitespace gap into a `│` junction.
2. Drop the git diffstat (`+N`/`-N`).
3. Drop the worktree segment.
4. Collapse the context bar to plain `N%` text.
5. Drop the git branch.
6. Drop the last-message time segment.
7. Drop the 7-day quota segment.
8. Drop the token segment entirely (session token and subagent token together).
9. Shorten the model name (for example `Opus 4.8 (1M)` to `Opus`).
10. Drop the model name.
11. Truncate the session name with `…`.
12. Drop the session name.
13. Collapse the 5-hour quota to remaining-percent only, dropping the reset countdown while keeping any burn alarm.
14. Core only: the path basename plus the context percentage.

#### Scenario: earliest sufficient step is applied

- **WHEN** the full configuration overflows by an amount that the gap-to-junction collapse alone resolves
- **THEN** the renderer applies only step 1 and emits a line with a `│` junction and all segments still present
- **AND** the renderer does not drop the git diffstat or any later segment

#### Scenario: steps applied cumulatively until it fits

- **WHEN** the line still overflows after step 1
- **THEN** the renderer applies step 2 (drop diffstat), then step 3, and so on in order, stopping at the first step whose result fits within `term_cols - EDGE_PAD`

#### Scenario: token segment drops as one unit

- **WHEN** the renderer reaches step 8
- **THEN** both the session token count and the subagent token count are removed together
- **AND** neither is shown without the other

#### Scenario: 5-hour quota collapses before the core

- **WHEN** every step through 12 has been applied and the line still overflows
- **THEN** the renderer applies step 13, collapsing the 5-hour quota to remaining-percent only and dropping its reset countdown
- **AND** any active burn alarm on the 5-hour quota is retained

##### Example: order positions for representative segments

| Step | Action | Segment affected |
| --- | --- | --- |
| 1 | collapse gap to junction | inter-half spacing |
| 2 | drop | git diffstat `+N`/`-N` |
| 4 | compact | context bar to `N%` |
| 7 | drop | 7-day quota |
| 8 | drop | token (session + subagent) |
| 9 | compact | model name |
| 13 | compact | 5-hour quota to remaining% only |
| 14 | retain | core (path basename + context%) |


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
### Requirement: Shrink and truncate preferred over drop

Within the fixed sacrifice order, every step that compacts a segment (collapsing the context bar, shortening the model name, truncating the session name, collapsing the 5-hour quota) MUST be ordered to occur for that segment before that same segment is dropped, so that the renderer always exhausts the shrink option before the drop option for any segment that has both. A priority-based drop MUST NOT be applied to a segment while a not-yet-used compact form of that same segment would make the line fit.

#### Scenario: context bar shrinks before any later drop of context

- **WHEN** the context bar in full form does not fit
- **THEN** the renderer first collapses the context bar to plain `N%` text (step 4)
- **AND** the context percentage is never dropped, because it is part of the core

#### Scenario: session name truncates before it is dropped

- **WHEN** the session name does not fit at step 11
- **THEN** the renderer head-truncates the session name with a trailing `…` to the available width before it is dropped at step 12
- **AND** the truncation keeps the front of the name and cuts the tail

##### Example: model name shrink precedes model drop

- GIVEN the model name `Opus 4.8 (1M)` and a width where step 8 has been applied but the line still overflows
- WHEN the renderer reaches model handling
- THEN step 9 shortens it to `Opus` first
- AND only if the line still overflows does step 10 drop the model name entirely


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
### Requirement: Core always remains

The core, consisting of the path basename and the context percentage, MUST always be present in the emitted line at every terminal width, including the pathological 1–2 column case. The renderer MUST NOT drop, blank, or fully truncate away either the path basename or the context percentage as part of any degradation step.

#### Scenario: core survives the narrowest terminal

- **WHEN** the terminal is so narrow that every droppable and compactable segment has been removed or collapsed
- **THEN** the emitted line still contains the path basename and the context percentage
- **AND** the line's visible width is less than or equal to `term_cols - EDGE_PAD`

#### Scenario: core survives a 1–2 column terminal without overflow

- **WHEN** `term_cols` is 1 or 2 and perl is unavailable
- **THEN** the renderer emits a line that does not wrap and does not exceed the drawable width using the pure-bash degraded truncation fallback
- **AND** the core content is retained as far as the drawable width allows, with the path basename head-truncated rather than the context percentage removed

##### Example: core at minimal width

- GIVEN `term_cols = 20`, `EDGE_PAD = 3`, a deep path, and a full original segment set
- WHEN the renderer degrades to the core-only tier
- THEN the emitted line contains the path basename and `N%`
- AND its visible width is `<= 17`


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
### Requirement: Width-tiered rendering scenarios

The renderer MUST produce a visible segment set that monotonically decreases as the drawable width decreases: a segment present at a given width MUST also be present at every wider width, and the core MUST be present at every width. Wide terminals MUST show the full set with a plain whitespace gap and no `│` junction; medium widths MUST show a `│` junction with one or more later segments dropped or compacted; narrow widths MUST show the core only.

#### Scenario: wide terminal shows everything

- **WHEN** the drawable width exceeds the full assembled content by at least `JGAP` columns
- **THEN** the renderer emits every segment in full form separated by a plain whitespace gap
- **AND** no `│` junction is inserted

#### Scenario: medium width shows junction plus partial drops

- **WHEN** the drawable width is between the wide and narrow tiers
- **THEN** the renderer inserts a `│` junction and applies one or more of the fixed sacrifice steps (for example dropping the diffstat, the worktree, or collapsing the context bar)
- **AND** the higher-priority segments and the core remain visible

#### Scenario: narrow terminal shows core only

- **WHEN** the drawable width admits only the core
- **THEN** the renderer emits the path basename and the context percentage and nothing else
- **AND** the emitted line does not wrap or exceed the drawable width

##### Example: only the core fits

- GIVEN `term_cols = 24`, `EDGE_PAD = 3`, basename `claude-statusline`, and context `42%`
- WHEN the drawable width admits only the core
- THEN the emitted line shows the path basename and `42%` and no other segment, with visible width `<= 21`

#### Scenario: visible set is monotonic across widths

- **WHEN** the same input is rendered at a wider width W1 and a narrower width W2 (W2 < W1)
- **THEN** the set of segments visible at W2 is a subset of the set visible at W1
- **AND** the core is in both sets

##### Example: illustrative width-to-segment mapping

This table is illustrative; exact breakpoints depend on the assembled content length and `EDGE_PAD`/`JGAP`.

| Drawable width | Visible segment set |
| --- | --- |
| 160 | path · model · effort · thinking · ctx bar · 5h quota · 7d quota · tokens · last-msg, plain gap, git+diffstat · worktree · session (full) |
| 120 | path · model · effort · ctx bar · 5h quota · 7d quota · tokens · last-msg, `│`, git (no diffstat) · worktree · session |
| 90 | path · model · ctx `N%` · 5h quota · 7d quota · last-msg, `│`, git · session |
| 60 | path · model · ctx `N%` · 5h quota, `│`, git · session (truncated `…`) |
| 30 | path · ctx `N%` · 5h `N%`, `│`, git |
| 17 | path basename · ctx `N%` (core only) |

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