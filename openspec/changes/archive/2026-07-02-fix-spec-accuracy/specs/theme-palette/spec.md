## MODIFIED Requirements

### Requirement: Background Theme Resolution From Config

The active theme SHALL be resolved by `resolve_theme` in `lib/collect.sh`, which reads `.theme` from `~/.claude.json` (`$HOME/.claude.json`) and, when that value is absent or empty, falls back to reading `.theme` from `~/.claude/settings.json` (`$HOME/.claude/settings.json`). `resolve_theme` SHALL emit the literal `dark` only when `~/.claude/settings.json` is present and parseable but its `.theme` is absent or empty; when `~/.claude/settings.json` is missing or unparseable (a torn write) so `jq` errors, `resolve_theme` SHALL emit an empty line. `resolve_theme` SHALL always emit exactly one line (an empty line counts as that one line). When the emitted theme is empty — or is any non-empty value that does not contain `light` — `load_palette` SHALL treat it as a dark theme and select the palette by branching on `STYLE` (per the Dark Theme Style Selection requirement); only when `STYLE` is unset or unrecognized does the `STYLE` catch-all yield the `claude` native palette, so an empty theme resolves to the palette named by `STYLE` rather than necessarily `claude`. `start_theme_job` SHALL launch `resolve_theme` as a background job via process substitution onto a dedicated file descriptor with its stdin redirected from `/dev/null`, so the theme resolution never consumes the statusline stdin JSON; `read_theme` SHALL block only until that job reaches EOF, assign the single line into the `_theme` global, and close the descriptor. A torn or invalid read (for example `~/.claude.json` being mid-rewrite so `jq` fails to parse) SHALL be suppressed and SHALL degrade through the fallback chain — settings.json when it is present and parseable, otherwise an empty line that `load_palette` treats as a dark theme, selecting the palette by branching on `STYLE` (the `claude` native palette only when `STYLE` is unset or unrecognized) — affecting only the current frame, so a subsequent frame re-resolves the true theme.

#### Scenario: Theme comes from the primary config file

- **WHEN** `~/.claude.json` contains a non-empty `.theme`
- **THEN** `resolve_theme` SHALL emit that value and the settings.json fallback SHALL NOT override it

#### Scenario: Fallback to settings.json then dark

- **WHEN** `~/.claude.json` has no usable `.theme`
- **THEN** `resolve_theme` SHALL emit `.theme` from `~/.claude/settings.json` when that file is present and parseable with a usable value; SHALL emit the literal `dark` only when `~/.claude/settings.json` is present and parseable but its `.theme` is absent or empty; and SHALL emit an empty line (still exactly one line) when `~/.claude/settings.json` is missing or unparseable, in which case `load_palette` treats the empty non-`light` theme as a dark theme and selects the palette by branching on `STYLE` (yielding the `claude` native palette only when `STYLE` is unset or unrecognized)

#### Scenario: Background job never steals stdin

- **WHEN** `start_theme_job` launches the resolver
- **THEN** the job SHALL have its stdin redirected from `/dev/null` so it cannot consume the statusline stdin JSON, and `read_theme` SHALL obtain the theme by reading the job's file descriptor to EOF

##### Example: Torn read degrades for one frame

- **GIVEN** `~/.claude.json` is being rewritten by Claude Code and `jq` cannot parse it this frame
- **WHEN** `resolve_theme` runs
- **THEN** the `jq` error SHALL be suppressed, the empty result SHALL fall through to the settings.json / `dark` fallback for this one frame, and the next frame SHALL re-resolve the real theme once the file is intact
