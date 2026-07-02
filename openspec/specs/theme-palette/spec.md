# theme-palette Specification

## Purpose

The theme-palette capability defines the colour system every other segment draws from. It owns the STYLE config knob that selects among five dark themes (claude, tokyo-night, tokyo-night-claude, catppuccin, rose-pine), the semantic role map each theme provides (primary/model/path text, the green-to-red status ladder, the structural greys, and the bar track), the fixed light palette applied whenever the active theme name contains "light", and how the active theme is resolved from ~/.claude.json (falling back to settings.json) in a background job.

## Requirements

### Requirement: Dark Theme Style Selection

The `STYLE` config knob (defined at the top of `statusline-command.sh`) SHALL select the active dark-theme colour palette applied by `load_palette` in `lib/render.sh`. The recognized values SHALL be exactly the five dark themes `claude`, `tokyo-night`, `tokyo-night-claude`, `catppuccin`, and `rose-pine`. `load_palette` SHALL branch on `STYLE` only when the resolved theme is a dark theme. Any `STYLE` value that is not one of the four explicitly-named alternatives `tokyo-night`, `tokyo-night-claude`, `catppuccin`, or `rose-pine` — including the literal `claude`, an empty value, or any unrecognized string — SHALL select the `claude` native palette via the catch-all branch, so `claude` is the effective default. Each of the five palettes SHALL be a complete role map that assigns every colour role (`WH`, `MD`, `CY`, `GR`, `YL`, `OG`, `RD`, `DM`, `SP`, `RD_DATA`, `TRK`); no role SHALL be left unset by any theme branch.

#### Scenario: A named dark theme selects its palette

- **WHEN** the resolved theme is a dark theme and `STYLE` equals one of `tokyo-night`, `tokyo-night-claude`, `catppuccin`, or `rose-pine`
- **THEN** `load_palette` SHALL populate all colour roles from that theme's branch and no other theme's values SHALL apply

#### Scenario: Unrecognized STYLE falls back to the claude palette

- **WHEN** the resolved theme is a dark theme and `STYLE` is `claude`, is empty, or is any value not matching the four named alternatives
- **THEN** `load_palette` SHALL apply the `claude` native palette from the catch-all branch and SHALL still assign every colour role

##### Example: catppuccin selection

- **GIVEN** `STYLE="catppuccin"` and a resolved theme name that does not contain `light`
- **WHEN** `load_palette` runs
- **THEN** `WH`, `MD`, `CY`, `GR`, `YL`, `OG`, `RD`, `DM`, `SP`, `RD_DATA`, and `TRK` SHALL all be set from the catppuccin (Mocha) branch

---
### Requirement: Colour Role Semantics

Every theme palette produced by `load_palette` SHALL define its colours by ROLE (semantic meaning), and each role's meaning SHALL be identical across all themes regardless of the concrete colour value chosen. `WH` SHALL be the primary/high-emphasis text foreground. `MD` SHALL colour the model name. `CY` SHALL colour the project path. `GR`, `YL`, `OG`, and `RD` SHALL form a four-step semantic ladder from healthy to critical, used for the rate-limit quota-remaining levels and the progress-bar zones, where `OG` additionally denotes effort=medium and `RD` additionally denotes the alert condition (low/no-think/context over its budget threshold). `DM` SHALL be the secondary/dim grey used for lower-emphasis text such as the timestamp, session name, and normal effort. `SP` SHALL be the structural grey used for separators and path `/` dividers. `RD_DATA` SHALL be the data red used for the git deleted-line count, a distinct tier from the alert `RD`. `TRK` SHALL be the progress-bar track background. These role assignments SHALL be independent of the exact RGB values, and each theme MUST supply a value for every role.

#### Scenario: Roles carry consistent meaning across themes

- **WHEN** any of the five dark themes or the light palette is active
- **THEN** `MD` SHALL always mean the model-name colour, `CY` SHALL always mean the project-path colour, and the `GR`→`YL`→`OG`→`RD` ladder SHALL always run healthy→critical, whatever concrete colours the active theme assigns

#### Scenario: Data red is a distinct tier from alert red

- **WHEN** the git segment renders a deleted-line count
- **THEN** it SHALL use `RD_DATA` rather than `RD`, so the deleted-line data colour is a separate role from the semantic alert colour even when a theme happens to give them similar hues

---
### Requirement: Light Theme Fixed Palette

When the resolved theme name contains the substring `light`, `load_palette` SHALL apply a single fixed light palette and SHALL NOT consult `STYLE`. The fixed light palette SHALL assign every colour role (`WH`, `MD`, `CY`, `GR`, `YL`, `OG`, `RD`, `DM`, `SP`, `RD_DATA`, `TRK`), including deriving `SP` from `DM` and `RD_DATA` from `RD`, so no role is left unset. Only a resolved theme name that does not contain `light` SHALL consult the `STYLE` dark-theme selection.

#### Scenario: A light theme ignores STYLE

- **WHEN** the resolved theme name contains `light` (for example `light` or `light-daltonized`)
- **THEN** `load_palette` SHALL use the fixed light palette and the value of `STYLE` SHALL have no effect on the resulting colours

#### Scenario: A dark theme name consults STYLE

- **WHEN** the resolved theme name does not contain `light` (for example the default `dark`)
- **THEN** `load_palette` SHALL select the palette by branching on `STYLE`

##### Example: STYLE is ignored under a light theme

- **GIVEN** the resolved theme is `light` and `STYLE="rose-pine"`
- **WHEN** `load_palette` runs
- **THEN** the fixed light palette SHALL apply and the rose-pine palette SHALL NOT be used

---
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
