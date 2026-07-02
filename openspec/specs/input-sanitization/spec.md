# input-sanitization Specification

## Purpose

The input-sanitization capability defines the statusline's trust boundary: how every external string — stdin JSON fields, git output, and the last-message file — is cleaned before it can reach the terminal. It owns the single sanitization entry point (parse_input's control-character strip and 256-cap), the post-jq session_id allow-list and transcript_path traversal reject, the shared re-sanitizer for the two strings that bypass jq, the umask-077 private cache files, and the overarching invariant that only the script's own SGR codes ever reach the terminal.

## Requirements

### Requirement: Single sanitization entry point for stdin fields

Every external string field taken from the statusline's stdin JSON SHALL be sanitized in exactly one place — `parse_input`'s single jq pass — before any downstream code uses it, so that downstream code MAY assume the string contains only the script's own SGR codes. Within that pass each field SHALL first escape newline and carriage-return to the literal sequences `\n` and `\r` (keeping each value on one line so the positional `read` order stays aligned), then strip all remaining control characters by keeping only codepoints satisfying `. >= 32 and (. < 127 or . > 159)` — removing the C0 block, DEL (0x7F), AND the C1 block U+0080–U+009F (which includes U+009B, the 8-bit CSI, the same injection class as a raw ESC) — and finally cap the value to 256 codepoints. The control-character filtering MUST use jq `explode`/`implode` codepoint math, NOT a regex character class (jq's Oniguruma does not honor `\u` escapes and treats a control range as a literal class). There MUST be exactly one stdin reader (this jq pass); any other collected input MUST NOT consume stdin.

Interaction with hard rules: the positional `read` order in `parse_input` MUST stay one-for-one with the jq array; `LC_ALL=C` stays pinned; no `set -e`.

#### Scenario: A raw escape sequence in a field never reaches the terminal

- **WHEN** any stdin string field (for example `session_name`) contains an ESC/CSI control sequence such as `ESC[1m` or an 8-bit C1 CSI (U+009B)
- **THEN** the control bytes SHALL be stripped by `parse_input` before rendering, so the emitted line contains only the script's own SGR codes and its visible width matches what the terminal draws (no injection, no wrap)

##### Example: C1 CSI stripped

- GIVEN a `session_name` containing U+009B followed by `1m`
- WHEN `parse_input` sanitizes the field
- THEN U+009B is removed (it is in the C1 block, outside `. < 127 or . > 159`), leaving inert text capped at 256 codepoints

#### Scenario: The 256-codepoint cap bounds every field

- **WHEN** a stdin field is longer than 256 codepoints
- **THEN** it SHALL be truncated to 256 codepoints in `parse_input`, bounding `vis_width`'s O(n^2) ASCII scan under bash 3.2 (a load-bearing DoS guard, not cosmetics), while render's own `…` truncation still governs what is shown

<!-- @trace
source: statusline-input-hardening
updated: 2026-07-02
code:
  - lib/collect.sh
  - lib/render.sh
  - tests/run-tests.sh
  - CLAUDE.md
-->

---
### Requirement: session_id allow-list after jq

Because `session_id` is interpolated into a filesystem path (the per-session last-message file), an awk `-v sid=` assignment, and space-delimited cache records, it SHALL be constrained after the jq pass to the character set `[A-Za-z0-9_-]` only; a value containing ANY other character (including `/`, `.`, whitespace, backslash, or control bytes) SHALL be blanked to the empty string. Real Claude Code session identifiers (UUIDs) are a strict subset of this set and MUST NOT be rejected. A blanked `session_id` SHALL be treated by every downstream reader as a graceful no-op (skip the last-message file read, skip token accumulation), never as an error.

#### Scenario: A path-traversal-shaped session_id is neutralized

- **WHEN** `session_id` has a path-traversal or record-breaking shape such as `../secret` or `a b` or `a;b`
- **THEN** `session_id` SHALL be blanked, the per-session last-message file read SHALL be skipped, and no arbitrary file's contents SHALL leak into the line

##### Example: traversal session_id reads nothing

- GIVEN `session_id` = `../secret` and a file `secret` exists outside the last-msg directory
- WHEN the frame renders
- THEN the line is a single line, the segment that would read `~/.claude/last-msg/$session_id` is skipped, and the contents of `secret` never appear

#### Scenario: A valid UUID session_id is preserved

- **WHEN** `session_id` is a UUID such as `a1b2c3d4-5e6f-7890-abcd-ef1234567890`
- **THEN** it SHALL pass the allow-list unchanged and the session-keyed features (last-message file, token cache line) operate normally

<!-- @trace
source: statusline-input-hardening
updated: 2026-07-02
code:
  - lib/collect.sh
  - tests/run-tests.sh
  - CLAUDE.md
-->

---
### Requirement: transcript_path traversal rejection after jq

`transcript_path` (used to `tail` the transcript for the effort scan and to locate token-usage JSONL) SHALL be blanked after the jq pass when it contains a `..` path-traversal segment. A blanked `transcript_path` SHALL cause the dependent reads (effort-mode scan, token summation) to be skipped as a graceful no-op.

#### Scenario: A traversal transcript_path disables dependent reads

- **WHEN** `transcript_path` contains `..`
- **THEN** it SHALL be blanked, and neither the effort scan nor the token-usage summation SHALL read any file for that frame

<!-- @trace
source: statusline-input-hardening
updated: 2026-07-02
code:
  - lib/collect.sh
  - tests/run-tests.sh
  - CLAUDE.md
-->

---
### Requirement: Shared re-sanitization for jq-bypass strings

The two external strings that do NOT pass through `parse_input`'s jq — `git_branch` (produced by `git`) and the last-message file contents (read from disk) — SHALL both be re-sanitized through a single shared helper (`_sanitize_field`) that applies the same control-character filter as the jq entry point: strip C0 + DEL (single bytes) and the 2-byte UTF-8 C1 block (0xC2 0x80–0x9F, mirroring `select(. >= 32 and (. < 127 or . > 159))`), then cap to 256 bytes. Both call sites MUST use this one helper so the two filters cannot drift apart; the helper MUST set its result without a command-substitution fork on the hot path (it assigns the global `REPLY`, since bash 3.2 has no namerefs).

#### Scenario: A hostile git branch name cannot inject SGR

- **WHEN** the current git branch name contains an escape/CSI sequence or C1 byte
- **THEN** `git_branch` SHALL be re-sanitized via `_sanitize_field` before rendering, so it cannot inject SGR into stdout nor desync `vis_width` into a line wrap

##### Example: last-msg and git_branch share one filter

- GIVEN the last-message file and a git branch name each contain a C1 CSI byte
- WHEN `build_left` reads the last-message file and `collect_status` reads the branch
- THEN both are passed through the same `_sanitize_field`, producing identical stripping behavior with no second, divergent filter to maintain

<!-- @trace
source: statusline-input-hardening
updated: 2026-07-02
code:
  - lib/collect.sh
  - lib/render.sh
  - tests/run-tests.sh
  - CLAUDE.md
-->

---
### Requirement: Private cache files via umask

The functions that create the cross-session rate-limit cache and the token-usage cache — `_reconcile_core` and `tokens_update` — SHALL set `umask 077` before creating any cache file, temp file, or lock directory, so those artifacts are created with owner-only permissions (600 for files, 700 for directories). This prevents another user on a shared machine from reading the session identifiers and usage figures they hold. The `umask` call MUST remain scoped to a subshell (these functions run only via process substitution or as detached background jobs), so it does not alter the main shell's umask.

#### Scenario: The rate-limit cache is created owner-only

- **WHEN** a frame with rate-limit sync enabled writes the shared cache `~/.claude/sl-ratelimit-cache`
- **THEN** the cache file SHALL be created with mode 600 (owner read/write only)

##### Example: 600 after a sync frame

- GIVEN a fresh home with no existing cache
- WHEN one frame renders with `RL_SYNC=true` and five-hour rate-limit fields present
- THEN `~/.claude/sl-ratelimit-cache` exists with permission bits `600`

<!-- @trace
source: statusline-input-hardening
updated: 2026-07-02
code:
  - lib/collect.sh
  - tests/run-tests.sh
  - CLAUDE.md
-->

---
### Requirement: Only-our-SGR-reaches-the-terminal invariant

Taken together, the sanitization entry point plus the two jq-bypass re-sanitizers SHALL guarantee that only the script's own SGR (color) codes ever reach the terminal, so the rendered line cannot be an injection vector and `vis_width`'s visible-column accounting cannot be desynced by an external control byte into a wrap. As a companion display-safety clamp, the rate-limit "remaining" percentage SHALL be clamped to be never negative. This invariant is guarded by the existing regression cases H, L, N, P, Q, R, and S in the test suite.

#### Scenario: The defense-in-depth cases stay green

- **WHEN** the test suite runs the injection / traversal / overflow / clamp regression cases (H, L, N, P, Q, R, S)
- **THEN** they SHALL all pass, demonstrating that no external string can inject SGR, traverse a path, overflow/wrap the line, or drive a negative remaining percentage

<!-- @trace
source: statusline-input-hardening
updated: 2026-07-02
code:
  - lib/collect.sh
  - lib/render.sh
  - tests/run-tests.sh
  - CLAUDE.md
-->
