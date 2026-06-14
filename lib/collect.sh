# shellcheck shell=bash
# shellcheck disable=SC2034  # globals written here are consumed by the sibling render.sh (see WRITES header); lint via: shellcheck -x statusline-command.sh
# collect.sh — input collection: stdin JSON parsing + theme / width / git / effort collected concurrently in the background
#
# READS : stdin (statusline JSON), $HOME/.claude.json, $HOME/.claude/settings.json, transcript
# WRITES: cwd project_dir model session_name used_pct worktree_name effort thinking
#         five_h seven_d five_reset seven_reset session_id transcript_path now
#         git_branch git_dirty git_ins git_del effort_mode _theme term_cols
#
# Sync model: background jobs run via process substitution opening an FD; a read blocks until that job hits EOF, which is the
# sync point — no wait / temp file needed. Jobs are independent and run in parallel, so wall-clock = the slowest one, not the sum.
# Hard rule: every background job gets </dev/null (a job inherits the stdin JSON pipe; only parse_input's jq is allowed to read it).


# t=0: start the theme background job first; it doesn't depend on stdin and fully overlaps parse_input's jq parsing
start_theme_job() {
    exec 3< <(resolve_theme </dev/null)
}

# Theme follows /theme: written to ~/.claude.json (settings.json as fallback); always emits one line.
# ~/.claude.json may be mid-rewrite by Claude Code (torn read) → on jq parse failure fall through the fallback chain, affecting only one frame.
resolve_theme() {
    local t
    t=$(jq -r '.theme // empty' "$HOME/.claude.json" 2>/dev/null)
    [ -n "$t" ] || t=$(jq -r '.theme // "dark"' "$HOME/.claude/settings.json" 2>/dev/null)
    printf '%s\n' "$t"
}

read_theme() {
    _theme=""
    IFS= read -r _theme <&3 || :
    exec 3<&-
}


# t=0: at the same time start the terminal-width background job (for the right-align gap); doesn't depend on stdin, fully overlaps theme/jq
start_width_job() {
    $RIGHT_ALIGN || return 0
    exec 8< <(resolve_width </dev/null)
}

# Width source: prefer stty's live value (a terminal resize is reflected on the next frame), trust COLUMNS only on failure
# (it may be a startup snapshot, and COLUMNS=0 environments have been observed). Always emits one line; empty if unavailable, render falls back on its own.
# Note: 2>/dev/null MUST come before </dev/tty: redirects apply left-to-right, so this is the order that swallows the
# error from /dev/tty failing to open (no controlling terminal) — already hit: reversed, the error message leaks onto the display.
resolve_width() {
    local size
    size=$(stty size 2>/dev/null </dev/tty)
    size=${size##* }   # "rows cols" — take the last field
    case "$size" in ''|*[!0-9]*|0) size="" ;; esac
    if [ -z "$size" ]; then
        case "$COLUMNS" in ''|*[!0-9]*|0) ;; *) size=$COLUMNS ;; esac
    fi
    printf '%s\n' "$size"
}

read_width() {
    term_cols=""
    $RIGHT_ALIGN || return 0
    IFS= read -r term_cols <&8 || :
    exec 8<&-
}


# Single jq pass parsing every field; the order must match the reads below one-for-one.
# Newlines/carriage-returns inside values are first escaped to literal \n \r so each value stays on one line and fields don't misalign;
# all other control characters are stripped: C0 (incl. ESC, tab), DEL, AND the C1 block U+0080-U+009F (8-bit CSI/OSC/DCS — U+009B = "ESC [" on a UTF-8 terminal honoring C1, same injection class as a raw ESC; select keeps only `. >= 32 and (. < 127 or . > 159)`) — JSON's \u001b escape is legal input, and a raw ESC leaking out
# gets parsed by the terminal as CSI (injection risk), plus vis_width's width accounting wouldn't match the terminal and would push the single line into a wrap
# (reproduced in review: a session name containing ESC[1Zm renders as 121 cols at COLUMNS=120 → wraps).
# This is the only entry point for external strings, so after stripping, downstream can assume the string holds only our own SGR codes.
# Stripping uses explode/implode for codepoint filtering, not regex — jq's Oniguruma doesn't honor regex-layer backslash-u escapes,
# and a control-character range is treated as a literal character class (where the 0-u range strips almost all ASCII — already hit).
# jq inside the process substitution inherits the script's stdin (the statusline JSON).
# The last field (now|floor) also grabs the current Unix seconds for ttl, saving a date +%s fork.
# Each value is also capped to 256 codepoints (| .[0:256]): vis_width's ASCII-strip in render.sh is O(n^2) under bash 3.2, so an
# unbounded multi-KB field (e.g. a crafted session_name) would stall every frame (10KB → ~5s); 256 is far above any terminal's visible width, so render's "…" truncation still governs what shows.
parse_input() {
    {
        IFS= read -r cwd
        IFS= read -r project_dir
        IFS= read -r model
        IFS= read -r session_name
        IFS= read -r used_pct
        IFS= read -r worktree_name
        IFS= read -r effort
        IFS= read -r thinking
        IFS= read -r five_h
        IFS= read -r seven_d
        IFS= read -r five_reset
        IFS= read -r seven_reset
        IFS= read -r session_id
        IFS= read -r transcript_path
        IFS= read -r now
    } < <(jq -r '
        [ .workspace.current_dir // .cwd // "",
          .workspace.project_dir // "",
          .model.display_name // "",
          .session_name // "",
          .context_window.used_percentage // "",
          .worktree.name // "",
          .effort.level // "",
          (if .thinking.enabled == null then "" else .thinking.enabled end),
          .rate_limits.five_hour.used_percentage // "",
          .rate_limits.seven_day.used_percentage // "",
          .rate_limits.five_hour.resets_at // "",
          .rate_limits.seven_day.resets_at // "",
          .session_id // "",
          .transcript_path // "",
          (now | floor)
        ] | map(tostring | gsub("\n"; "\\n") | gsub("\r"; "\\r")
            | explode | map(select(. >= 32 and (. < 127 or . > 159))) | implode | .[0:256])[]
    ' 2>/dev/null)
}


# effort mode detection: the JSON only gives the resolved level (ultracode→xhigh, auto→resolved value),
# the mode itself is only recorded in the transcript's /effort stdout (<local-command-stdout> tag); grab the last one.
# The old 5-process pipe (tail|grep|grep|tail|sed) is shrunk to 3 (tail|grep|sed), taking the last match via bash string expansion.
# Word extraction must stay with sed: the anchor needs the full "effort level (set to|to)" token —
# a pure-bash trim anchored on "fort level" would wrongly catch suffixes like comfort/discomfort level (already hit).
effort_scan() {   # $1=transcript_path → one line of mode text on stdout (empty line if none)
    local m
    m=$(tail -n 2000 "$1" 2>/dev/null \
        | grep -oE '<local-command-stdout>[^<]*[Ee]ffort level (set to|to) [a-zA-Z]+[^<]*</local-command-stdout>' \
        | sed -E 's/.*[Ee]ffort level (set to|to) ([a-zA-Z]+).*/\2/')
    printf '%s\n' "${m##*$'\n'}"   # take the last match if there are several
}

# Concurrent collection of git×3 + effort: each opens its own FD in the procsub subshell, reaped in order; always emits a fixed 4 lines
collect_all() {   # $1=cwd $2=transcript_path $3=effort_level → branch / shortstat / untracked / effort_mode
    local b="" s="" u="" m=""
    if [ -n "$1" ]; then
        # branch: spends only 1 git process on a branch; falls back to a short sha only on detached HEAD
        # (4/5/6 no longer need </dev/null: collect_all itself is launched with </dev/null, and the child jobs inherit it)
        exec 4< <(git --no-optional-locks -C "$1" symbolic-ref --short -q HEAD 2>/dev/null \
                  || git --no-optional-locks -C "$1" rev-parse --short HEAD 2>/dev/null) \
             5< <(git --no-optional-locks -C "$1" diff --shortstat HEAD 2>/dev/null) \
             6< <(git --no-optional-locks -C "$1" ls-files --others --exclude-standard 2>/dev/null | head -1)
    fi
    if [ -n "$3" ] && [ -f "$2" ]; then
        exec 7< <(effort_scan "$2" </dev/null)
    fi
    if [ -n "$1" ]; then
        IFS= read -r b <&4 || :
        IFS= read -r s <&5 || :
        IFS= read -r u <&6 || :
    fi
    if [ -n "$3" ] && [ -f "$2" ]; then
        IFS= read -r m <&7 || :
    fi
    printf '%s\n%s\n%s\n%s\n' "$b" "$s" "$u" "$m"
}

collect_status() {
    local git_stat git_untracked   # intermediate values don't leave the function; git_branch/effort_mode are globals for render
    git_branch=""; git_stat=""; git_untracked=""; effort_mode=""
    {
        IFS= read -r git_branch
        IFS= read -r git_stat
        IFS= read -r git_untracked
        IFS= read -r effort_mode
    } < <(collect_all "$cwd" "$transcript_path" "$effort" </dev/null)

    # dirty flag + changed-line counts merged (precedence and behavior bit-for-bit identical to the old version):
    # non-empty shortstat = tracked files have changes (staged+unstaged) → dirty, also extract +N/-N;
    # otherwise an untracked new file also counts as dirty. +N/-N excludes untracked new-file lines (diff HEAD can't see them).
    # In a non-git directory all three jobs are empty; an empty git_branch silences the whole segment.
    git_dirty=""; git_ins=""; git_del=""
    if [ -n "$git_branch" ]; then
        if [ -n "$git_stat" ]; then
            git_dirty="*"
            if [[ $git_stat =~ ([0-9]+)\ insertion ]]; then git_ins="${BASH_REMATCH[1]}"; fi
            if [[ $git_stat =~ ([0-9]+)\ deletion ]]; then git_del="${BASH_REMATCH[1]}"; fi
        elif [ -n "$git_untracked" ]; then
            git_dirty="*"   # no tracked changes, but there is an untracked new file
        fi
    fi
}


# Cross-session rate-limit sync. Claude Code freezes rate_limits at a session's start snapshot (upstream limitation): a long-lived
# session keeps reporting its stale used% while only the countdown moves; a fresh session reports the true current value. This shares
# the freshest value across sessions through a tiny cache, so a frozen session adopts the newest used% any session has reported.
#
# Cache: $HOME/.claude/sl-ratelimit-cache, one "<resets_at> <used>" line per reset-window, keyed by resets_at.
# Freshness rule: within one window used% only climbs until resets_at (Claude's 5h/7d windows are FIXED, not rolling), so for a given
#   resets_at the MAX used% ever seen is the most recent. When the window rolls, resets_at becomes a new key and usage restarts there.
# One awk pass: seed this frame's (resets_at,used) for both windows, fold in every cached line taking the per-key max, drop expired keys
#   (resets_at <= now) into a fresh temp file, and emit the reconciled used% for our two windows as "<five>|<seven>".
# Mutates five_h / seven_d in place to the reconciled max; add_rate then renders them exactly as before. Degrades safely: any awk/mv
#   failure leaves out empty → the guards below keep this session's original values. Per-pid temp + atomic mv tolerates concurrent
#   sessions (last writer wins; the max re-converges on the next render).
reconcile_rates() {
    $RL_SYNC || return 0
    local cache="$HOME/.claude/sl-ratelimit-cache" src tmpfile out new5 new7
    src="$cache"; [ -f "$src" ] || src=/dev/null   # first run: no cache yet → read nothing, just seed from this frame
    tmpfile="$cache.$$"                            # $$ is unique per session process → no temp collision across sessions
    : > "$tmpfile" 2>/dev/null || return 0         # can't write (e.g. read-only HOME) → leave values untouched
    out=$(awk -v now="$now" -v r5="$five_reset" -v u5="$five_h" -v r7="$seven_reset" -v u7="$seven_d" -v tmp="$tmpfile" '
        function isnum(x){ return (x ~ /^[0-9]+(\.[0-9]+)?$/) }
        BEGIN{
            if (isnum(r5) && isnum(u5)) m[r5]=u5+0
            if (isnum(r7) && isnum(u7)) m[r7]=u7+0
        }
        isnum($1) && isnum($2){ if (!($1 in m) || $2+0 > m[$1]+0) m[$1]=$2+0 }
        END{
            for (k in m) if (k+0 > now+0 && m[k] != "") printf "%s %s\n", k, m[k] >> tmp
            printf "%s|%s\n", (isnum(r5) ? m[r5]"" : ""), (isnum(r7) ? m[r7]"" : "")
        }
    ' "$src" 2>/dev/null)
    mv -f "$tmpfile" "$cache" 2>/dev/null
    new5=${out%%|*}; new7=${out#*|}                # awk emits exactly one "|"; robust to command-sub trailing-newline stripping
    case "$new5" in ''|*[!0-9.]*) ;; *) five_h="$new5" ;; esac
    case "$new7" in ''|*[!0-9.]*) ;; *) seven_d="$new7" ;; esac
}
