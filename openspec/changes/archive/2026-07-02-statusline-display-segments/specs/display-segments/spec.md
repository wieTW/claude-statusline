## ADDED Requirements

### Requirement: Path Segment Content and Colour

`build_left` SHALL derive the path segment's display text from `cwd` and `project_dir` as follows: when `cwd` is a descendant of `project_dir` (matching the glob `"$project_dir"/*`), the text SHALL be the project directory's basename (`${project_dir##*/}`) concatenated with the remainder of `cwd` after the project prefix (`${cwd#"$project_dir"}`), producing `projectname/subpath`; otherwise the text SHALL be the basename of `cwd` (`${cwd##*/}`). When that basename is empty because `cwd` is the filesystem root `/`, the text SHALL fall back to the literal `cwd` value so `/` is kept as-is. The path segment SHALL render in bold cyan by prefixing the `CY` and `BOLD` roles (from `load_palette`) and resetting with `RS`. When `cwd` is empty the path segment SHALL be omitted. The path segment MUST always be the first segment of the left half.

#### Scenario: cwd under project directory renders project-relative
- **WHEN** `cwd` is `/Users/will/proj/lib/x` and `project_dir` is `/Users/will/proj`
- **THEN** the path text SHALL be `proj/lib/x` rendered with `CY`+`BOLD`

#### Scenario: cwd outside any project renders basename only
- **WHEN** `cwd` is `/Users/will/other` and `project_dir` is empty or unrelated
- **THEN** the path text SHALL be `other`

#### Scenario: filesystem root is preserved
- **WHEN** `cwd` is `/`
- **THEN** the path text SHALL be `/` (the empty-basename fallback keeps `cwd` verbatim)

##### Example: project-relative composition
- **GIVEN** `project_dir=/a/b/repo` and `cwd=/a/b/repo/src/lib`
- **WHEN** `build_left` composes the path
- **THEN** it emits `${CY}${BOLD}repo/src/lib${RS}`

### Requirement: Model Name Segment Content and Colour

`build_left` SHALL render the model name (`model`) in the `MD` role (from `load_palette`). In the full form the substring ` (1M context)` SHALL be rewritten to `(1M)` (via `${model/ (1M context)/(1M)}`) so the extended-context marker is shown compactly. A compact form SHALL also be captured as the first whitespace-delimited word of `model` (`${model%% *}`), also in the `MD` role, for use by adaptive-layout when it shrinks the model name before dropping it. When `model` is empty the model segment SHALL be omitted.

#### Scenario: 1M-context suffix rewritten in full form
- **WHEN** `model` is `Opus 4.8 (1M context)`
- **THEN** the full model segment SHALL read `Opus 4.8(1M)` in the `MD` colour

#### Scenario: compact form is the leading word
- **WHEN** `model` is `Opus 4.8 (1M context)`
- **THEN** the compact model segment SHALL read `Opus` in the `MD` colour

#### Scenario: absent model omitted
- **WHEN** `model` is empty
- **THEN** no model segment SHALL be produced

### Requirement: Effort Segment Content, Mode Recovery, and Colour

`build_left` SHALL render the effort segment only when the resolved effort level (`effort`) is non-empty. The displayed text SHALL default to the level itself, adjusted by `effort_mode`: when `effort_mode` is `ultracode` AND `effort` equals `xhigh` the text SHALL be `ultra`; when `effort_mode` is `auto` the text SHALL be `auto·<level>`; any other `effort_mode` (including an `ultracode` record whose level is not `xhigh`, treated as stale) SHALL leave the text as the plain level. The colour SHALL follow five-level semantics from `load_palette`: `low` SHALL use `RD`, `medium` SHALL use `OG`, and `high`, `xhigh`, `max`, and any level not recognised as `low` or `medium` SHALL use the neutral `DM` secondary grey (no semantic warm/alert colour is applied to them). Because the stdin JSON carries only the resolved level, `effort_mode` SHALL be recovered by `effort_scan` (invoked from `collect_all`/`collect_status`) which tails the transcript, matches `<local-command-stdout>` lines of the form `effort level (set to|to) <word>`, and takes the last such match; `effort_scan` SHALL run only when both a non-empty effort level and an existing transcript file are present.

#### Scenario: ultracode resolves to ultra only at xhigh
- **WHEN** `effort_mode` is `ultracode` and `effort` is `xhigh`
- **THEN** the effort text SHALL be `ultra` in the `DM` colour

#### Scenario: stale ultracode record shows the plain level
- **WHEN** `effort_mode` is `ultracode` but `effort` is `high`
- **THEN** the effort text SHALL be `high` (the mismatched record is not trusted) in the `DM` colour

#### Scenario: auto mode prefixes the resolved level
- **WHEN** `effort_mode` is `auto` and `effort` is `medium`
- **THEN** the effort text SHALL be `auto·medium` in the `OG` colour

#### Scenario: low and medium carry warm semantic colours
- **WHEN** `effort` is `low`
- **THEN** the effort text SHALL render in `RD`; and WHEN `effort` is `medium` it SHALL render in `OG`

#### Scenario: effort_mode recovered from transcript
- **WHEN** the transcript's most recent `<local-command-stdout>` reports `Effort level set to xhigh` and stdin resolves `effort` to `xhigh`
- **THEN** `effort_scan` SHALL emit `xhigh` as `effort_mode`'s source (the last match), enabling downstream mode-based display

##### Example: unknown level stays neutral
- **GIVEN** a future `effort` value `turbo` with no `effort_mode`
- **WHEN** `build_left` colours the effort segment
- **THEN** it uses `DM` (the catch-all), not a warm semantic colour

### Requirement: Thinking Indicator Segment

`build_left` SHALL show a thinking indicator only when the current thinking state is abnormal relative to the `NORM_THINKING` configuration knob, and SHALL stay silent when the `thinking` value is missing (empty). When `NORM_THINKING` is `true` (thinking is the norm) the segment SHALL render a `no-think` warning in the `RD` role only when `thinking` equals `false`, and SHALL be silent when thinking is on. When `NORM_THINKING` is `false` (thinking is not the norm) the segment SHALL render a `thinking` label in the `DM` role only when `thinking` equals `true`, and SHALL be silent when thinking is off. An empty `thinking` value MUST NOT produce any indicator under either configuration.

#### Scenario: normally-on, thinking off raises a red warning
- **WHEN** `NORM_THINKING` is `true` and `thinking` is `false`
- **THEN** the segment SHALL read `no-think` in the `RD` colour

#### Scenario: normally-on, thinking on stays silent
- **WHEN** `NORM_THINKING` is `true` and `thinking` is `true`
- **THEN** no thinking segment SHALL be produced

#### Scenario: normally-off, thinking on shows a calm label
- **WHEN** `NORM_THINKING` is `false` and `thinking` is `true`
- **THEN** the segment SHALL read `thinking` in the `DM` colour

#### Scenario: missing thinking value stays silent
- **WHEN** `thinking` is empty
- **THEN** no thinking segment SHALL be produced under either `NORM_THINKING` setting

### Requirement: Git Branch Segment

`build_right` SHALL render the git branch segment only when `git_branch` (collected by `collect_status`) is non-empty. The branch name SHALL come from `git symbolic-ref --short -q HEAD`, falling back to the short SHA from `git rev-parse --short HEAD` when HEAD is detached. Because this value comes from git and bypasses `parse_input`'s jq sanitization, it MUST be re-sanitized via `_sanitize_field` (stripping C0 + DEL + the 2-byte UTF-8 C1 block and capping to 256 bytes, the same filter as `parse_input`) before it reaches stdout. A dirty marker `*` SHALL be appended when the working tree has tracked changes (a non-empty `git diff --shortstat HEAD`) OR, absent tracked changes, when there is at least one untracked new file (`git ls-files --others --exclude-standard`). The branch name plus the dirty marker SHALL render in the `WH` primary-text role (from `load_palette`).

#### Scenario: branch with tracked changes shows dirty marker
- **WHEN** `git_branch` is `main` and `git diff --shortstat HEAD` is non-empty
- **THEN** the segment SHALL read `main*` in the `WH` colour

#### Scenario: detached HEAD falls back to short sha
- **WHEN** HEAD is detached so `symbolic-ref` fails
- **THEN** the branch text SHALL be the short SHA from `rev-parse --short HEAD`

#### Scenario: untracked-only file marks dirty
- **WHEN** there are no tracked changes but an untracked new file exists
- **THEN** the dirty `*` SHALL still be appended

#### Scenario: hostile branch name is neutralized
- **WHEN** a branch name contains raw control/escape bytes
- **THEN** `_sanitize_field` SHALL strip them before the branch reaches stdout so only the script's own SGR codes are emitted

### Requirement: Git Diffstat Segment

`build_right` SHALL append a diffstat to the git segment derived from `git diff --shortstat HEAD` (via `collect_status`'s `git_ins`/`git_del`), which by construction excludes untracked new-file lines. When insertions are present the segment SHALL show `+N` in the `GR` role; when deletions are present it SHALL show `-N` in the `RD_DATA` data-red role. When both are present they SHALL be joined by a `/` rendered in the `SP` structural-grey role, producing `+N/-N`. The diffstat SHALL be omitted when there are no counted insertions or deletions.

#### Scenario: both insertions and deletions joined by slash
- **WHEN** `git_ins` is `12` and `git_del` is `3`
- **THEN** the segment SHALL read `+12` in `GR`, `/` in `SP`, `-3` in `RD_DATA`

#### Scenario: insertions only
- **WHEN** `git_ins` is `5` and `git_del` is empty
- **THEN** the segment SHALL append ` +5` in `GR` with no `/` and no deletion part

#### Scenario: untracked files excluded from counts
- **WHEN** the only changes are untracked new files
- **THEN** `git_ins`/`git_del` SHALL be empty and no diffstat SHALL be shown (the dirty `*` still applies per the branch segment)

### Requirement: Worktree Segment

`build_right` SHALL render a worktree segment only when `worktree_name` is non-empty, formatted as `[wt:NAME]` in the `DM` dim role (from `load_palette`).

#### Scenario: worktree name shown in brackets
- **WHEN** `worktree_name` is `feature`
- **THEN** the segment SHALL read `[wt:feature]` in the `DM` colour

#### Scenario: absent worktree omitted
- **WHEN** `worktree_name` is empty
- **THEN** no worktree segment SHALL be produced

### Requirement: Session Name Segment

`build_right` SHALL render the session name (`session_name`) only when it is non-empty, in the `DM` dim role (from `load_palette`), and MUST place it as the last (rightmost) segment of the right half so it is the least prominent; within the right half its tail is the first cut when the right string is head-truncated (step 11), before the name is dropped (step 12).

#### Scenario: session name rendered dim and rightmost
- **WHEN** `session_name` is `my-session` and both git and worktree segments are present
- **THEN** `my-session` SHALL render in `DM` after the git and worktree segments in the right half

#### Scenario: absent session name omitted
- **WHEN** `session_name` is empty
- **THEN** no session segment SHALL be produced

### Requirement: Inter-Segment Separator

`render_line` SHALL join adjacent base segments within each half using the separator `SEP`, defined as a space, a `│` glyph, and a space (`" │ "`), coloured with the `SP` structural-grey role and reset with `RS`. In palettes where `SP` is not defined independently (the light palette) `SP` SHALL equal the `DM` role, so the separator uses the structural greys in every theme. The separator MUST appear only between two present segments and MUST NOT be emitted before the first or after the last segment of a half (handled by `join_parts`).

#### Scenario: two segments joined by grey separator
- **WHEN** the left half contains a path segment and a model segment
- **THEN** they SHALL be joined by `${SP} │ ${RS}` with no leading or trailing separator

#### Scenario: single segment has no separator
- **WHEN** a half contains exactly one segment
- **THEN** `join_parts` SHALL emit that segment alone with no `│`

<!-- @trace
source: statusline-display-segments
updated: 2026-07-02
code:
  - lib/render.sh
  - lib/collect.sh
-->

