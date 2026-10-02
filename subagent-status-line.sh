#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # cross-module globals, same contract lib/collect.sh and lib/render.sh use:
#   _w / _line / _trunc / _tok / _dur / _mname / _content / _rw are set by one function and read by another, and
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
# ANSI colour codes and is rendered verbatim. A record is never emitted with empty content to hide a row:
# which rows show, their order and the "↓ N more" fold belong to Claude Code.
#
# Row layout — seven cells joined by the same " │ " separator the single line uses, one after the marker too:
#
#     <marker> │ <elapsed> │ <ctx%> │ <tokens> │ <model> │ <description> │ <label>
#     RUN  │   12m │ 13% │ 128K │ Opus 5 │ Fold 682173 into 681727 │ Confirming mirror refs unchanged after cleanup
#
# marker: the class name padded to 4 columns (RUN/DONE green, IDLE/PEND grey, PAUS orange, FAIL/KILL red).
# elapsed: now - startTime, right-aligned to 5, "45s" under a minute and fmt_dur's "12m"/"1H15m"/"1D3H" from
# there; it keeps counting on finished rows because the payload has no end time. ctx%: round half up of
# 100 * tokenCount / contextWindowSize, right-aligned to 3, red above 92 on a window of 1,000,000 or more and
# above 80 below that. tokens: fmt_tok with an uppercase K, right-aligned to 4, "0" for zero. model: the
# display name derived by rule (no window marker), padded to the widest name among this invocation's rows.
# A value the payload does not supply in usable form prints "-"; a PEND row prints 0% and 0 instead and
# draws elapsed, ctx% and tokens grey, never red. The label is dropped when it only repeats the description
# (Claude Code fills it that way while an agent is starting), and promoted when the description is empty.
# A row wider than `columns` gives up, in this order, only as much as it must: label truncated, label
# dropped, tokens, model, elapsed, description truncated; marker and ctx% are never dropped.
#
# Classification (one pass, the same answer for the marker and for anything counted later):
#   running + the last SA_IDLE_SAMPLES (16) tokenSamples all numbers and none of their 15 adjacent pairs
#   increasing → IDLE; running otherwise (fewer samples, a non-number, any increase) → RUN; pending → PEND;
#   paused → PAUS; failed → FAIL; killed → KILL; completed → DONE; anything else, absent included →
#   unclassified: no record, so Claude Code keeps its default row. The status string is never rendered.
#
# State handed to the session line: every run whose session_id is a Claude Code UUID writes the per-class counts of
# every classified task, including those that get no record, as "V1 <epoch_s> <FAIL> <KILL> <PAUS> <RUN> <IDLE> <PEND>
# <DONE>" to ~/.claude/sl-subagents/<session_id> (sa_state_write). It is the only file this command writes; a failed or
# refused write leaves stdout unchanged. Because it writes under $HOME, run it by hand only through
# scripts/sandbox-run.sh, never against the real $HOME.
#
# Claude Code facts this rests on, read from the 2.1.287 binary (check these first after an upgrade):
#   F1 this command runs on a tick chain while at least one task exists: ~0.3 s after the panel mounts, then
#      every 5 s, single-flight, 5000 ms timeout; never with zero tasks.
#   F2 the payload holds every non-dismissed task, completed ones for 30 s more; each carries id, type,
#      status, description, label, startTime (epoch ms), model, contextWindowSize, tokenCount, tokenSamples,
#      cwd, and no end time; the top level carries session_id, transcript_path, cwd, columns.
#   F3 tokenSamples gets one entry per tick and is spliced to the last 16, so 16 flat samples span ~75-80 s.
#   F4 for local_agent tasks only running and completed are written by constructors, failed and killed by
#      later transitions; no write site of pending or paused was found, so PEND and PAUS may never appear.
#   F5 rows with content "" are filtered before Claude Code picks its 5-row window; the rest fold into
#      "↓ N more", in Claude Code's own order (parent tree, then startTime). This command cannot reorder.
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

# Strip leading and trailing spaces/tabs, no fork. Used ONLY to compare the description against the
# activity label, never to alter what is printed. bash 3.2 has no ${var//pattern} anchoring that would do
# this in one step, and the fields are capped at 256 codepoints so the loop is bounded and cheap.
sa_trim() {   # $1=string → _trim
    _trim=$1
    while :; do case "$_trim" in ' '*|"$SA_TAB"*) _trim=${_trim#?} ;; *) break ;; esac; done
    while :; do case "$_trim" in *' '|*"$SA_TAB") _trim=${_trim%?} ;; *) break ;; esac; done
}

# A count or epoch from the payload, usable only as decimal digits within 15 of them (well inside 64-bit signed
# arithmetic). jq's tostring erases the JSON type, so a string-typed "0262414" reaches the shell verbatim and bash
# would read the leading zero as OCTAL: every caller therefore expands the value with the 10# prefix.
sa_num_ok() {   # $1=raw value → rc 0 when usable
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#1}" -le 15 ]
}

sa_lpad() {   # $1=ASCII text $2=width → _pad, right-aligned with leading spaces (never cut)
    _pad=$1
    while [ "${#_pad}" -lt "$2" ]; do _pad=" $_pad"; done
}

# The three numeric cells of one row. A value the payload does not supply in usable form prints "-"; a PEND row
# prints the settled 0% and 0 instead and draws all three in the secondary grey, never red.
sa_cells() {   # $1=class $2=raw startTime $3=raw contextWindowSize $4=raw tokenCount → _el _cx _tk (coloured, padded)
    local cls=$1 s n w pct role
    if [ -n "$sa_now_ms" ] && sa_num_ok "$2"; then
        s=$(( (10#$sa_now_ms - 10#$2) / 1000 ))
        [ "$s" -ge 0 ] || s=0                     # a start in the future (clock skew) is "just started"
        fmt_elapsed "$s"; sa_lpad "$_dur" 5
    else
        sa_lpad "-" 5
    fi
    _el="${DM}${_pad}${RS}"
    role=$WH; [ "$cls" != PEND ] || role=$DM
    if sa_num_ok "$4" && sa_num_ok "$3" && [ $(( 10#$3 )) -gt 0 ]; then
        n=$(( 10#$4 )); w=$(( 10#$3 ))
        pct=$(( (200 * n + w) / (2 * w) ))        # round half up of 100*n/w in integer math
        if [ "$cls" != PEND ]; then
            # Same -gt comparison as the session line's context meter: 92 on a 1M window, 80 below it.
            if [ "$w" -ge 1000000 ]; then [ "$pct" -le 92 ] || role=$RD; else [ "$pct" -le 80 ] || role=$RD; fi
        fi
        sa_lpad "${pct}%" 3
    elif [ "$cls" = PEND ]; then
        sa_lpad "0%" 3
    else
        sa_lpad "-" 3
    fi
    _cx="${role}${_pad}${RS}"
    role=$WH; [ "$cls" != PEND ] || role=$DM
    if sa_num_ok "$4"; then
        fmt_tok "$(( 10#$4 ))"                    # borrowed from render.sh: 262414 → "262k", 1234567 → "1.2M"
        case "$_tok" in *k) _tok="${_tok%k}K" ;; esac
        sa_lpad "$_tok" 4
    elif [ "$cls" = PEND ]; then
        sa_lpad "0" 4
    else
        sa_lpad "-" 4
    fi
    _tk="${role}${_pad}${RS}"
}

sa_join() {   # $@=cells in order; an empty one is skipped along with the separator that would precede it
    local p
    sa_parts=()
    for p in "$@"; do [ -n "$p" ] && sa_parts[${#sa_parts[@]}]=$p; done
    join_parts "${sa_parts[@]}"
    _content=$_line
}

sa_rowwidth() {   # $@=cells in order, empty ones absent → _rw = visible width of the joined row
    local p n=0 t=0
    for p in "$@"; do [ -n "$p" ] || continue; vis_width "$p"; t=$(( t + _w )); n=$(( n + 1 )); done
    _rw=$t; [ "$n" -le 1 ] || _rw=$(( t + (n - 1) * SA_SEPW ))
}

# Assemble one row and bound it to the reported column count. Each step below runs only when the row still does
# not fit, and keeps what the earlier steps did: truncate the label, drop the label (when it cannot keep one
# character plus the ellipsis), drop tokens, drop model, drop elapsed, truncate the description. Marker and ctx%
# are never dropped; when not even one description character plus the ellipsis fits beside them, the row is the
# two of them alone, emitted even past the column count (Claude Code truncates it). Widths include the padding.
sa_render() {   # $1=marker $2=elapsed $3=ctx% $4=tokens $5=model $6=description $7=label (coloured, "" = absent) $8=cap → _content
    local mk=$1 el=$2 cx=$3 tk=$4 mo=$5 de=$6 lb=$7 cap=$8 room
    case "$cap" in
        ''|*[!0-9]*) cap=0 ;;
        *) if [ "${#cap}" -le 9 ]; then cap=$(( 10#$cap )); else cap=0; fi ;;
    esac
    # No usable column count → nothing to bound against, so render the row whole (the single line takes the
    # same unbounded path when the terminal width cannot be measured).
    if [ "$cap" -le 0 ]; then sa_join "$mk" "$el" "$cx" "$tk" "$mo" "$de" "$lb"; return; fi
    sa_rowwidth "$mk" "$el" "$cx" "$tk" "$mo" "$de" "$lb"
    if [ "$_rw" -le "$cap" ]; then sa_join "$mk" "$el" "$cx" "$tk" "$mo" "$de" "$lb"; return; fi
    if [ -n "$lb" ]; then
        sa_rowwidth "$mk" "$el" "$cx" "$tk" "$mo" "$de"
        room=$(( cap - _rw - SA_SEPW ))
        if [ "$room" -ge 2 ]; then                # 2 cells is trunc_head's floor: one glyph plus the ellipsis
            trunc_head "$lb" "$room"; sa_join "$mk" "$el" "$cx" "$tk" "$mo" "$de" "$_trunc"; return
        fi
        if [ "$_rw" -le "$cap" ]; then sa_join "$mk" "$el" "$cx" "$tk" "$mo" "$de"; return; fi
    fi
    sa_rowwidth "$mk" "$el" "$cx" "$mo" "$de"
    if [ "$_rw" -le "$cap" ]; then sa_join "$mk" "$el" "$cx" "$mo" "$de"; return; fi
    sa_rowwidth "$mk" "$el" "$cx" "$de"
    if [ "$_rw" -le "$cap" ]; then sa_join "$mk" "$el" "$cx" "$de"; return; fi
    sa_rowwidth "$mk" "$cx" "$de"
    if [ "$_rw" -le "$cap" ]; then sa_join "$mk" "$cx" "$de"; return; fi
    sa_rowwidth "$mk" "$cx"
    room=$(( cap - _rw - SA_SEPW ))
    if [ "$room" -ge 2 ]; then trunc_head "$de" "$room"; sa_join "$mk" "$cx" "$_trunc"; return; fi
    sa_join "$mk" "$cx"                           # pathologically narrow: marker and ctx% are the last to go
}

# A session id may name a file only when it has the exact shape of a Claude Code session UUID (8-4-4-4-12 lowercase
# hex), the same gate lib/collect.sh's sid_persistable applies to the rate-limit cache (that module is not sourced
# here). The shape also excludes "/", "." and every other path character.
sa_sid_ok() {   # $1=session id → rc 0 when UUID-shaped
    local h4='[0-9a-f][0-9a-f][0-9a-f][0-9a-f]' g
    g="$h4$h4-$h4-$h4-$h4-$h4$h4$h4"
    # shellcheck disable=SC2254  # unquoted on purpose: the expanded pattern IS the glob (quoted it would match literally)
    case "$1" in $g) return 0 ;; esac
    return 1
}

# Hand this invocation's per-class counts to the session line (subagent-summary-line): one line
# "V1 <epoch_s> <FAIL> <KILL> <PAUS> <RUN> <IDLE> <PEND> <DONE>" in ~/.claude/sl-subagents/<session_id>, written on every
# run, also when nothing changed, because the epoch is the heartbeat the reader's staleness bound checks. The path is
# required to be exactly what we create there: a link or a non-directory where the directory belongs, a link or a
# directory where the entry belongs, and anything at all at the temp path are refused, and nothing found on a refused
# path is repaired or removed ("mv -f" onto a directory would bury the temp file inside it; "mkdir -p" succeeds through
# a link, hence the re-check). Written to ".<sid>.<pid>" by the shell and renamed, so a reader never sees half a line.
# umask 077 inside the subshell: 700 directory, 600 file, and the caller's umask is untouched. On a first write (no
# entry yet for this session) regular files of the directory older than 86400 s by mtime are swept; content never
# decides (a temp file another session is writing does not parse yet), and links and directories are never touched
# (BSD find -type f neither matches nor follows a link; -maxdepth 1 never enters a subdirectory). The bound is written
# in minutes, -mmin +1440, rather than in days: BSD find's day units are documented as rounded up to whole 24-hour
# periods, so a day-based bound depends on that rounding. Every failure is silent, and the
# subshell's output goes nowhere, so the panel's stdout is the same whether or not the write happened.
sa_state_write() {   # $1=session id $2=epoch seconds $3..$9=FAIL KILL PAUS RUN IDLE PEND DONE counts
    sa_sid_ok "$1" || return 0
    (
        umask 077
        d="$HOME/.claude/sl-subagents"
        if [ ! -d "$d" ]; then
            if [ -L "$d" ] || [ -e "$d" ]; then exit 0; fi
            mkdir -p "$d" 2>/dev/null || exit 0
        fi
        if [ ! -d "$d" ] || [ -L "$d" ]; then exit 0; fi
        e="$d/$1"; t="$d/.$1.$$"
        if [ -L "$e" ] || [ -d "$e" ]; then exit 0; fi
        if [ -e "$t" ] || [ -L "$t" ]; then exit 0; fi
        first=0; [ -e "$e" ] || first=1
        { printf 'V1 %s %s %s %s %s %s %s %s\n' "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" > "$t"; } 2>/dev/null || exit 0
        if [ -f "$t" ] && [ ! -L "$t" ] && [ ! -L "$e" ] && [ ! -d "$e" ] && mv -f "$t" "$e" 2>/dev/null; then
            [ "$first" = 0 ] || find "$d" -mindepth 1 -maxdepth 1 -type f -mmin +1440 -exec rm -f {} + 2>/dev/null
        elif [ -f "$t" ] && [ ! -L "$t" ]; then
            rm -f "$t" 2>/dev/null
        fi
    ) </dev/null >/dev/null 2>&1
}


# ── main ────────────────────────────────────────────────────────────────────────────────────────────────
# The theme job starts first so its jq overlaps the parsing jq below. Its </dev/null is mandatory, not
# tidiness: a background job inherits the stdin JSON pipe, and a second reader would eat the payload out
# from under the one jq that is allowed to have it.
exec 3< <(sa_resolve_theme </dev/null)

# IDLE needs this many trailing tokenSamples, i.e. SA_IDLE_SAMPLES - 1 adjacent pairs without an increase. Claude
# Code pushes one sample per 5 s tick and keeps the last 16 (F3), so 16 is the whole window it keeps: about 75-80 s
# without a new token. Fewer samples mean not enough evidence, and a young agent stays RUN.
SA_IDLE_SAMPLES=16

# One jq in. Every field is extracted behind `select(type == "object")` plus has()/null tests rather than a
# `//` chain, because jq ABORTS the whole program (rc 5) on a type-mismatched index — that would drop every
# task's row, not just the offending one. Newlines become spaces, control characters are removed by
# explode/implode codepoint math, and each field is capped at 256 codepoints. Output is positional: one
# line for the column count, one for jq's clock in epoch ms, one for the session id, then eight lines per task, the last one the
# task's class (empty when unclassified). Lines, not a delimiter: tab is IFS whitespace, so `read` would
# silently merge consecutive empty fields, and empty fields are the normal case here. The class is decided
# here, once, so the marker and anything counted from it can never disagree.
# shellcheck disable=SC2016  # $k / $n / $s / $t / $w are jq variables, not shell ones — single quotes are required
SA_JQ='
def clean: tostring
  | gsub("\n"; " ") | gsub("\r"; " ")
  | explode | map(select(. >= 32 and (. < 127 or . > 159))) | implode
  | .[0:256];
def fld($k): if has($k) and (.[$k] != null) then (.[$k] | clean) else "" end;
def idle: (if has("tokenSamples") then .tokenSamples else null end) as $t
  | ($t | type) == "array" and ($t | length) >= $n
    and ($t[-$n:] as $w | ($w | all(type == "number")) and ([range(1; $n)] | all($w[.] <= $w[. - 1])));
def class: (if has("status") then .status else null end) as $s
  | if   $s == "running"   then (if idle then "IDLE" else "RUN" end)
    elif $s == "pending"   then "PEND"
    elif $s == "paused"    then "PAUS"
    elif $s == "failed"    then "FAIL"
    elif $s == "killed"    then "KILL"
    elif $s == "completed" then "DONE"
    else "" end;
(if type == "object" then (if (.columns | type) == "number" then (.columns | floor | tostring) else "" end) else "" end),
(now * 1000 | floor | tostring),
(if type == "object" then fld("session_id") else "" end),
( (if type == "object" then .tasks else null end)
  | (if type == "array" then . else [] end)
  | .[]
  | select(type == "object")
  | fld("id"), fld("model"), fld("contextWindowSize"), fld("description"), fld("label"), fld("tokenCount"),
    fld("startTime"), class )
'
exec 4< <(jq -r --argjson n "$SA_IDLE_SAMPLES" "$SA_JQ" 2>/dev/null)
sa_cols=""; sa_now_ms=""
IFS= read -r sa_cols <&4
IFS= read -r sa_now_ms <&4
sa_sid=""; IFS= read -r sa_sid <&4
sa_num_ok "$sa_now_ms" || sa_now_ms=""

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

# First pass: classify, build every cell but the model's padding, and find the widest model name among the rows
# that will be emitted. Second pass: pad the model cell to that width and narrow each row on its own.
sa_ids=(); sa_mk=(); sa_el=(); sa_cx=(); sa_tk=(); sa_mn=(); sa_mw=(); sa_de=(); sa_lb=()
sa_mwmax=0
sa_nFAIL=0; sa_nKILL=0; sa_nPAUS=0; sa_nRUN=0; sa_nIDLE=0; sa_nPEND=0; sa_nDONE=0
while IFS= read -r sa_id <&4; do
    IFS= read -r sa_model <&4 || break
    IFS= read -r sa_win   <&4 || break
    IFS= read -r sa_desc  <&4 || break
    IFS= read -r sa_label <&4 || break
    IFS= read -r sa_tokc  <&4 || break
    IFS= read -r sa_start <&4 || break
    IFS= read -r sa_class <&4 || break
    # Unclassified status (absent, or not one of the seven values) → keep Claude Code's default row.
    [ -n "$sa_class" ] || continue
    # Counted here, before any rule that decides whether a record is emitted: a classified task counts even when
    # Claude Code keeps its default row for it (no model, no text) or folds it away.
    case "$sa_class" in
        FAIL) sa_nFAIL=$(( sa_nFAIL + 1 )) ;; KILL) sa_nKILL=$(( sa_nKILL + 1 )) ;; PAUS) sa_nPAUS=$(( sa_nPAUS + 1 )) ;;
        RUN)  sa_nRUN=$(( sa_nRUN + 1 ))   ;; IDLE) sa_nIDLE=$(( sa_nIDLE + 1 )) ;; PEND) sa_nPEND=$(( sa_nPEND + 1 )) ;;
        DONE) sa_nDONE=$(( sa_nDONE + 1 )) ;;
    esac
    # No id → the row cannot be addressed. No model → the reason this row exists is missing, and a row
    # without it is worse than Claude Code's default row. Either way: emit nothing, keep the default.
    [ -n "$sa_id" ] && [ -n "$sa_model" ] || continue
    # Description missing → promote the activity label into the description cell, and do NOT also repeat it
    # as the label, or the same sentence appears twice on one row.
    if [ -z "$sa_desc" ]; then sa_desc=$sa_label; sa_label=""; fi
    [ -n "$sa_desc" ] || continue     # nothing names this task → unattributable row → keep the default
    # While a subagent is starting and has no concrete action yet, Claude Code fills `label` with the
    # description, so the same sentence would be printed twice (45 of 316 rows in the captured sample —
    # 14%). Equal after trimming → drop the label cell, keeping the description that names the task.
    # Trimming is the ONLY normalisation: no case folding, no width folding, no squeezing of inner
    # whitespace. Those would merge strings that genuinely differ, and if the label really is a different
    # activity, showing it matters more than saving a cell. The printed description keeps its own
    # spacing verbatim — the trim decides the comparison, never the output.
    if [ -n "$sa_label" ]; then
        sa_trim "$sa_desc"; sa_dtrim=$_trim
        sa_trim "$sa_label"
        [ "$sa_dtrim" != "$_trim" ] || sa_label=""
    fi
    case "$sa_class" in
        RUN|DONE)  sa_mcol=$GR ;;
        IDLE|PEND) sa_mcol=$DM ;;
        PAUS)      sa_mcol=$OG ;;
        *)         sa_mcol=$RD ;;             # FAIL, KILL
    esac
    sa_mpad=$sa_class; while [ "${#sa_mpad}" -lt 4 ]; do sa_mpad="$sa_mpad "; done
    sa_cells "$sa_class" "$sa_start" "$sa_win" "$sa_tokc"
    sa_model_name "$sa_model"
    vis_width "$_mname"; [ "$_w" -le "$sa_mwmax" ] || sa_mwmax=$_w
    sa_i=${#sa_ids[@]}
    sa_ids[sa_i]=$sa_id; sa_mk[sa_i]="${sa_mcol}${sa_mpad}${RS}"
    sa_el[sa_i]=$_el; sa_cx[sa_i]=$_cx; sa_tk[sa_i]=$_tk
    sa_mn[sa_i]=$_mname; sa_mw[sa_i]=$_w
    sa_de[sa_i]="${WH}${sa_desc}${RS}"
    sa_lb[sa_i]=""; [ -z "$sa_label" ] || sa_lb[sa_i]="${DM}${sa_label}${RS}"
done
exec 4<&-

sa_out=()
sa_i=0
while [ "$sa_i" -lt "${#sa_ids[@]}" ]; do
    sa_mcell=${sa_mn[sa_i]}; sa_k=${sa_mw[sa_i]}
    while [ "$sa_k" -lt "$sa_mwmax" ]; do sa_mcell="$sa_mcell "; sa_k=$(( sa_k + 1 )); done
    sa_render "${sa_mk[sa_i]}" "${sa_el[sa_i]}" "${sa_cx[sa_i]}" "${sa_tk[sa_i]}" "${MD}${sa_mcell}${RS}" \
              "${sa_de[sa_i]}" "${sa_lb[sa_i]}" "$sa_cols"
    sa_out[${#sa_out[@]}]=${sa_ids[sa_i]}
    sa_out[${#sa_out[@]}]=$_content
    sa_i=$(( sa_i + 1 ))
done

# One jq out. The records are built by jq from positional arguments, never by hand-concatenating JSON: the
# content holds ANSI escapes and arbitrary printable text, and escaping that is jq's job, not a printf's.
if [ ${#sa_out[@]} -gt 0 ]; then
    # shellcheck disable=SC2016  # $ARGS / $i are jq variables
    jq -cn 'range(0; ($ARGS.positional | length); 2) as $i
            | {id: $ARGS.positional[$i], content: $ARGS.positional[$i + 1]}' --args "${sa_out[@]}" </dev/null
fi
if [ -n "$sa_now_ms" ]; then
    sa_state_write "$sa_sid" "$(( 10#$sa_now_ms / 1000 ))" \
        "$sa_nFAIL" "$sa_nKILL" "$sa_nPAUS" "$sa_nRUN" "$sa_nIDLE" "$sa_nPEND" "$sa_nDONE"
fi
exit 0
