## ADDED Requirements

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
