#!/usr/bin/env bash
# Reference: https://github.com/Raymondhou0917/claude-code-resources/blob/master/starter-kit/06-statusline.md
# Claude Code statusline — reads JSON from stdin, prints a single colored status line.
# Left: path + resource state (model / ctx / quota) + last-message time; right: git / session, right-aligned to the terminal edge.
# A │ separator sits at the left/right junction (reads as " │ ", matching in-segment separators); when the line doesn't fit,
# the left part is kept whole and the name is truncated with … on the right — never overflows and gets hard-cut by the
# terminal (the vanishing-name bug is fixed).
#
# The entry point holds only config and the main flow; the implementation is split into two modules (collect vs render):
#   lib/collect.sh  stdin JSON parsing + theme / width / git / effort collected concurrently in the background
#   lib/render.sh   palette + single-line (left ── gap ── right) assembly and output
# Performance: every slow external command (jq/git/tail+grep) is parallelized; wall-clock = the slowest one (~20ms), not the sum.
# Hard rule: never use set -e anywhere (an FD read hitting EOF with no trailing newline returns rc=1 as a normal path; -e would kill it).
export LC_ALL=C   # pin the %.0f decimal format; avoids parse failures under comma-decimal locales

CTX_BAR=true       # ctx shows a gradient progress bar (█████░░░ N%); false falls back to plain text ctx:N%
NORM_THINKING=true # thinking normally on: warn in red (no-think) only when it's off, stay silent when on (set false to invert: show gray "thinking" only when on)
STYLE="tokyo-night-claude"     # color style: claude / tokyo-night / tokyo-night-claude / catppuccin / rose-pine (for dark themes; light themes always use the light palette)
RIGHT_ALIGN=true   # right-align the git/session part to the terminal edge; falls back to a │-separated join when width is unavailable or it doesn't fit
EDGE_PAD=3         # CC's statusline drawable area is N cols narrower than the width stty reports (overflow gets truncated to …);
                   # measured correction = 3 (aligning to the true terminal width eats 4 cols of the right part, keeping D-1 cols + …); tune here if a future CC build truncates again
JGAP=2             # minimum whitespace gap for the two parts to count as "separated": gap>=JGAP → plain whitespace, no junction │; <JGAP → the parts are too tight,
                   # so insert a │ separator (truncating the name to make room if needed). Larger → fewer │; set 1 → a │ appears as soon as they nearly touch
RL_SYNC=true       # cross-session rate-limit sync. CC freezes rate_limits at a session's start snapshot (upstream limitation): an old
                   # session keeps showing its stale used%, only the countdown moves. When true, every session records the max used% it
                   # sees per reset-window in ~/.claude/sl-ratelimit-cache; each render shows the max across all sessions, so a frozen
                   # session adopts the freshest value any session reported. Sound because fixed-window used% only climbs until resets_at
                   # (then the window rolls → a new key, usage restarts). false → trust only this session's (possibly frozen) value.

case $0 in */*) SL_DIR=${0%/*} ;; *) SL_DIR=. ;; esac   # pure-bash dirname, saves a fork
. "$SL_DIR/lib/collect.sh"
. "$SL_DIR/lib/render.sh"

start_theme_job    # t=0: kick off the theme background job first; it overlaps the stdin parse in the next step
start_width_job    # at the same instant, start the terminal-width job (for the right-align gap); also never touches stdin
parse_input        # main shell blocks parsing the stdin JSON (the only reader of stdin)
collect_status     # git×3 + effort scan collected concurrently, blocking until the slowest job finishes
read_theme         # the theme/width jobs are long done by now (covered by the two steps above), zero wait
read_width
reconcile_rates    # cross-session rate-limit sync: adopt the freshest used% any session has seen for this window

load_palette
build_left
build_right
render_line
