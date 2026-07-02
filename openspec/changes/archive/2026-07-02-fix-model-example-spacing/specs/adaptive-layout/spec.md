## MODIFIED Requirements

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
