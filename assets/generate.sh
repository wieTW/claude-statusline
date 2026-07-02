#!/usr/bin/env bash
# Regenerates the README screenshot SVGs from ACTUAL statusline output — the images are never
# mocked up. Each scenario builds a fixture (fake $HOME caches, a demo git repo, a status JSON),
# pipes it through statusline-command.sh exactly like Claude Code does, and converts the ANSI
# line to SVG with ansi2svg.py.
#
# Dev-only tool (not part of the runtime): needs jq (already a runtime dep), git, python3.
# Usage: bash assets/generate.sh    → rewrites assets/{hero,alerts,degrade,themes}.svg
# Output is deterministic (all times are fixed offsets from now), so re-running produces
# byte-identical SVGs unless the statusline's rendering actually changed.

SL=$(cd "$(dirname "$0")/.." && pwd)
OUT="$SL/assets"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/sl-assets.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

NOW=$(date +%s)

# --- demo git repo: on main, one modified file → "main* +68/-14" -------------------------------
REPO="$WORK/repo/claude-statusline"
mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" checkout -q -b main 2>/dev/null
seq 14 | sed 's/^/old-line-/' > "$REPO/render.sh"
git -C "$REPO" add -A
git -C "$REPO" -c user.email=demo@demo -c user.name=demo commit -qm demo
seq 68 | sed 's/^/new-line-/' > "$REPO/render.sh"

# mk_home <name> <session_tokens> <subagent_tokens> <lastmsg_age_s>  → sets $FH
mk_home() {
    FH="$WORK/home-$1"
    mkdir -p "$FH/.claude/last-msg"
    printf 'T demo-sess %s %s 100 %s 100 %s\n' "$2" "$3" "$NOW" "$NOW" > "$FH/.claude/sl-tokens-cache"
    printf '%s %s\n' "$(date -r $((NOW - $4)) +%H:%M)" "$((NOW - $4))" > "$FH/.claude/last-msg/demo-sess"
}

# hero_json — a healthy mid-session frame (42% ctx, quotas fine, cache warm)
hero_json() {
    jq -n --arg cwd "$REPO" '{
      workspace:{current_dir:$cwd}, model:{display_name:"Opus 4.8"},
      context_window:{used_percentage:42, exceeds_200k_tokens:false},
      rate_limits:{five_hour:{used_percentage:63, resets_at:(now+7800|floor)},
                   seven_day:{used_percentage:28, resets_at:(now+453600|floor)}},
      session_id:"demo-sess", transcript_path:"/nonexistent/demo.jsonl", session_name:"auth-refactor",
      cost:{total_duration_ms:4500000, total_api_duration_ms:2725000}
    }'
}

# render <home> <cols> [script]  — stdin: status JSON; stdout: one ANSI line
render() {
    HOME="$1" COLUMNS="$2" bash "${3:-$SL/statusline-command.sh}"
}

# --- 1. hero: the full healthy line ------------------------------------------------------------
mk_home hero 128400 23100 180
hero_json | render "$FH" 140 | python3 "$OUT/ansi2svg.py" > "$OUT/hero.svg"

# --- 2. alerts: every warning that only shows when real -----------------------------------------
# 1M-context model near its budget (red 93% + ⚑ past the 200k cliff), thinking off (no-think),
# 5h quota burning fast enough to run dry 23m from now — before its reset (↘23m), 7d nearly gone,
# last prompt 75m ago (red Δ: even the extended prompt cache has expired).
mk_home alerts 412300 88400 4500
R5=$((NOW + 6600))
printf 'P %s %s 51\n' "$R5" "$((NOW - 2400))" > "$FH/.claude/sl-ratelimit-cache"   # burn-slope sample: 51%→82% used in 40m
jq -n --arg cwd "$REPO" --argjson r5 "$R5" '{
  workspace:{current_dir:$cwd}, model:{display_name:"Opus 4.8 (1M context)"},
  context_window:{used_percentage:93, exceeds_200k_tokens:true},
  thinking:{enabled:false},
  rate_limits:{five_hour:{used_percentage:82, resets_at:$r5},
               seven_day:{used_percentage:91, resets_at:(now+93600|floor)}},
  session_id:"demo-sess", transcript_path:"/nonexistent/demo.jsonl",
  cost:{total_duration_ms:9900000, total_api_duration_ms:7500000}
}' | render "$FH" 140 | python3 "$OUT/ansi2svg.py" > "$OUT/alerts.svg"

# --- 3. degrade: the same healthy status at shrinking terminal widths ---------------------------
mk_home degrade 128400 23100 180
{
    for w in 140 100 70 50 24; do
        printf '@@%s columns\n' "$w"
        hero_json | render "$FH" "$w"
    done
} | python3 "$OUT/ansi2svg.py" --pad-cols 140 > "$OUT/degrade.svg"

# --- 4. themes: the same frame under each STYLE ------------------------------------------------
mk_home themes 128400 23100 180
{
    for s in claude tokyo-night tokyo-night-claude catppuccin rose-pine; do
        T="$WORK/theme-$s"
        mkdir -p "$T"
        cp -R "$SL/lib" "$T/lib"
        sed "s/^STYLE=.*/STYLE=\"$s\"/" "$SL/statusline-command.sh" > "$T/statusline-command.sh"
        printf '@@STYLE="%s"\n' "$s"
        hero_json | render "$FH" 140 "$T/statusline-command.sh"
    done
} | python3 "$OUT/ansi2svg.py" > "$OUT/themes.svg"

ls -la "$OUT"/hero.svg "$OUT"/alerts.svg "$OUT"/degrade.svg "$OUT"/themes.svg
