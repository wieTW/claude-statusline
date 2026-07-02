# adaptive-layout Specification

## Purpose

The adaptive-layout capability governs how the single status line fits the terminal's drawable width without ever wrapping or being hard-cut. It defines the right-alignment of the git/session half, the `│` junction that appears only when the two halves nearly touch, and the fixed 14-step sacrifice order that shrinks and truncates segments before dropping them — guaranteeing that the core (the path basename plus the context percentage) always survives, even at a 1–2 column width.

## Requirements

### Requirement: Drawable-width invariant

When the drawable terminal width, defined as `term_cols - EDGE_PAD`, is positive (`term_cols > EDGE_PAD`), the rendered status line MUST NOT exceed it, with perl present or absent. When `term_cols` is less than or equal to `EDGE_PAD`, so the drawable width is zero or negative, the numeric bound does not apply and the renderer MUST guarantee only the single-physical-row property. At every terminal width the renderer MUST NOT wrap the single line into two physical rows. This invariant is the topmost constraint and every degradation tier below it MUST hold it.

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

---
### Requirement: Per-segment priority and forms

Each renderable segment MUST be assigned a fixed priority and, where a shorter rendering exists, a compact form in addition to its full form. The renderer MUST prefer rendering a segment in its compact form (shrink or truncate) over dropping that segment, and MUST use a segment's priority only to decide drop order as a last resort. The core, defined as the path basename plus the context percentage, MUST be assigned the highest priority and MUST be exempt from every drop tier.

#### Scenario: compact form preferred over drop

- **WHEN** a segment that has both a compact and a full form does not fit in its full form, but its compact form fits
- **THEN** the renderer emits the compact form of that segment
- **AND** the renderer does not drop the segment

##### Example: model name compacts instead of dropping

- GIVEN the model segment `Opus 4.8(1M)` does not fit in full form but its compact form `Opus` fits in the remaining width
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
| model name | `Opus 4.8(1M)` | `Opus` |
| session name | full name | head form with `…` |
| 5-hour quota | `2H2m 76%` | `76%` (countdown dropped, burn alarm kept) |

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
9. Shorten the model name (for example `Opus 4.8(1M)` to `Opus`).
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

- GIVEN the model name `Opus 4.8(1M)` and a width where step 8 has been applied but the line still overflows
- WHEN the renderer reaches model handling
- THEN step 9 shortens it to `Opus` first
- AND only if the line still overflows does step 10 drop the model name entirely

---
### Requirement: Core always remains

The context percentage is the single core element that MUST always be present in the emitted line at every terminal width, including the pathological 1–2 column case. The renderer MUST NOT drop, blank, or fully truncate away the context percentage as part of any degradation step. The path basename is head-truncated on a best-effort basis to fit ahead of the percentage; it is an optional companion that the renderer SHALL fully sacrifice at very narrow drawable widths — roughly `avail < ctx-width + 3`, where the remaining path budget falls below two columns — so that the percentage always survives.

#### Scenario: core survives the narrowest terminal

- **WHEN** the terminal is so narrow that every droppable and compactable segment has been removed or collapsed
- **THEN** the emitted line still contains the context percentage, with the path basename retained ahead of it only as far as the drawable width allows
- **AND** the line's visible width is less than or equal to `term_cols - EDGE_PAD`

#### Scenario: core survives a 1–2 column terminal without overflow

- **WHEN** `term_cols` is 1 or 2 and perl is unavailable
- **THEN** the renderer emits a line that does not wrap and does not exceed the drawable width using the pure-bash degraded truncation fallback
- **AND** the context percentage is retained, with the path basename head-truncated into whatever budget remains and dropped entirely when no path budget remains, the percentage never removed

##### Example: core at minimal width

- GIVEN `term_cols = 20`, `EDGE_PAD = 3`, a deep path, and a full original segment set
- WHEN the renderer degrades to the core-only tier
- THEN the emitted line contains the context percentage `N%`, with the path basename head-truncated to fit ahead of it while the drawable width still admits a path cell
- AND its visible width is `<= 17`

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

---
### Requirement: Right-alignment mode and fallback join (RIGHT_ALIGN)

The `RIGHT_ALIGN` config knob, defined at the top of the entry script and read by `render_line`, SHALL govern whether the right half (git · worktree · session name) is right-aligned to the drawable right edge. When `RIGHT_ALIGN` is true AND the terminal width is available as a positive `term_cols`, the renderer MUST right-align the right half so that its trailing edge sits at the drawable width `term_cols - EDGE_PAD`, separating the two halves with either a plain whitespace gap or a `│` junction as the gap width dictates. When `RIGHT_ALIGN` is false, OR when the terminal width is unavailable (`term_cols` absent, zero, or non-positive), the renderer MUST NOT attempt width-based right-alignment and MUST instead fall back to a simple `│`-separated join, joining the two halves with a `" │ "` separator (a space, the `│` junction, and a space). In that fallback path, when exactly one half is non-empty, the renderer MUST print the non-empty half alone with no separator.

#### Scenario: right-aligned to the drawable edge when enabled and width is known

- **WHEN** `RIGHT_ALIGN` is true and `term_cols` is a positive measurable width
- **THEN** the renderer right-aligns the right half so its trailing visible edge lands at `term_cols - EDGE_PAD`
- **AND** the left half stays flush to the start of the line

#### Scenario: fallback join when RIGHT_ALIGN is disabled

- **WHEN** `RIGHT_ALIGN` is false
- **THEN** the renderer joins the left and right halves with a single `" │ "` separator instead of right-aligning
- **AND** it performs no drawable-width measurement or padding

#### Scenario: fallback join when terminal width is unavailable

- **WHEN** `RIGHT_ALIGN` is true but `term_cols` is absent, zero, or non-positive
- **THEN** the renderer cannot measure width and MUST fall back to the `" │ "`-separated join of the two halves
- **AND** it does not right-align

#### Scenario: a single non-empty half prints alone in the fallback path

- **WHEN** the renderer is on the fallback join path and exactly one of the two halves is empty
- **THEN** the renderer prints the non-empty half by itself
- **AND** no `│` separator is emitted

##### Example: fallback join of both halves

- GIVEN `RIGHT_ALIGN=false`, left half `~/proj  Opus  6%`, and right half `main  session-a`
- WHEN `render_line` assembles the line
- THEN the emitted line is the left half, then `" │ "`, then the right half, with no right-alignment padding

---
### Requirement: EDGE_PAD and JGAP tunable knobs

`EDGE_PAD` and `JGAP` SHALL be documented, tunable knobs defined at the top of the entry script and read by `render_line`. This requirement fixes their KNOB SEMANTICS only; the concrete drawable-width and gap-to-junction rendering rules they parameterize are already normative in other requirements and are cross-referenced here rather than restated.

`EDGE_PAD` is a documented tunable knob whose magnitude reserves proportionally more or fewer right-edge columns: a larger value reserves more columns at the right edge and a smaller value reserves fewer. Its effect flows through the drawable-width formula `term_cols - EDGE_PAD` defined by the "Drawable-width invariant" requirement, which this requirement cross-references and MUST NOT redefine.

`JGAP` is a documented tunable threshold that shifts the whitespace gap at which the `│` junction appears: raising `JGAP` makes the junction appear at wider gaps (fewer plain-whitespace frames), and lowering it toward 1 makes the junction appear only as the two halves nearly touch. The gap-to-junction rendering rule itself is defined by the "Width-tiered rendering scenarios" and "Fixed sacrifice order" requirements, which this requirement cross-references rather than restates. When the gap is less than `JGAP` AND both halves are retained, the renderer MUST insert a `│` junction; because the fixed sacrifice order can drop the right half (right budget below 2 columns), a frame with no retained right half has no junction to insert. Both knobs SHALL be adjustable without editing `render_line`.

#### Scenario: EDGE_PAD magnitude reserves right-edge columns

- **WHEN** `EDGE_PAD` is raised
- **THEN** the drawable width defined by the "Drawable-width invariant" requirement (`term_cols - EDGE_PAD`) shrinks, reserving proportionally more columns at the right edge
- **AND** lowering `EDGE_PAD` reserves proportionally fewer right-edge columns

#### Scenario: JGAP threshold shifts where the junction appears

- **WHEN** `JGAP` is raised
- **THEN** the gap-to-junction threshold from the "Width-tiered rendering scenarios" rule shifts so the `│` junction appears at wider gaps, producing fewer plain-whitespace frames
- **AND** lowering `JGAP` toward 1 shifts the threshold so the junction appears only as the two halves nearly touch

#### Scenario: no junction when the sacrifice order has dropped the right half

- **WHEN** the computed gap is less than `JGAP` but the fixed sacrifice order has already dropped the right half (right budget below 2 columns)
- **THEN** the renderer inserts no `│` junction, because there is no retained right half to separate the left half from
- **AND** the renderer inserts the junction only when the gap is less than `JGAP` AND both halves are retained

##### Example: default knob values and their effect

- GIVEN `EDGE_PAD = 3`, `JGAP = 2`, and `term_cols = 140`
- WHEN the renderer computes layout with both halves retained
- THEN the drawable width is `137` per the "Drawable-width invariant", a both-halves-retained gap of `2` or more columns renders as plain whitespace, and a gap of `1` or `0` columns inserts a `│` junction

<!-- @trace
source: statusline-spec-completeness
updated: 2026-07-02
code:
  - statusline-command.sh
  - lib/render.sh
  - tests/run-tests.sh
  - CLAUDE.md
-->
