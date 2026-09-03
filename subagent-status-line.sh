#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # cross-module globals, same contract lib/collect.sh and lib/render.sh use:
#   _w / _line / _trunc / _tok / _mname / _win / _content are set by one function and read by another, and
#   STYLE / SEP / _theme are read by render.sh. Lint via: shellcheck -x subagent-status-line.sh
# subagent-status-line.sh — Claude Code's SUBAGENT status line: the rows that list the subagents currently
# running. Sibling of statusline-command.sh, which owns the single session line; the two never touch.
# Wire it up by pointing the `subagentStatusLine.command` setting in ~/.claude/settings.json at this
# script's absolute path. That setting takes only `type` and `command` — there is no refresh-interval or
# padding knob, so the width is bounded by the payload's own `columns`.
#
# Contract: one subagent status JSON on stdin; JSON Lines on stdout — one {"id":…,"content":…} record per
# task row this script takes over, NOT an array. A task id we do not print keeps Claude Code's own default
# row. That guaranteed fallback is this script's ONLY error path: whenever something about a row is
# unusable we stay silent about that row rather than draw something that might be wrong. `content` carries
# ANSI colour codes and is rendered verbatim.
#
# Row layout — three segments joined by the same " │ " separator the single line uses:
#
#     <description> │ <Model>(<Window>) │ <tokens> │ <label>
#     實作 subagent 狀態列 │ Opus 5(1M) │ 262k │ Updating sa3b expectation in run-tests.sh
#
# The label is dropped when it only repeats the description (Claude Code fills it that way while an agent
# is starting), and the token segment is dropped when there is no usable non-zero count. Under a narrow
# terminal the label is truncated first and the description second; the model and token segments are never
# truncated, because they are the two things this row was added to show.
#
# What the payload can and cannot say (measured against 152 captured frames / 164 task rows, 2026-09-03):
# each task carries id / type / status / description / label / startTime / model / contextWindowSize /
# tokenCount / cwd. `type` is always the literal "local_agent" and the top-level `agent_type` is the MAIN
# session's profile — the subagent's own agent type is simply NOT in the payload, so this script does not
# try to show it and does not infer it from anywhere else.
#
# Hard rules inherited from statusline-command.sh (see CLAUDE.md): never `set -e`; every background job
# gets </dev/null (a job inherits the stdin JSON pipe and only the parsing jq may read it); LC_ALL=C pinned
# at the top; every external string is control-character stripped and capped at 256 codepoints (vis_width's
# ASCII strip is O(n^2) under macOS bash 3.2, so an uncapped multi-KB field would stall every frame); the
# jq control-character filter uses explode/implode and never a regex (jq's Oniguruma does not honour \u
# escapes inside a character class and would gut the field instead of cleaning it); bash 3.2, no bash-4+.
export LC_ALL=C

SA_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# lib/render.sh is pure function definitions with no side effects at source time; we borrow load_palette,
# vis_width, trunc_head, join_parts and fmt_tok so both lines share one palette and one width model.
# lib/collect.sh is deliberately NOT sourced: it carries path constants bound to the real $HOME, and its
# reconcile_* / tokens_* helpers write shared cache files that every live session reads.
# shellcheck source=lib/render.sh
. "$SA_DIR/lib/render.sh"


# Theme resolution, read-only, mirroring resolve_theme in lib/collect.sh (which we may not source): .theme
# from ~/.claude.json, falling back to ~/.claude/settings.json. Always emits exactly one line; an empty
# line is the dark default, which is what load_palette does with an unrecognised value anyway.
sa_resolve_theme() {
    local t
    t=$(jq -r '.theme // empty' "$HOME/.claude.json" 2>/dev/null)
    [ -n "$t" ] || t=$(jq -r '.theme // "dark"' "$HOME/.claude/settings.json" 2>/dev/null)
    printf '%s\n' "$t"
}

# Model identifier → display name, by RULE, never by a table of known models. A lookup table does not fail
# loudly when a new model ships: it falls through to some default and prints another model's name or
# nothing, and this segment is precisely what the reader uses to tell an expensive model from a cheap one.
# The rule: strip a leading "claude-", strip a trailing extended-window suffix "[<digits>m]", capitalise the
# family, then join the hyphen-separated numeric segments with "." after a single space.
#   claude-sonnet-5 → Sonnet 5    claude-opus-5[1m] → Opus 5    claude-haiku-4-5 → Haiku 4.5
# Anything that does not match that shape is printed verbatim after the prefix/suffix strip — a strange but
# TRUE string, never a plausible-looking guess.
sa_model_name() {   # $1=raw model identifier → _mname
    local s=$1 sfx num fam rest seg nums first idx
    local lo=abcdefghijklmnopqrstuvwxyz up=ABCDEFGHIJKLMNOPQRSTUVWXYZ
    case "$s" in claude-*) s=${s#claude-} ;; esac
    case "$s" in
        *\[*\])
            sfx=${s##*\[}; sfx=${sfx%\]}          # "1m]" → "1m"
            num=${sfx%m}                          # "1m" → "1"; unchanged when there is no trailing m
            if [ "$num" != "$sfx" ] && [ -n "$num" ]; then
                case "$num" in *[!0-9]*) ;; *) s=${s%\[*} ;; esac
            fi
            ;;
    esac
    _mname=$s                                     # the verbatim answer, kept unless every check below passes
    case "$s" in *-*) ;; *) return ;; esac        # no version segment at all
    fam=${s%%-*}; rest=${s#*-}
    case "$fam" in ''|*[!a-z]*) return ;; esac    # family is not a plain lowercase word
    nums=""
    while [ -n "$rest" ]; do
        case "$rest" in
            *-*) seg=${rest%%-*}; rest=${rest#*-} ;;
            *)   seg=$rest; rest="" ;;
        esac
        case "$seg" in ''|*[!0-9]*) return ;; esac   # a non-numeric version segment: not our shape
        if [ -z "$nums" ]; then nums=$seg; else nums="$nums.$seg"; fi
    done
    # Uppercase the family initial without a fork: bash 3.2 has no ${var^}. The prefix of the lowercase
    # alphabet that stops at the initial is as long as that letter's index, so the same slice of the
    # uppercase alphabet is its capital. The all-lowercase check above guarantees the letter is found.
    first=${fam:0:1}; idx=${lo%%"$first"*}
    _mname="${up:${#idx}:1}${fam:1} $nums"
}

# Context-window marker. Present only when the size is usable: no placeholder, no assumed default, because
# a guessed window is exactly the kind of confident wrong answer this line must never give. A full window
# is normal and wears the model's own colour; anything smaller is the condition the reader needs to spot,
# so it wears the warning role.
sa_window() {   # $1=raw contextWindowSize → _win (coloured, empty when unusable)
    local n=$1
    _win=""
    case "$n" in ''|*[!0-9]*) return ;; esac
    [ "${#n}" -le 15 ] || return                  # keep the arithmetic well inside 64-bit signed
    n=$(( 10#$n ))                                # base 10 always: bash reads a leading zero as octal
    if [ "$n" -ge 1000000 ]; then _win="${MD}(1M)${RS}"; return; fi
    fmt_tok "$n"                                  # borrowed from render.sh: <1000 raw, else "Nk"
    [ -n "$_tok" ] || return
    case "$_tok" in *k) _tok="${_tok%k}K" ;; esac
    _win="${YL}(${_tok})${RS}"
}

# Strip leading and trailing spaces/tabs, no fork. Used ONLY to compare the description against the
# activity label, never to alter what is printed. bash 3.2 has no ${var//pattern} anchoring that would do
# this in one step, and the fields are capped at 256 codepoints so the loop is bounded and cheap.
sa_trim() {   # $1=string → _trim
    _trim=$1
    while :; do case "$_trim" in ' '*|"$SA_TAB"*) _trim=${_trim#?} ;; *) break ;; esac; done
    while :; do case "$_trim" in *' '|*"$SA_TAB") _trim=${_trim%?} ;; *) break ;; esac; done
}

# Token usage for this subagent. Plain-text colour (WH), deliberately NOT the warning yellow: on this row
# YL already means "the context window was cut down", and the single status line uses YL for its own
# subagent-token total, so a second yellow here would make the actual warning unreadable.
# Omitted when the count is absent, non-numeric, or zero — the same rule the single line applies to its
# subagent-token segment. A subagent that has burned nothing has nothing to report, and a "0" on every
# freshly started row is noise; a missing count is never rendered as 0 or as a placeholder either.
sa_tokens() {   # $1=raw tokenCount → _tok_seg (coloured, empty when absent / non-numeric / zero)
    local n=$1
    _tok_seg=""
    case "$n" in ''|*[!0-9]*) return ;; esac
    [ "${#n}" -le 15 ] || return                  # keep the arithmetic well inside 64-bit signed
    n=$(( 10#$n ))                                # base 10 always: bash reads a leading zero as octal
    [ "$n" -gt 0 ] || return
    fmt_tok "$n"                                  # borrowed from render.sh: 262414 → "262k", 1234567 → "1.2M"
    [ -n "$_tok" ] || return
    _tok_seg="${WH}${_tok}${RS}"
}

sa_join() {   # $@=segments in order; an empty one is skipped along with the separator that would precede it
    local p
    sa_parts=()
    for p in "$@"; do [ -n "$p" ] && sa_parts[${#sa_parts[@]}]=$p; done
    join_parts "${sa_parts[@]}"
    _content=$_line
}

# Assemble one row and bound it to the reported column count. Sacrifice order: the activity label shrinks
# first, the description only if that was not enough. The model name and its window marker are never
# truncated at any width — identifying the model is the entire reason this row is being taken over.
sa_render() {   # $1=description $2=model segment $3=token segment $4=label $5=column cap → _content
    local desc="${WH}$1${RS}" mseg=$2 tseg=$3 lseg="" cap=$5
    local wd wm wt wl nsep room
    [ -z "$4" ] || lseg="${DM}$4${RS}"
    vis_width "$desc"; wd=$_w
    vis_width "$mseg"; wm=$_w
    wt=0; if [ -n "$tseg" ]; then vis_width "$tseg"; wt=$_w; fi
    wl=0; if [ -n "$lseg" ]; then vis_width "$lseg"; wl=$_w; fi
    case "$cap" in
        ''|*[!0-9]*) cap=0 ;;
        *) if [ "${#cap}" -le 9 ]; then cap=$(( 10#$cap )); else cap=0; fi ;;
    esac
    nsep=1                                        # separators = one fewer than the segments actually present
    [ -z "$tseg" ] || nsep=$(( nsep + 1 ))
    [ -z "$lseg" ] || nsep=$(( nsep + 1 ))
    # No usable column count → nothing to bound against, so render the row whole (the single line takes the
    # same unbounded path when the terminal width cannot be measured).
    if [ "$cap" -le 0 ]; then sa_join "$desc" "$mseg" "$tseg" "$lseg"; return; fi
    if [ $(( wd + wm + wt + wl + nsep * SA_SEPW )) -le "$cap" ]; then sa_join "$desc" "$mseg" "$tseg" "$lseg"; return; fi

    if [ -n "$lseg" ]; then
        room=$(( cap - wd - wm - wt - nsep * SA_SEPW ))
        if [ "$room" -ge 2 ]; then                # 2 cells is trunc_head's floor: one glyph plus the ellipsis
            trunc_head "$lseg" "$room"; sa_join "$desc" "$mseg" "$tseg" "$_trunc"; return
        fi
        lseg=""; nsep=$(( nsep - 1 ))             # not even room for an ellipsis → drop segment and separator
        if [ $(( wd + wm + wt + nsep * SA_SEPW )) -le "$cap" ]; then sa_join "$desc" "$mseg" "$tseg" ""; return; fi
    fi
    room=$(( cap - wm - wt - nsep * SA_SEPW ))
    if [ "$room" -ge 2 ]; then trunc_head "$desc" "$room"; sa_join "$_trunc" "$mseg" "$tseg" ""; return; fi
    sa_join "" "$mseg" "$tseg" ""                 # pathologically narrow: model and usage are the last to go
}


# ── main ────────────────────────────────────────────────────────────────────────────────────────────────
# The theme job starts first so its jq overlaps the parsing jq below. Its </dev/null is mandatory, not
# tidiness: a background job inherits the stdin JSON pipe, and a second reader would eat the payload out
# from under the one jq that is allowed to have it.
exec 3< <(sa_resolve_theme </dev/null)

# One jq in. Every field is extracted behind `select(type == "object")` plus has()/null tests rather than a
# `//` chain, because jq ABORTS the whole program (rc 5) on a type-mismatched index — that would drop every
# task's row, not just the offending one. Newlines become spaces, control characters are removed by
# explode/implode codepoint math, and each field is capped at 256 codepoints. Output is positional: one
# line for the column count, then six lines per task. Lines, not a delimiter: tab is IFS whitespace, so
# `read` would silently merge consecutive empty fields, and empty fields are the normal case here.
# shellcheck disable=SC2016  # $k / $ARGS below are jq variables, not shell ones — single quotes are required
SA_JQ='
def clean: tostring
  | gsub("\n"; " ") | gsub("\r"; " ")
  | explode | map(select(. >= 32 and (. < 127 or . > 159))) | implode
  | .[0:256];
def fld($k): if has($k) and (.[$k] != null) then (.[$k] | clean) else "" end;
(if type == "object" then (if (.columns | type) == "number" then (.columns | floor | tostring) else "" end) else "" end),
( (if type == "object" then .tasks else null end)
  | (if type == "array" then . else [] end)
  | .[]
  | select(type == "object")
  | fld("id"), fld("model"), fld("contextWindowSize"), fld("description"), fld("label"), fld("tokenCount") )
'
exec 4< <(jq -r "$SA_JQ" 2>/dev/null)
sa_cols=""
IFS= read -r sa_cols <&4

# STYLE is the single line's palette knob. Derived from there rather than defined a second time, so the two
# lines cannot drift apart — the same trick tests/run-tests.sh uses for EDGE_PAD / JGAP. Unreadable → empty
# → load_palette's catch-all yields the claude native palette.
STYLE=$(sed -n 's/^STYLE="\([^"]*\)".*/\1/p' "$SA_DIR/statusline-command.sh" 2>/dev/null)
_theme=""
IFS= read -r _theme <&3
exec 3<&-
load_palette
SA_TAB=$'\t'                   # named so sa_trim's case patterns stay readable
SEP="${SP} │ ${RS}"            # same separator the single line uses, so the two read as one system
vis_width "$SEP"; SA_SEPW=$_w  # derived, not hardcoded, so a separator change cannot desync the width math

sa_out=()
while IFS= read -r sa_id <&4; do
    IFS= read -r sa_model <&4 || break
    IFS= read -r sa_win   <&4 || break
    IFS= read -r sa_desc  <&4 || break
    IFS= read -r sa_label <&4 || break
    IFS= read -r sa_tokc  <&4 || break
    # No id → the row cannot be addressed. No model → the reason this row exists is missing, and a row
    # without it is worse than Claude Code's default row. Either way: emit nothing, keep the default.
    [ -n "$sa_id" ] && [ -n "$sa_model" ] || continue
    # Description missing → promote the activity label into the first segment, and do NOT also repeat it as
    # the third, or the same sentence appears twice on one row.
    if [ -z "$sa_desc" ]; then sa_desc=$sa_label; sa_label=""; fi
    [ -n "$sa_desc" ] || continue     # nothing names this task → unattributable row → keep the default
    # While a subagent is starting and has no concrete action yet, Claude Code fills `label` with the
    # description, so the same sentence would be printed twice (45 of 316 rows in the captured sample —
    # 14%). Equal after trimming → drop the THIRD segment, keeping the description that names the task.
    # Trimming is the ONLY normalisation: no case folding, no width folding, no squeezing of inner
    # whitespace. Those would merge strings that genuinely differ, and if the label really is a different
    # activity, showing it matters more than saving a segment. The printed description keeps its own
    # spacing verbatim — the trim decides the comparison, never the output.
    if [ -n "$sa_label" ]; then
        sa_trim "$sa_desc"; sa_dtrim=$_trim
        sa_trim "$sa_label"
        [ "$sa_dtrim" != "$_trim" ] || sa_label=""
    fi
    sa_model_name "$sa_model"
    sa_window "$sa_win"
    sa_tokens "$sa_tokc"
    sa_render "$sa_desc" "${MD}${_mname}${RS}${_win}" "$_tok_seg" "$sa_label" "$sa_cols"
    sa_out[${#sa_out[@]}]=$sa_id
    sa_out[${#sa_out[@]}]=$_content
done
exec 4<&-

# One jq out. The records are built by jq from positional arguments, never by hand-concatenating JSON: the
# content holds ANSI escapes and arbitrary printable text, and escaping that is jq's job, not a printf's.
if [ ${#sa_out[@]} -gt 0 ]; then
    # shellcheck disable=SC2016  # $ARGS / $i are jq variables
    jq -cn 'range(0; ($ARGS.positional | length); 2) as $i
            | {id: $ARGS.positional[$i], content: $ARGS.positional[$i + 1]}' --args "${sa_out[@]}" </dev/null
fi
exit 0
