# shellcheck shell=bash
# shellcheck disable=SC2154  # globals read here are assigned by the sibling collect.sh (see READS header); lint via: shellcheck -x statusline-command.sh
# render.sh — render output: palette + single-line assembly (left = path/resources/time, right = git/session, right-aligned)
#
# READS : config (CTX_BAR NORM_THINKING STYLE RIGHT_ALIGN EDGE_PAD JGAP BURN_SENS LASTMSG_WARN LASTMSG_STALE) + every global written by collect.sh
# WRITES: stdout (single colored status line). The palette (WH MD GR…TRK) must be global so it's reachable across functions;
#         the assembly working variables (parts parts2 _pct _ttl _dur _tok _rate_full _rate_compact _line bar display_dir git_seg…)
#         and the per-segment handles built by build_left/build_right for degrade_layout (seg_path seg_model_full/compact seg_effort
#         seg_thinking seg_ctx_full/compact seg_tok seg_5h_full/compact seg_7d seg_lastmsg seg_git_full/nodiff seg_worktree seg_session)
#         are deliberately not local (this module is the terminal stage, nobody reads them afterward); external code should not depend on them
#
# Pure-bash string concatenation throughout, zero forks; $'..' stores the ESC byte directly, no printf fork needed.


# Palette: the STYLE library (dark themes). Each set is a complete role mapping with values from that theme's official palette:
#   WH primary text / MD model name / CY project path / DM secondary gray (timestamp/session/effort normal) / SP structural gray (separators, /)
#   GR→YL→OG→RD semantic ladder (4 quota levels, 4 progress-bar zones; OG doubles as effort=medium, RD doubles as low/no-think/ctx>80% alert)
#   RD_DATA data red (-line count, a tier apart from alert red) / TRK progress-bar track
# A _theme name containing "light" uses the fixed light palette; only dark themes consult STYLE.
load_palette() {
    RS=$'\033[0m'; BOLD=$'\033[1m'
    if [[ "$_theme" == *light* ]]; then
        WH=$'\033[38;2;40;40;40m'      # primary text: near-black
        MD=$'\033[38;2;140;80;10m'     # model name: deep amber
        GR=$'\033[38;2;20;120;20m'
        YL=$'\033[38;2;160;100;0m'
        OG=$'\033[38;2;180;80;0m'
        RD=$'\033[38;2;160;20;10m'
        DM=$'\033[38;2;110;110;110m'
        CY=$'\033[38;2;30;80;180m'     # project path: deep blue (alt deep sky-blue 20;100;160)
        SP="$DM"; RD_DATA="$RD"
        TRK=$'\033[48;2;215;215;215m'
    else
        case "$STYLE" in
        tokyo-night)   # cool night blue-purple base, orange accents (official palette ff9e64/9ece6a/e0af68/f7768e/7aa2f7)
            WH=$'\033[38;2;192;202;245m'; MD=$'\033[38;2;255;158;100m'; CY=$'\033[38;2;122;162;247m'
            GR=$'\033[38;2;158;206;106m'; YL=$'\033[38;2;224;175;104m'; OG=$'\033[38;2;255;158;100m'
            RD=$'\033[38;2;247;118;142m'; RD_DATA=$'\033[38;2;219;75;75m'
            DM=$'\033[38;2;120;124;153m'; SP=$'\033[38;2;86;95;137m'
            TRK=$'\033[48;2;41;46;66m'
            ;;
        tokyo-night-claude)   # tokyo-night color palette + claude's native warm-gray text (WH/DM/SP swapped to warm beige-gray, color accents stay cool night blue-purple)
            WH=$'\033[38;2;222;214;202m'; MD=$'\033[38;2;255;158;100m'; CY=$'\033[38;2;122;162;247m'
            GR=$'\033[38;2;158;206;106m'; YL=$'\033[38;2;224;175;104m'; OG=$'\033[38;2;255;158;100m'
            RD=$'\033[38;2;247;118;142m'; RD_DATA=$'\033[38;2;219;75;75m'
            DM=$'\033[38;2;138;130;124m'; SP=$'\033[38;2;94;88;84m'
            TRK=$'\033[48;2;41;46;66m'
            ;;
        catppuccin)    # Mocha pastel design system (peach/green/yellow/red/maroon/lavender + overlay/surface grays)
            WH=$'\033[38;2;205;214;244m'; MD=$'\033[38;2;250;179;135m'; CY=$'\033[38;2;180;190;254m'
            GR=$'\033[38;2;166;227;161m'; YL=$'\033[38;2;249;226;175m'; OG=$'\033[38;2;250;179;135m'
            RD=$'\033[38;2;243;139;168m'; RD_DATA=$'\033[38;2;235;160;172m'
            DM=$'\033[38;2;127;132;156m'; SP=$'\033[38;2;88;91;112m'
            TRK=$'\033[48;2;49;50;68m'
            ;;
        rose-pine)     # rose-gold elegant system (gold/foam/rose/love/iris + subtle/muted grays)
            WH=$'\033[38;2;224;222;244m'; MD=$'\033[38;2;246;193;119m'; CY=$'\033[38;2;196;167;231m'
            GR=$'\033[38;2;156;207;216m'; YL=$'\033[38;2;246;193;119m'; OG=$'\033[38;2;235;188;186m'
            RD=$'\033[38;2;235;111;146m'; RD_DATA=$'\033[38;2;180;99;122m'
            DM=$'\033[38;2;144;140;170m'; SP=$'\033[38;2;110;106;134m'
            TRK=$'\033[48;2;38;35;58m'
            ;;
        *)             # claude native look (default): terracotta orange #D97757 + warm grays, like an extension of the Claude Code UI
            WH=$'\033[38;2;222;214;202m'; MD=$'\033[38;2;217;119;87m'; CY=$'\033[38;2;150;140;180m'
            GR=$'\033[38;2;125;155;115m'; YL=$'\033[38;2;212;164;94m'; OG=$'\033[38;2;222;138;78m'
            RD=$'\033[38;2;226;100;84m'; RD_DATA=$'\033[38;2;186;112;98m'
            DM=$'\033[38;2;138;130;124m'; SP=$'\033[38;2;94;88;84m'
            TRK=$'\033[48;2;44;42;40m'
            ;;
        esac
    fi
}


# percentage → integer; non-numeric (incl. empty) returns empty string, so printf doesn't error out and print 0
fmt_pct() {
    case "$1" in
        ''|*[!0-9.]*) _pct="" ;;
        *) printf -v _pct '%.0f' "$1" 2>/dev/null || _pct="" ;;
    esac
}

# token count → human: <1000 raw integer, <1e6 "Nk" (integer thousands), else "N.NM" (one decimal). Pure integer math
# (LC_ALL=C, bash 3.2 — no float printf): the M form derives one decimal from n/100000 (e.g. 1100000→11→"1.1M", 33400000→334→"33.4M").
fmt_tok() {   # $1=integer → _tok ; empty on non-numeric
    local n=$1 t
    case "$n" in ''|*[!0-9]*) _tok=""; return ;; esac
    if   [ "$n" -lt 1000 ];    then _tok="$n"
    elif [ "$n" -lt 1000000 ]; then _tok="$(( n / 1000 ))k"
    else t=$(( n / 100000 )); _tok="$(( t / 10 )).$(( t % 10 ))M"; fi
}

# Shared seconds→duration formatter: D/H/m cascade. Single source for ttl() (reset countdown) and the last-message Δ,
# which previously carried byte-identical arithmetic in two places (silent-drift risk if only one were ever edited).
fmt_dur() {   # $1=seconds (non-negative integer) → _dur="1D3H"/"2H2m"/"5m"
    local s=$1 d h m
    d=$((s/86400)); h=$(((s%86400)/3600)); m=$(((s%3600)/60))
    if [ "$d" -gt 0 ]; then _dur="${d}D${h}H"
    elif [ "$h" -gt 0 ]; then _dur="${h}H${m}m"
    else _dur="${m}m"; fi
}

# Seconds-precision duration formatter for the API-time primary (fmt_dur is minute-grained; API work is often sub-minute).
# <60s → "<s>s" (incl. "0s" for a sub-second ms that still passed the -gt 0 guard); <1h → "<m>m<s>s" ("3m45s", "1m0s", "59m59s");
# >=1h delegates to fmt_dur so the "1H15m"/"1D3H" forms are byte-identical to the session-duration primary. Writes _dur. fmt_dur untouched.
fmt_dur_s() {   # $1=seconds (non-negative integer) → _dur="45s"/"3m45s"/"1H15m"
    local s=$1
    if [ "$s" -lt 60 ]; then _dur="${s}s"
    elif [ "$s" -lt 3600 ]; then _dur="$(( s / 60 ))m$(( s % 60 ))s"
    else fmt_dur "$s"; fi
}

ttl() {   # $1=resets_at (Unix seconds) → _ttl="1D3H"/"2H2m"/"5m"; non-numeric returns empty
    _ttl=""
    case "$1" in ''|*[!0-9]*) return ;; esac
    local s=$(( $1 - now ))
    if [ "$s" -le 0 ]; then _ttl="0m"; return; fi
    fmt_dur "$s"; _ttl="$_dur"
}

# Build a rate-limit segment into _rate_full (countdown + remaining% + optional burn) and _rate_compact (remaining% + burn only, countdown
# dropped). Both empty when the used% is non-numeric. The caller pushes _rate_full to parts and keeps _rate_compact for degrade step 13
# (collapse the 5h quota to remaining-percent only while RETAINING any burn alarm — the alarm lives in $3 and is in both forms).
build_rate() {   # $1=used% $2=resets_at $3=burn indicator (optional) → _rate_full / _rate_compact ("2H2m 76% ↘33m" / "76% ↘33m")
    _rate_full=""; _rate_compact=""
    fmt_pct "$1"
    [ -n "$_pct" ] || return 0
    local r=$((100 - _pct)) color
    if [ "$r" -lt 0 ]; then r=0; fi   # used_percentage may exceed 100 → clamp so "remaining" is never a negative number
    if [ "$r" -gt 75 ]; then color="$GR"
    elif [ "$r" -gt 50 ]; then color="$YL"
    elif [ "$r" -gt 25 ]; then color="$OG"
    else color="$RD"; fi
    ttl "$2"
    _rate_compact="${color}${r}%${RS}${3:+ $3}"                          # burn alarm kept; countdown dropped
    _rate_full="${_ttl:+${WH}${_ttl}${RS} }${_rate_compact}"            # full = countdown prefix + compact
}

add_rate() {   # $1=used% $2=resets_at $3=burn indicator (optional, appended inside the segment) → appends "2H2m 76% ↘33m" to parts
    build_rate "$1" "$2" "$3"
    [ -n "$_rate_full" ] && parts+=("$_rate_full")
}

# Rate-limit burn-projection alarm (5h window). reconcile_rates' awk emits burn_tte = projected seconds-to-exhaust, ALREADY gated on
# slope>0 AND projected-exhaust-strictly-before-reset (both mandatory; they need now/resets_at, so they live in awk). Here we apply only
# the config sensitivity ceiling and the colour threshold, then render "↘<dur>". Only the depletion glyph ↘ is ever emitted — a falling
# used% (slope<0) yields an empty burn_tte upstream and never reaches here. Empty/non-numeric burn_tte (no slope, gate failed, sync off)
# → segment stays silent, matching the statusline's "show only when abnormal" rule. ↘ folds to 1 cell in vis_width, so the width math holds.
build_burn() {   # uses globals burn_tte + config BURN_SENS → _burn ("" when hidden)
    _burn=""
    case "${burn_tte:-}" in ''|*[!0-9]*) return 0 ;; esac
    local tte=$burn_tte ceil
    case "${BURN_SENS:-balanced}" in
        conservative) ceil=1800 ;;     # show only when ≤30m to exhaust
        sensitive)    ceil=$tte ;;     # no extra ceiling beyond the mandatory before-reset gate → always show
        *)            ceil=6300 ;;     # balanced default (~90m+; the end-to-end result matrix pins it within [101,120) min)
    esac
    [ "$tte" -le "$ceil" ] || return 0
    fmt_dur "$tte"
    if [ "$tte" -le 1800 ]; then _burn="${RD}↘${_dur}${RS}"   # ≤30m: imminent → red
    else _burn="${YL}↘${_dur}${RS}"; fi                       # >30m: comfortable approach → yellow
}


# Left: path + resource state (model / effort / thinking / ctx / quota) + last-message time
# Besides building parts[] (the full-form left half used by the roomy / junction render paths), each segment is also captured into a
# named global with, where a shorter rendering exists, a compact form (seg_*_compact). render_line's degrade_layout (the fixed 14-step
# sacrifice order) reassembles parts[] from these handles when the full line overflows: shrink before drop, core (path + ctx%) never cut.
build_left() {
    parts=()
    seg_path=""; seg_model_full=""; seg_model_compact=""; seg_effort=""; seg_thinking=""
    seg_ctx_full=""; seg_ctx_compact=""; seg_tok=""; seg_5h_full=""; seg_5h_compact=""; seg_7d=""; seg_lastmsg=""

    # Path display: cwd under project_dir → project name + relative path, otherwise basename
    display_dir=""
    if [ -n "$cwd" ]; then
        display_dir="${cwd##*/}"
        [ -n "$display_dir" ] || display_dir="$cwd"   # keep as-is when cwd is "/"
        if [ -n "$project_dir" ]; then
            case "$cwd" in
                "$project_dir"/*) display_dir="${project_dir##*/}${cwd#"$project_dir"}" ;;
            esac
        fi
    fi
    # Core path segment: the basename is the never-dropped anchor (degrade_layout head-truncates it only at the core-only tier).
    [ -n "$display_dir" ] && { seg_path="${CY}${BOLD}${display_dir}${RS}"; parts+=("$seg_path"); }

    # Model name carries a compact form ("Opus 4.8(1M)" → "Opus", the leading word) so degrade_layout shrinks before dropping (steps 9/10).
    if [ -n "$model" ]; then
        seg_model_full="${MD}${model/ (1M context)/(1M)}${RS}"
        seg_model_compact="${MD}${model%% *}${RS}"   # first whitespace-delimited word, e.g. "Opus"
        parts+=("$seg_model_full")
    fi

    # effort coloring (all 5 levels: low/medium/high/xhigh/max): warm = below the normal high;
    # xhigh/max are upward deviations that self-evidence via the text, same gray as high; unknown new values aren't colored arbitrarily.
    # ultracode must resolve to xhigh; a mismatched level is treated as a stale record (e.g. reset after resume) and not trusted; auto can't be disproven, so display it as-is.
    if [ -n "$effort" ]; then
        effort_disp="$effort"
        case "$effort_mode" in
            ultracode) [ "$effort" = "xhigh" ] && effort_disp="ultra" ;;
            auto)      effort_disp="auto·${effort}" ;;
        esac
        case "$effort" in
            low)    effort_color="$RD" ;;
            medium) effort_color="$OG" ;;
            *)      effort_color="$DM" ;;
        esac
        seg_effort="${effort_color}${effort_disp}${RS}"
        parts+=("$seg_effort")
    fi

    # thinking shown only when abnormal: normally-on → red warning when off; normally-off → calm gray text when on; missing JSON value stays silent, no false alarm
    if [ -n "$thinking" ]; then
        if $NORM_THINKING; then
            [ "$thinking" = "false" ] && seg_thinking="${RD}no-think${RS}"
        else
            [ "$thinking" = "true" ] && seg_thinking="${DM}thinking${RS}"
        fi
        [ -n "$seg_thinking" ] && parts+=("$seg_thinking")
    fi

    # ctx %: the % number is normally white, turns red as a warning only near the model's context limit. The red threshold is
    # BUDGET-AWARE, not a fixed 80%: a 1M-context model (display name carries the "1M context" marker, same signal build_left
    # already keys on for the model-name compaction above) has ~5x the budget, so 80% there is still huge headroom — applying the
    # 200k-class 80% rule would falsely flag it red. So pick the threshold from the model's context budget: 80% for 200k-class
    # models, 92% for 1M-context models (a value that keeps 85% — the spec's worked example — in normal colour while still warning
    # as the 1M window genuinely nears full). Defaults to the 200k threshold when no extended-context marker is present.
    # When CTX_BAR=true, a 12-cell gradient bar is prepended: used portion colored in four zones (green→yellow→orange→red), unused drawn as gray track
    fmt_pct "$used_pct"
    if [ -n "$_pct" ]; then
        case "$model" in *"1M context"*|*"(1M)"*) ctx_red_at=92 ;; *) ctx_red_at=80 ;; esac
        if [ "$_pct" -gt "$ctx_red_at" ]; then ctx_color="$RD"; else ctx_color="$WH"; fi
        # 200k cost/cache cliff marker: appended iff the upstream over-200k indicator (exceeds_200k_tokens) is true. It is DECOUPLED
        # from the percentage colour above — driven solely by the indicator, independent of used_percentage or which budget the colour
        # threshold selected (so a normal-coloured 1M frame can still show the cliff, and a red 200k frame may or may not). The marker
        # rides as a red alert "⚑" (the RD role applied below), emitted only on the established build_left path; its own colour is the
        # alert red so the crossed-cliff reads at a glance without coupling to the % colour. exceeds_200k is read through parse_input (sanitized, capped).
        ctx_cliff=""
        [ "$exceeds_200k" = "true" ] && ctx_cliff="${RD}⚑${RS}"
        # Compact ctx form (degrade step 4): plain "N%" text, no bar — the % itself is part of the core and is never dropped.
        seg_ctx_compact="${ctx_color}${_pct}%${RS}${ctx_cliff}"
        if $CTX_BAR; then
            # Solid bar: background color (48;2) + a space fills the whole cell, no font gaps; the unfilled part uses the gray background as a track
            BAR_W=12
            filled=$(( _pct * BAR_W / 100 ))
            z1=$(( BAR_W / 4 )); z2=$(( BAR_W / 2 )); z3=$(( BAR_W * 3 / 4 ))
            bar=""
            for ((n=0; n<BAR_W; n++)); do
                if [ "$n" -lt "$filled" ]; then
                    if   [ "$n" -lt "$z1" ]; then c="$GR"
                    elif [ "$n" -lt "$z2" ]; then c="$YL"
                    elif [ "$n" -lt "$z3" ]; then c="$OG"
                    else                          c="$RD"
                    fi
                    bar="${bar}${c/38;2/48;2} "   # convert the foreground color code to a background code (the leading 38;2 is always the prefix)
                else
                    bar="${bar}${TRK} "
                fi
            done
            seg_ctx_full="${bar}${RS} ${ctx_color}${_pct}%${RS}${ctx_cliff}"
        else
            seg_ctx_full="${ctx_color}ctx:${_pct}%${RS}${ctx_cliff}"   # CTX_BAR off: full == "ctx:N%"; compact drops the "ctx:" prefix to plain N%
        fi
        parts+=("$seg_ctx_full")
    fi

    # Token usage (cumulative in+out, cache excluded): session total shown once there is real usage; subagent total appended
    # with ⊂ only when > 0. Values come from read_tokens (the bg-job-updated cache) — the frame never blocks on summation;
    # absent cache or a zero-usage session (e.g. the first frame) → segment omitted, matching the "first frame shows nothing" spec.
    # Placed before the rate-limit windows so the line reads "…ctx · tokens · 5h · 7d · time".
    if [ -n "$session_tokens" ] && [ "$session_tokens" -gt 0 ] 2>/dev/null; then
        fmt_tok "$session_tokens"; tok_part="${WH}${_tok}${RS}"
        if [ -n "$subagent_tokens" ] && [ "$subagent_tokens" -gt 0 ] 2>/dev/null; then
            fmt_tok "$subagent_tokens"; tok_part="${tok_part}${DM} ⊂${RS}${YL}${_tok}${RS}"
        fi
        seg_tok="$tok_part"   # session + subagent are one indivisible unit: degrade step 8 drops both together
        parts+=("$seg_tok")
    fi

    # Rate limit: reset countdown + remaining %. The 5h segment also carries the burn-projection alarm (↘<ttl>) when the budget
    # is on track to run dry before the window resets; build_burn returns "" otherwise so the common case adds nothing.
    build_burn
    build_rate "$five_h" "$five_reset" "$_burn"
    seg_5h_full="$_rate_full"; seg_5h_compact="$_rate_compact"   # compact (step 13) keeps the burn alarm, drops only the reset countdown
    [ -n "$seg_5h_full" ] && parts+=("$seg_5h_full")
    build_rate "$seven_d" "$seven_reset"
    seg_7d="$_rate_full"
    [ -n "$seg_7d" ] && parts+=("$seg_7d")

    # Last-message time: the per-session file written by the UserPromptSubmit hook (not the current time).
    # session_id is interpolated into a path here, so reject any slash/.. shape first (defense-in-depth: the id is
    # CC-generated, but a crafted one would otherwise read an arbitrary file's first line — confirmed traversal).
    # The file content is the ONE external string that does NOT pass parse_input's filter, so strip control chars here too,
    # restoring the documented "only our own SGR codes reach the terminal" invariant: a raw non-SGR ESC in the file would
    # otherwise inject into the terminal AND desync vis_width (a non-m-terminated CSI) into a line wrap — the exact bug the
    # parse_input filter prevents. Glob-strip is zero-fork: C0 0x01-0x1F + DEL 0x7F, plus the 2-byte UTF-8 C1 block 0xC2 0x80..0x9F
    # (mirroring parse_input's select(. >= 32 and (. < 127 or . > 159))); a final :0:256 byte-cap matches the jq length bound.
    # Deliberately NOT a jq re-parse, which would add a fork to every frame's hot path for an inert-text cleanup.
    # (Glob range starts at 0x01, not 0x00: bash's $'\000' expands to the empty string — a leading "-" in the bracket class — so it
    # cannot encode NUL; range would silently strip every literal "-" (breaks "MM-DD" labels). Safe anyway: `read` drops NUL bytes,
    # so a C-string `last_msg` can never hold one, leaving the 0x01.. range equivalent to parse_input's select(. >= 32 ...) here.)
    last_msg=""; lm_epoch=""
    case "$session_id" in
        ''|*/*|*..*) ;;   # empty or path-traversal-shaped → skip the read entirely
        *)
            if [ -f "$HOME/.claude/last-msg/$session_id" ]; then
                IFS= read -r last_msg < "$HOME/.claude/last-msg/$session_id"
                _sanitize_field "$last_msg"; last_msg=$REPLY          # C0+DEL + 2-byte C1 (U+009B CSI etc.) strip + 256-cap (O(n^2) vis_width bound); shared with git_branch via _sanitize_field in collect.sh so the two filters can't drift
                # File is now "HH:MM <epoch>" (hook writes both). Split off the trailing all-digit epoch so we can age it into a Δ;
                # an old "MM-DD HH:MM" file (no numeric tail) leaves lm_epoch empty and is shown verbatim — backward compatible for
                # sessions whose file the updated hook hasn't rewritten yet.
                lm_epoch=${last_msg##* }
                case "$lm_epoch" in
                    ''|*[!0-9]*) lm_epoch="" ;;                       # no epoch tail → keep last_msg as the whole raw string
                    *) last_msg=${last_msg% *} ;;                     # time label = everything before the last space
                esac
            fi
            ;;
    esac
    # Time-segment PRIMARY text: a THREE-LEVEL fallback chain, all REPLACING the absolute last-prompt clock.
    #   1. cost.total_api_duration_ms (>0): cumulative API-wait/"thinking" ms — the time Claude spent producing responses this session,
    #      EXCLUDING idle and EXCLUDING local tool execution — formatted seconds-grained by fmt_dur_s ("3m45s"). Closest available proxy
    #      for "how long did Claude actually think", so it takes precedence over wall-clock.
    #   2. else cost.total_duration_ms (>0): session wall-clock since start (idle included), formatted by fmt_dur ("1H15m").
    #   3. else the legacy "HH:MM" / "MM-DD HH:MM" clock label (older CC without either cost field) — backward compatible, and the path
    #      the test suite's no-cost frames exercise.
    # Levels 1 and 2 both land in dur_str so the segment-emit guard, the (Δ) delta logic, and the clock-fallback branch below are shared.
    dur_str=""
    if [ -n "$api_ms" ] && [ "$api_ms" -gt 0 ] 2>/dev/null; then
        fmt_dur_s "$(( api_ms / 1000 ))"; dur_str="$_dur"
    elif [ -n "$dur_ms" ] && [ "$dur_ms" -gt 0 ] 2>/dev/null; then
        fmt_dur "$(( dur_ms / 1000 ))"; dur_str="$_dur"
    fi
    # Render "<primary> (Δ)": the primary text (API time, session duration, or the clock fallback) is dim; Δ ("how long since the last prompt") is
    # colored as a prompt-cache-freshness signal (thresholds = the two real cache TTLs, see LASTMSG_WARN/STALE in statusline-command.sh).
    # Δ under a minute is hidden. The text is honest elapsed time; only the Δ color encodes the cache read — the script can't see CC's
    # real cache state, so it won't claim one in words.
    # Cross-day correctness applies ONLY to the clock fallback (reached only when BOTH cost duration fields are unavailable): lm_epoch is a
    # UTC Unix time but the stored "HH:MM" label is LOCAL, so a prompt from a prior local calendar day would be misread as today; when
    # lm_epoch and now fall on DIFFERENT local days, prepend the local date ("MM-DD HH:MM"). Both duration primaries (API time, session
    # duration) are elapsed spans, not wall clocks, so they need no such fix. The comparison is a
    # calendar-DAY difference (not a fixed 24h age): a 23:50 prompt rendered at 00:10 next day is cross-day at Δ=20m. The local date is
    # resolved with `date -r <epoch>` (BSD/macOS, same family as the script's stat -f), so DST is handled with no manual offset math. The
    # date fork only runs inside the Δ>=60 + clock-fallback branch, keeping the common path fork-free. (Deliberate: design.md's "Δ>=1h
    # gate" is superseded by spec.md last-message-age's NORMATIVE "cross-midnight prompt under one hour" scenario — lm_epoch 23:50 / now
    # 00:10 MUST render "06-14 23:50" with a yellow (20m) Δ; spec.md is the authority over design.md/tasks.md 6.5's stale "Δ>=1h" wording.)
    if [ -n "$last_msg" ] || [ -n "$dur_str" ]; then
        local lm_delta="" lm_col="" lm_primary="$dur_str"
        if [ -n "$lm_epoch" ]; then
            lm_age=$(( now - lm_epoch ))
            if [ "$lm_age" -lt 0 ]; then lm_age=0; fi
            if [ "$lm_age" -ge 60 ]; then
                fmt_dur "$lm_age"; lm_delta="$_dur"
                if   [ "$lm_age" -ge "$LASTMSG_STALE" ]; then lm_col="$RD"   # ≥1h: even the extended cache is gone
                elif [ "$lm_age" -ge "$LASTMSG_WARN"  ]; then lm_col="$YL"   # ≥5m: default cache has gone idle-cold
                else lm_col="$DM"; fi                                        # <5m: cache still warm → dim, matches the primary text
            fi
        fi
        if [ -z "$lm_primary" ]; then                                       # no session duration → fall back to the legacy clock label
            lm_primary="$last_msg"
            if [ -n "$lm_delta" ]; then                                     # clock fallback + Δ>=60 only: prefix local "MM-DD" on a prior-day prompt
                local lm_day now_day
                lm_day=$(date -r "$lm_epoch" '+%Y-%m-%d' 2>/dev/null)        # local calendar day of the prompt
                now_day=$(date -r "$now" '+%Y-%m-%d' 2>/dev/null)           # local calendar day of the render
                if [ -n "$lm_day" ] && [ -n "$now_day" ] && [ "$lm_day" != "$now_day" ]; then
                    lm_primary="${lm_day:5} $last_msg"                       # different local day → prefix "MM-DD" (strip the leading "YYYY-")
                fi
            fi
        fi
        if [ -n "$lm_delta" ]; then
            seg_lastmsg="${DM}${lm_primary}${RS} ${lm_col}(${lm_delta})${RS}"
        else
            seg_lastmsg="${DM}${lm_primary}${RS}"                           # <1 min since last prompt (or no prompt yet) → primary only, no Δ
        fi
        parts+=("$seg_lastmsg")
    fi
}


# Right (the right-align anchor): git / worktree / session name — the session name is the longest and least important,
# so it goes at the very end of the line, minimizing what's sacrificed when the terminal can't fit it and truncates.
build_right() {
    parts2=()
    seg_git_full=""; seg_git_nodiff=""; seg_worktree=""; seg_session=""

    if [ -n "$git_branch" ]; then
        seg_git_nodiff="${WH}${git_branch}${git_dirty}${RS}"   # branch + dirty marker, no diffstat (degrade step 2 drops only the +N/-N)
        git_seg="$seg_git_nodiff"
        if [ -n "$git_ins" ]; then git_seg="${git_seg} ${GR}+${git_ins}${RS}"; fi
        if [ -n "$git_del" ]; then
            if [ -n "$git_ins" ]; then git_seg="${git_seg}${SP}/${RS}${RD_DATA}-${git_del}${RS}"
            else git_seg="${git_seg} ${RD_DATA}-${git_del}${RS}"; fi
        fi
        seg_git_full="$git_seg"
        parts2+=("$seg_git_full")
    fi
    [ -n "$worktree_name" ] && { seg_worktree="${DM}[wt:${worktree_name}]${RS}"; parts2+=("$seg_worktree"); }
    [ -n "$session_name" ] && { seg_session="${DM}${session_name}${RS}"; parts2+=("$seg_session"); }
}


# Rebuild parts[] / parts2[] applying the fixed sacrifice order CUMULATIVELY up to step $1 (an integer 2..14). The 14-step order
# (spec "Fixed sacrifice order") degrades from the widest configuration down to the narrowest; render_line increments the step until
# the assembled line fits the drawable width, applying each step only when the prior step still overflows (earliest sufficient step).
# Steps map: 1 = gap→junction (done by render_line's junction tier, not here); 2 drop diffstat; 3 drop worktree; 4 ctx→compact;
# 5 drop git branch; 6 drop last-msg; 7 drop 7d; 8 drop token (session+subagent as one unit); 9 model→compact; 10 drop model;
# 11 truncate session with … (done by render_line's right-truncation tier); 12 drop session; 13 5h→compact (keep burn, drop countdown);
# 14 core only = path + ctx%. Shrink precedes drop for every segment that has both forms (4<later ctx drop never happens since % is core;
# 9<10 model; 11<12 session; 13 collapses 5h, never dropped — it stays as the core-adjacent resource). Core (path + ctx%) is never dropped.
degrade_layout() {   # $1 = sacrifice step (2..14) → rebuild parts[] / parts2[]
    local step=$1
    # Left half, in display order. Each segment included unless its drop step has been reached; ctx/model/5h swap to compact at their step.
    parts=()
    [ -n "$seg_path" ] && parts+=("$seg_path")                                  # core: always present
    if   [ -n "$seg_model_full" ] && [ "$step" -lt 9 ]; then parts+=("$seg_model_full")     # step 9 compacts, 10 drops
    elif [ -n "$seg_model_compact" ] && [ "$step" -lt 10 ]; then parts+=("$seg_model_compact"); fi
    [ -n "$seg_effort" ] && [ "$step" -lt 14 ] && parts+=("$seg_effort")        # effort/thinking carry no own step; the core-only tier (14) clears all non-core left segments
    [ -n "$seg_thinking" ] && [ "$step" -lt 14 ] && parts+=("$seg_thinking")
    if   [ "$step" -lt 4 ] && [ -n "$seg_ctx_full" ]; then parts+=("$seg_ctx_full")         # step 4 collapses bar→plain N%; the % survives every tier (core)
    elif [ -n "$seg_ctx_compact" ]; then parts+=("$seg_ctx_compact"); fi
    [ -n "$seg_tok" ] && [ "$step" -lt 8 ] && parts+=("$seg_tok")               # step 8 drops session+subagent together
    if   [ "$step" -lt 13 ] && [ -n "$seg_5h_full" ]; then parts+=("$seg_5h_full")          # step 13 collapses 5h to remaining% (+burn); never dropped
    elif [ -n "$seg_5h_compact" ]; then parts+=("$seg_5h_compact"); fi
    [ -n "$seg_7d" ] && [ "$step" -lt 7 ] && parts+=("$seg_7d")                 # step 7 drops the 7d quota
    [ -n "$seg_lastmsg" ] && [ "$step" -lt 6 ] && parts+=("$seg_lastmsg")       # step 6 drops the last-message time

    # Right half. git: full→nodiff at step 2, dropped at step 5; worktree dropped at step 3; session dropped at step 12
    # (step 11 = truncate session is delegated to render_line's right-truncation tier, which keeps git and cuts the name tail).
    parts2=()
    if   [ "$step" -lt 2 ] && [ -n "$seg_git_full" ]; then parts2+=("$seg_git_full")
    elif [ "$step" -lt 5 ] && [ -n "$seg_git_nodiff" ]; then parts2+=("$seg_git_nodiff"); fi
    [ -n "$seg_worktree" ] && [ "$step" -lt 3 ] && parts2+=("$seg_worktree")
    [ -n "$seg_session" ] && [ "$step" -lt 12 ] && parts2+=("$seg_session")
}


join_parts() {   # $@=parts → _line
    _line=""
    local p
    for p in "$@"; do
        if [ -z "$_line" ]; then _line="$p"; else _line="${_line}${SEP}${p}"; fi
    done
}

# Visible column width (for the right-align gap calc): strip ANSI SGR codes, then convert to display cells.
# Precondition: any ESC in the string can only be our own SGR code (always ends with m) — external strings' control chars
# are already stripped at the parse_input entry, otherwise "strip up to the first m" would diverge from the terminal's CSI parsing.
# Under LC_ALL=C, ${#} counts bytes: the narrow multibyte chars we emit (│ ·) are first swapped to a 1-byte stand-in,
# the remaining non-ASCII is uniformly counted as 3-byte CJK = 2 cells (ceil bytes*2/3). 2/4-byte chars get overestimated,
# and 3-byte narrow chars (e.g. half-width katakana = 1 cell) also get overestimated to 2 — a known limitation, not worth a wcwidth table.
# The overestimate direction is safe: the gap only shrinks (right edge tucks in slightly), it never blows up the line width and wraps the single line into two.
vis_width() {   # $1=string with color codes → _w=visible column width
    local s=$1 t="" na
    while [[ $s == *$'\033['* ]]; do
        t+=${s%%$'\033['*}              # take the visible text before the ESC
        s=${s#*$'\033['}; s=${s#*m}     # an SGR code always ends with m, the shortest match eats exactly one code
    done
    t+=$s
    t=${t//│/N}; t=${t//·/N}; t=${t//…/N}; t=${t//⊂/N}; t=${t//↘/N}; t=${t//⚑/N}   # fold the narrow multibyte chars we emit (junction │ · … ⊂ token, ↘ burn, ⚑ 200k cliff) back to 1 byte
    na=${t//[$'\001'-$'\177']/}         # strip all ASCII, leaving only non-ASCII bytes
    _w=$(( ${#t} - ${#na} + (${#na} * 2 + 2) / 3 ))
}

# Head-truncate to $2 visible columns (incl. the trailing …): keep the front of the string, cut the tail and append …; used to shrink the name when right-aligning.
# ANSI SGR is preserved as-is (zero width), UTF-8/wide chars are correct (perl \p{EA=W} counts 2 cells) — under LC_ALL=C bash
# iterates bytes, which would corrupt a multibyte char if cut and also count width differently from the terminal, so this part is handed to perl.
# The string is fed via stdin (-CS reliably UTF-8-decodes, steadier than argv's -A); perl returns two lines: line 1 = the exact post-truncation
# visible width, line 2 onward = the truncated string; bash trusts that width (_tw) directly instead of recounting, eliminating pad miscalculation.
# Only called on the narrow "doesn't fit on one line" path; common wide terminals take the zero-fork gap>=2 alignment path above and are unaffected.
trunc_head() {   # $1=string with color codes $2=visible-width cap (>=2) → _trunc (visible width=_tw<=$2, gets … only if cut)
    local out
    out=$(printf '%s' "$1" | perl -CS -e '
        my $b=$ARGV[0]; my $lim=$b-1; local $/; my $s=<STDIN>; chomp $s;
        my $w=0; my $o=""; my $cut=0;
        while (length $s) {
            if ($s =~ s/^(\x1b\[[0-9;]*m)//) { $o.=$1; next; }   # SGR code: take as-is, zero width
            $s =~ s/^(.)//s; my $c=$1;
            my $cw = ($c =~ /[\p{East_Asian_Width=Wide}\p{East_Asian_Width=Fullwidth}]/) ? 2 : 1;
            if ($w+$cw > $lim) { $cut=1; last }
            $o.=$c; $w+=$cw;
        }
        my $tw=$w + ($cut?1:0);
        print "$tw\n" . $o . "\x1b[0m" . ($cut ? "\x{2026}" : "");   # reset before appending …, so the … is not colored
    ' -- "$2")   # -- terminates perl option parsing: a negative cap (pathological 1-2 col terminal) is an ARGV value, not an "Unrecognized switch" error to stderr
    if [ -n "$out" ]; then
        _tw=${out%%$'\n'*}
        _trunc=${out#*$'\n'}
        return
    fi
    # perl absent or failed (empty capture; rc ignored — set -e is banned) → width-safe pure-bash degraded fallback.
    # Never overflows/wraps; keeps the colored original when it fits whole, drops color only on the rare must-cut branch.
    # Reuses vis_width's over-estimating byte logic so _tw >= true visible width — the safe direction (pad only shrinks).
    vis_width "$1"
    if [ "$_w" -le "$2" ]; then _trunc=$1; _tw=$_w; return; fi   # fits whole → keep colored original, no …
    local p=$1 plain="" best="" L=0 lb       # must cut: strip ANSI (avoids dangling-escape corruption), then grow a
    while [[ $p == *$'\033['* ]]; do plain+=${p%%$'\033['*}; p=${p#*$'\033['}; p=${p#*m}; done
    plain+=$p                                #   byte-prefix to the widest visible width that still leaves a cell for …
    _tw=1                                    # … alone is 1 cell; best stays empty if not even one char fits (loop breaks early, bounded by cap)
    while [ "$L" -lt "${#plain}" ]; do
        vis_width "${plain:0:$((L+1))}"
        [ "$_w" -gt $(( $2 - 1 )) ] && break
        best=${plain:0:$((L+1))}; _tw=$(( _w + 1 )); L=$((L+1))
    done
    # best is a byte-prefix (LC_ALL=C slices bytes); if the byte right after it is a UTF-8 continuation byte (0x80-0xBF)
    # the cut landed mid-character → peel the partial trailing char off so we never emit invalid UTF-8 (a replacement
    # glyph + width desync). Width only shrinks, the safe direction: _tw stays an upper bound so the pad never under-fills.
    case ${plain:${#best}:1} in
        [$'\200'-$'\277'])
            while [ -n "$best" ]; do
                lb=${best: -1}; best=${best%?}
                case $lb in [$'\200'-$'\277']) ;; *) break ;; esac
            done ;;
    esac
    _trunc="${best}"$'\033[0m'"…"
}

# Print one part bounded to $2 visible columns: print whole if it fits, else head-truncate with … . Single source for the
# left-only / right-empty width-bounding tiers in render_line (previously two byte-identical blocks → fix-one-forget-the-other risk).
emit_bounded() {   # $1=string with color codes $2=visible-width cap
    vis_width "$1"
    if [ "$_w" -le "$2" ]; then printf '%s\n' "$1"
    else trunc_head "$1" "$2"; printf '%s\n' "$_trunc"; fi
}

# Core-only tier (sacrifice step 14): emit just the path basename + context percentage, NEVER dropping either (spec "Core always remains").
# When even "<path> <ctx%>" exceeds the drawable width, the PATH is head-truncated to free room while the ctx% rides at the tail intact —
# the percentage is the one piece that must survive a 1-2 column terminal. With no ctx% present (no usage), this degrades to bounding the
# path alone. Width-safe with perl absent (trunc_head's pure-bash fallback). avail can be <=0 at a 1-2 col terminal; trunc_head handles it.
render_core_only() {   # $1=avail (drawable width)
    local avail=$1 core ctxw
    if [ -n "$seg_ctx_compact" ]; then
        vis_width "$seg_ctx_compact"; ctxw=$_w
        # reserve the % (+1 gap) at the tail; head-truncate the path into whatever is left, then re-join with a single space
        if [ -n "$seg_path" ]; then
            local pbudget=$(( avail - ctxw - 1 ))
            if [ "$pbudget" -ge 2 ]; then
                trunc_head "$seg_path" "$pbudget"
                printf '%s %s\n' "$_trunc" "$seg_ctx_compact"
            else
                emit_bounded "$seg_ctx_compact" "$avail"   # not even one path cell + % fits → keep the % alone, bounded
            fi
        else
            emit_bounded "$seg_ctx_compact" "$avail"
        fi
    else
        emit_bounded "${seg_path:-$left}" "$avail"        # no ctx% to protect → just bound the path (or whatever the left holds)
    fi
}

# Single-line output: left ──gap── right (right-aligned to the drawable right edge at term_cols-EDGE_PAD).
# The junction │ appears only when "merged" — placed only when the gap between the two parts is <JGAP (otherwise a │ floating in a big whitespace gap looks odd);
# when the gap is >=JGAP, plain whitespace separates them with no │. When placed, the │ hugs the right part, its leading space coming from the gap, reading as " │ ".
# When the line doesn't fit (gap<1): keep the left part whole, truncate the right part (name at the very end) with … to fit exactly, still right-aligned —
# never lets the whole line exceed the drawable width and get hard-cut by the terminal (the old │-join fallback emitted an over-wide line whose name the terminal ate; fixed).
# Pathologically narrow terminal where even the left part is wider than the drawable width: drop the right part, head-truncate the left part too to guarantee no overflow.
# Right empty but width known (non-git dir, no session name): bound the left part alone (same head-truncate) so a long left (deep path / long last-msg) can't overflow/wrap.
# Fallback: RIGHT_ALIGN off / width unavailable → can't measure width, so do the old │-join; one side empty → print the other.
render_line() {
    SEP="${SP} │ ${RS}"
    local JSEP="${SP}│ ${RS}" JSEP_W=2   # junction separator: │ + trailing space (2 visible cells), the leading space comes from the gap
    join_parts "${parts[@]}";  left="$_line"
    join_parts "${parts2[@]}"; right="$_line"

    # Fixed sacrifice order (spec "Fixed sacrifice order" / "Width-tiered rendering"): when width is measurable and the full set
    # doesn't fit even at the junction tier, walk degrade_layout in the fixed 14-step order — applying each step only when the prior
    # step still overflows — until the line fits. Steps split across two helpers so SHRINK precedes DROP for the session:
    #  • Phase A (steps 2..11): drop diffstat / worktree / ctx-compact / git / last-msg / 7d / token / model-compact / model-drop,
    #    then at step 11 the session is still PRESENT — the fall-through right-truncation tier head-truncates it with … (step 11's action).
    #    The loop breaks at the earliest step whose junction/roomy layout fits, OR (at step 11) when a … -truncated session is still viable
    #    (rbudget>=2) so the session is TRUNCATED before it is ever dropped (spec "Shrink and truncate preferred over drop").
    #  • Phase B (steps 12..13): only if even a 2-cell-truncated session can't fit — drop the session, then collapse the 5h quota to
    #    remaining% (keeping any burn alarm). Step 14 (core only) is the final guarantee that path + ctx% survive.
    # The full set still fits → the loop body never runs, so the roomy / junction tiers below handle the wide common case unchanged
    # (existing A/A2/B/J/K behaviours preserved). Step 1 (gap→junction) and 11/14 (truncate) are realised by the tiers below.
    if [ -n "$left" ] && $RIGHT_ALIGN && [ "${term_cols:-0}" -gt 0 ] 2>/dev/null; then
        local _avail=$(( term_cols - EDGE_PAD )) _step _lw _rw _jw _rb
        vis_width "$left"; _lw=$_w; vis_width "$right"; _rw=$_w
        # junction-tier width = left + " │ " (JSEP_W) + right, with the leading gap; fits when there's room for at least a 1-cell gap.
        if [ $(( _avail - _lw - ( _rw>0 ? JSEP_W : 0 ) - _rw )) -lt "$JGAP" ]; then
            _step=2
            while [ "$_step" -le 13 ]; do
                degrade_layout "$_step"
                join_parts "${parts[@]}";  left="$_line";  vis_width "$left";  _lw=$_w
                join_parts "${parts2[@]}"; right="$_line"; vis_width "$right"; _rw=$_w
                if [ -n "$right" ]; then _jw=$(( _lw + JSEP_W + _rw )); else _jw=$_lw; fi
                [ $(( _avail - _jw )) -ge 1 ] && break          # earliest step whose junction/roomy layout leaves >=1 gap → done
                # At step 11 the session is still present: prefer truncating it (fall-through right-truncation) over dropping it (step 12).
                # rbudget mirrors the fall-through tier's budget; >=2 means a … -truncated right still fits, so stop here and let it render.
                if [ "$_step" -eq 11 ] && [ -n "$right" ]; then
                    _rb=$(( _avail - _lw - JSEP_W - 1 ))
                    [ "$_rb" -ge 2 ] && break
                fi
                _step=$(( _step + 1 ))
            done
            # Core-only tier (step 14): if even step 13's left (path + ctx% + collapsed 5h) overflows, drop to the bare core
            # path + ctx% and head-truncate the PATH (not the %) so the context percentage always survives (spec "Core always remains").
            if [ -z "$right" ] && [ $(( _avail - _lw )) -lt 1 ]; then
                render_core_only "$_avail"
                return
            fi
        fi
    fi

    if [ -n "$left" ] && [ -n "$right" ] && $RIGHT_ALIGN \
       && [ "${term_cols:-0}" -gt 0 ] 2>/dev/null; then
        local avail=$(( term_cols - EDGE_PAD ))
        vis_width "$left";  lw=$_w
        vis_width "$right"; rw=$_w
        # Roomy: >=JGAP whitespace still fits between left and right → plain whitespace gap, no junction │ (otherwise the │ floats in the whitespace)
        gap=$(( avail - lw - rw ))
        if [ "$gap" -ge "$JGAP" ]; then
            printf -v pad '%*s' "$gap" ''
            printf '%s%s%s\n' "$left" "$pad" "$right"
            return
        fi
        # Merged (the two parts nearly touch): place the junction │ separator; if it fits, right-align, otherwise truncate the name (still keeping the │)
        gap=$(( avail - lw - JSEP_W - rw ))
        if [ "$gap" -ge 1 ]; then
            printf -v pad '%*s' "$gap" ''
            printf '%s%s%s%s\n' "$left" "$pad" "$JSEP" "$right"
            return
        fi
        # Doesn't fit: keep the left part, truncate the right to rbudget (keep git, cut the name tail), still keep the junction │, right-aligned
        local rbudget=$(( avail - lw - JSEP_W - 1 ))   # -1 reserves the minimum one-cell gap
        if [ "$rbudget" -ge 2 ]; then
            trunc_head "$right" "$rbudget"    # _tw = exact post-truncation visible width (perl-computed, always <=rbudget)
            printf -v pad '%*s' "$(( avail - lw - JSEP_W - _tw ))" ''   # pad>=1, line width is exactly avail
            printf '%s%s%s%s\n' "$left" "$pad" "$JSEP" "$_trunc"
            return
        fi
        # The left part nearly fills the whole terminal: the right has no room → drop it; head-truncate the left only if it's over-wide
        emit_bounded "$left" "$avail"
        return
    fi
    # Left-only (right empty) with a known width: still bound the left part. The block above is gated on a non-empty
    # right, so without this a long left (deep path / long last-msg) on a narrow terminal would fall through to the
    # unbounded printf below and get hard-wrapped — breaking the "never overflows" guarantee. Mirrors the pathological
    # left-truncation branch above. (avail can go negative at a 1-2 col terminal; trunc_head handles that gracefully now.)
    if [ -n "$left" ] && [ -z "$right" ] && $RIGHT_ALIGN \
       && [ "${term_cols:-0}" -gt 0 ] 2>/dev/null; then
        avail=$(( term_cols - EDGE_PAD ))
        emit_bounded "$left" "$avail"
        return
    fi
    if [ -n "$left" ] && [ -n "$right" ]; then
        printf '%s%s%s\n' "$left" "$SEP" "$right"
    else
        printf '%s\n' "${left}${right}"
    fi
}
