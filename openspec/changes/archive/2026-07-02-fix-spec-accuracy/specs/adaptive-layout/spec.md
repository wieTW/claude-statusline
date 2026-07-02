## MODIFIED Requirements

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
