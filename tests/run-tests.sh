#!/usr/bin/env bash
# statusline single-line integration tests: fake HOME + controlled COLUMNS run the real script, asserting alignment / fallback / content.
# All run in-process via direct calls — no export/bash -c (a prior version's exported-function env passing blew up).
# Self-locating: SL = the statusline project root (this script lives in <root>/tests/). Survives directory renames.
# Work dir is a fresh mktemp (NOT /tmp/sl-test — that hardcoded path is exactly why the old harness vanished on tmp-clear).
set -u
SL=$(cd "$(dirname "$0")/.." && pwd)
SLDIR=$(basename "$SL")   # project-dir basename, shown as the path segment; derived (not hardcoded) so the order check survives a repo rename
# The git label the statusline shows for this checkout, derived by the rule lib/collect.sh documents: the branch name, or the
# short sha when HEAD is detached. `branch --show-current` prints nothing on a detached HEAD, and the old `:-main` fallback then
# made A2 expect "main" while the line showed the sha, so every temporary worktree of a historical commit read red.
# Empty (not a git checkout) is left empty on purpose: A2 then fails with its own message instead of matching any text.
SLBR=$(git -C "$SL" symbolic-ref --short -q HEAD 2>/dev/null || git -C "$SL" rev-parse --short HEAD 2>/dev/null)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/sl-test.XXXXXX")
T4UDIR=""   # T4(c)'s probe directory under /Users/Shared, outside $WORK; set only while it exists
trap 'rm -rf "$WORK"; [ -z "$T4UDIR" ] || rm -rf "$T4UDIR"' EXIT
# Wall-clock second this run began. Only T4(b) uses it: that block audits the user's REAL shared cache, and it must be able to
# tell a row THIS run could have stamped (timestamp >= HARNESS_T0) from one that was already on disk when the run started.
# Taken here, before the first frame renders, so no write by any section of this harness can predate it.
HARNESS_T0=$(date +%s)
FAKE_HOME="$WORK/home"
TP="$WORK/transcript.jsonl"
mkdir -p "$FAKE_HOME/.claude/last-msg"
printf '06-07 19:38\n' > "$FAKE_HOME/.claude/last-msg/sl-selftest"
# The shape Claude Code writes for an interactive /effort: a user record whose message.content is the command's stdout.
printf '{"type":"user","message":{"role":"user","content":"<local-command-stdout>Set effort level to ultracode (this session only): xhigh + dynamic workflow orchestration</local-command-stdout>"}}\n' > "$TP"
# Hermetic git repo for width-sensitive git-segment fixtures: a clean, commit-less repo yields a deterministic
# "branch only, no dirty, no diffstat" segment. Using the live repo ($SL) would make the segment width track this
# checkout's uncommitted diff, flaking name-budget asserts (e.g. J) whenever the working tree is dirty.
GREPO="$WORK/grepo"; git init -q "$GREPO" >/dev/null 2>&1 || mkdir -p "$GREPO"

# Pull EDGE_PAD / JGAP from the script so the asserts track the real config instead of hardcoding 3 / 2.
EDGE_PAD=$(sed -n 's/^EDGE_PAD=\([0-9][0-9]*\).*/\1/p' "$SL/statusline-command.sh"); EDGE_PAD=${EDGE_PAD:-3}
JGAP=$(sed -n 's/^JGAP=\([0-9][0-9]*\).*/\1/p' "$SL/statusline-command.sh"); JGAP=${JGAP:-2}
# Which of the (at most) two output lines is the subagent summary line. Read from the script like EDGE_PAD / JGAP, so the
# helpers that tell the two lines apart follow the constant and only the SUB1 case that pins the shipped value would change
# with it. Empty (a build without the constant) behaves as "above", the same as any value other than "below".
SUBPOS=$(sed -n 's/^SUB_LINE_POS=\([A-Za-z]*\).*/\1/p' "$SL/statusline-command.sh")

# SET (seeded here, checked after the last section): neither command may write, create, rename or remove a settings file
# under ~/.claude. Two fixed files with a two-day-old mtime sit in the fake HOME for the whole run; every SA and SUB
# invocation (and every other frame) runs against that HOME. No "theme" key, so the palette resolves exactly as before
# (resolve_theme's fallback is "dark", which load_palette treats like the empty theme).
printf '{"permissions":{"allow":[]},"statusLine":{"type":"command","refreshInterval":60}}\n' > "$FAKE_HOME/.claude/settings.json"
printf '{"permissions":{"deny":[]}}\n' > "$FAKE_HOME/.claude/settings.local.json"
touch -t "$(date -v-2d +%Y%m%d%H%M.%S)" "$FAKE_HOME/.claude/settings.json" "$FAKE_HOME/.claude/settings.local.json"
setsnap() { local f; for f in settings.json settings.local.json; do printf '%s %s %s\n' "$f" "$(cksum < "$FAKE_HOME/.claude/$f" 2>&1)" "$(stat -f %m "$FAKE_HOME/.claude/$f" 2>&1)"; done; }
SETSNAP0=$(setsnap)

mkjson() {  # $1=cwd $2=project_dir $3=session_name → one-line statusline JSON on stdout
  jq -cn --arg cwd "$1" --arg proj "$2" --arg sn "$3" --arg tp "$TP" '
  { workspace:{current_dir:$cwd, project_dir:$proj},
    model:{display_name:"Opus 4.8 (1M context)"},
    session_name:$sn,
    context_window:{used_percentage:6.2},
    rate_limits:{ five_hour:{used_percentage:23, resets_at:(now+3960|floor)},
                  seven_day:{used_percentage:84, resets_at:(now+112000|floor)} },
    session_id:"sl-selftest",
    transcript_path:$tp,
    effort:{level:"xhigh"},
    thinking:{enabled:true} }'
}

run() { printf '%s' "$2" | env COLUMNS="$1" HOME="$FAKE_HOME" bash "$SL/statusline-command.sh"; }

check() {  # stdin=output, $1=exact|max|min $2=expected width → assert single line + display width (CJK=2 cells)
  # Must run via -c, NOT heredoc: a heredoc steals stdin so the data side reads nothing (already hit).
  python3 -c '
import sys, re, unicodedata
mode, want = sys.argv[1], int(sys.argv[2])
lines = sys.stdin.buffer.read().decode("utf-8").rstrip("\n").split("\n")
assert len(lines) == 1, f"FAIL expected 1 line, got {len(lines)}: {lines!r}"
plain = re.sub(r"\x1b\[[0-9;]*m", "", lines[0])
w = sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in plain)
ok = {"exact": w == want, "max": w <= want, "min": w >= want}[mode]
assert ok, f"FAIL width {w} not {mode} {want}: [{plain}]"
print(f"  width={w} [{plain[:110]}]")' "$@"
}

vw() {  # display width (strip ANSI, CJK=2 cells)
  python3 -c 'import sys,re,unicodedata
p=re.sub(r"\x1b\[[0-9;]*m","",sys.stdin.read().rstrip("\n"))
print(sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in p))'
}

J=$(mkjson "$SL" "$SL" "Consolidate statusline from two rows to one")
JCJK=$(mkjson "$SL" "$SL" "把狀態列整成一行測試")
JNOGIT=$(mkjson /private/tmp /private/tmp "")
# JLONG: hermetic GREPO (branch-only git, no dirty/diffstat) + a long session name. Defined here (not in J's section) so the earlier
# K / adaptive-layout sections can also use it — git + a wide session name keep the right half populated across squeezed widths.
JLONG=$(jq -cn --arg cwd "$GREPO" --arg proj "$GREPO" --arg tp "$TP" '
  { workspace:{current_dir:$cwd, project_dir:$proj}, model:{display_name:"Opus 4.8 (1M context)"},
    context_window:{used_percentage:3},
    rate_limits:{ five_hour:{used_percentage:40, resets_at:(now+500|floor)},
                  seven_day:{used_percentage:86, resets_at:(now+108000|floor)} },
    effort:{level:"high"}, session_id:"sl-selftest", transcript_path:$tp,
    session_name:"Consolidate statusline from two rows to one" }')
# JXLONG: GREPO git + an extra-long session name so the right half can't fit with a >=JGAP gap at mid widths — this forces the junction
# tier (│ placed, session head-truncated with …), exercising the "shrink (truncate) before drop" path that the fixed sacrifice order needs.
JXLONG=$(jq -cn --arg cwd "$GREPO" --arg proj "$GREPO" --arg tp "$TP" '
  { workspace:{current_dir:$cwd, project_dir:$proj}, model:{display_name:"Opus 4.8 (1M context)"},
    context_window:{used_percentage:3},
    rate_limits:{ five_hour:{used_percentage:40, resets_at:(now+500|floor)},
                  seven_day:{used_percentage:86, resets_at:(now+108000|floor)} },
    effort:{level:"high"}, session_id:"sl-selftest", transcript_path:$tp,
    session_name:"a very very very very very very very very very very long session name that forces right truncation" }')

fail=0
chk() { if "$@"; then :; else echo "  ★ FAIL"; fail=1; fi; }

# Baseline: content width W in the separated (no-width) fallback. Boundary cases derive from W dynamically.
W=$(run 0 "$J" | vw)
echo "baseline content width W=$W (separated mode; lw+rw=$((W-EDGE_PAD)))"

echo "── A. roomy align COLUMNS=$((W+20)): single line, width exactly $((W+20-EDGE_PAD)) (right edge = COLUMNS-EDGE_PAD)"
chk check exact $((W+20-EDGE_PAD)) < <(run $((W+20)) "$J")

echo "── A2. content order dir→model→ultra→ctx→quota→time→git→session"
plain=$(run $((W+20)) "$J" | python3 -c 'import sys,re;sys.stdout.write(re.sub(r"\x1b\[[0-9;]*m","",sys.stdin.read()))')
# An empty SLBR would turn the git slot of the pattern below into a match-anything glob, so it is a failure, not a pass.
if [ -z "$SLBR" ]; then echo "  ★ FAIL A2 could not derive this checkout's git label (is [$SL] a git checkout?)"; fail=1
else
case "$plain" in
  "$SLDIR"*"Opus 4.8(1M)"*ultra*"6%"*"77%"*"16%"*"06-07 19:38"*"$SLBR"*"Consolidate statusline from two rows to one") echo "  order OK" ;;
  *) echo "  ★ FAIL order mismatch: [$plain]"; fail=1 ;;
esac
fi

echo "── B. CJK session name: aligned width exactly $((140-EDGE_PAD)) (CJK=2 cells folds correctly)"
chk check exact $((140-EDGE_PAD)) < <(run 140 "$JCJK")

echo "── B2. boundary COLUMNS=W+JGAP → gap exactly JGAP, plain whitespace no │, right-aligned, width=W-(EDGE_PAD-JGAP)"
chk check exact $((W+JGAP-EDGE_PAD)) < <(run $((W+JGAP)) "$J")

echo "── B3. boundary COLUMNS=W+1 → gap<JGAP, junction │ placed, name truncated right (width=COLUMNS-EDGE_PAD, no overflow)"
chk check exact $((W+1-EDGE_PAD)) < <(run $((W+1)) "$J")

echo "── C. COLUMNS=0 (invalid width, unmeasurable) → cannot bound, fall back to │-join (width=W)"
chk check exact "$W" < <(run 0 "$J")

echo "── D. COLUMNS=50 (full set far wider than drawable) → degrade by the fixed sacrifice order, single line ≤ drawable, core (path+ctx%) kept"
# Post-adaptive-layout: instead of char-truncating the whole left blob to exactly fill the width (old behaviour), the renderer now
# drops/compacts segments in the fixed sacrifice order until the line fits — so it may sit BELOW the drawable width (≤, not ==), and the
# path basename + ctx% (the core) always survive. Width-bounded + single-line is the invariant (the J/P/M method); exact-fill no longer is.
out_d=$(run 50 "$J")
chk check max $((50-EDGE_PAD)) <<<"$out_d"
out_dp=$(printf '%s' "$out_d" | sed 's/\x1b\[[0-9;]*m//g')
case "$out_dp" in "$SLDIR"*"6%"*) echo "  core path + ctx% retained OK" ;; *) echo "  ★ FAIL core path/ctx% lost: [$out_dp]"; fail=1 ;; esac
[ "$(printf '%s' "$out_d" | grep -c '')" -eq 1 ] || { echo "  ★ FAIL D not single line"; fail=1; }

echo "── E. non-git + no session → right part empty, print left only, single line"
out_e=$(run 140 "$JNOGIT")
chk check max $((140-1)) <<<"$out_e"
case "$out_e" in *main*) echo "  ★ FAIL should have no git segment"; fail=1 ;; *) echo "  no git segment OK" ;; esac

echo "── K. junction │ only when 'merged': roomy(gap>=JGAP) plain whitespace gap, squeezed (right-truncated) keeps the │ junction, │-join fallback has │"
# Post-adaptive-layout the left/right junction is reached only when the right half (git + a wide session name) can't fit with a >=JGAP gap
# even after the in-order left drops — so the squeezed case uses JXLONG (extra-long name) and asserts the junction │ rides next to the
# … -truncated session, exercising step 11 (truncate before drop). roomy / fallback use JLONG. The roomy gap before the session is plain
# whitespace (no │); the in-segment │ separators inside each half are unaffected — the marker is the gap immediately before the right half.
kbad=0
ka=$(run 200 "$JLONG" | sed 's/\x1b\[[0-9;]*m//g')   # very wide: roomy, plain whitespace gap before the right half (git), no junction
# The right half starts with the git segment "main"; the gap before it is the left/right junction region. Roomy ⇒ only spaces there
# (the │ between main and the session is the right half's INTERNAL separator, not the junction — so we test the gap before "main").
case "$ka" in *"  main"*) echo "  roomy plain-whitespace gap (no junction) OK" ;; *"│ main"*) echo "  ★ FAIL roomy placed a junction │ before the right half: [$ka]"; kbad=1 ;; *) echo "  ★ FAIL roomy unexpected layout: [$ka]"; kbad=1 ;; esac
kt=$(run 120 "$JXLONG" | sed 's/\x1b\[[0-9;]*m//g')  # squeezed: junction │ placed, session head-truncated with …
case "$kt" in *"│ a very"*) ktj=1 ;; *) ktj=0 ;; esac
case "$kt" in *"…"*) ktt=1 ;; *) ktt=0 ;; esac
if [ "$ktj" -eq 1 ] && [ "$ktt" -eq 1 ]; then echo "  squeezed: junction │ + … -truncated session (shrink before drop) OK"; else echo "  ★ FAIL squeezed missing junction/… (junc=$ktj trunc=$ktt): [$kt]"; kbad=1; fi
kc=$(run 0 "$JLONG" | sed 's/\x1b\[[0-9;]*m//g')     # width unmeasurable → │-join fallback
case "$kc" in *"│"*) echo "  │-join fallback has │ OK" ;; *) echo "  ★ FAIL │-join fallback missing │"; kbad=1 ;; esac
[ "$kbad" -eq 0 ] || fail=1

echo "── F. RIGHT_ALIGN=false → output byte-for-byte identical to the 'no width' fallback"
mkdir -p "$WORK/noalign/lib" && cp "$SL"/lib/*.sh "$WORK/noalign/lib/"
sed 's/^RIGHT_ALIGN=true/RIGHT_ALIGN=false/' "$SL/statusline-command.sh" > "$WORK/noalign/statusline-command.sh"
# The two runs are independent processes that each read their own wall-clock `now`, so the rate-limit countdown token (e.g. 1H6m → 1H5m
# across a minute tick) can legitimately differ by one unit between them — that is a clock boundary, NOT a right-align divergence. Canonicalise
# every ttl token (runs of <digits><D|H|m>) before comparing so the assertion targets the right-align/fallback structure it actually tests.
ttlnorm() { sed -E 's/[0-9]+[DHm]/_/g'; }
out_f=$(printf '%s' "$J" | env COLUMNS=140 HOME="$FAKE_HOME" bash "$WORK/noalign/statusline-command.sh" | ttlnorm)
out_c=$(run 0 "$J" | ttlnorm)
if [ "$out_f" = "$out_c" ]; then echo "  identical OK"; else echo "  ★ FAIL the two fallbacks differ"; fail=1; fi

echo "── H. ESC injection: session_name with \\u001b[1Zm → control chars stripped, exact align no wrap"
JESC=$(jq -cn --arg cwd "$SL" --arg proj "$SL" --arg tp "$TP" '
  { workspace:{current_dir:$cwd, project_dir:$proj}, model:{display_name:"Opus 4.8 (1M context)"},
    session_name:"[1Zmhello", session_id:"sl-selftest", transcript_path:$tp, effort:{level:"xhigh"} }')
out_h=$(run 120 "$JESC")
case "$out_h" in *$'\033'"[1Z"*) echo "  ★ FAIL raw ESC leaked"; fail=1 ;; *) echo "  ESC stripped OK" ;; esac
chk check exact $((120-EDGE_PAD)) <<<"$out_h"

echo "── L. SEC-01: last_msg file ANSI injection stripped + session_id path traversal blocked"
# L1: a raw ESC written into the last-msg file must NOT reach the output (it bypasses parse_input).
printf '06-07 19:38\033[31mINJECT\033[0m\n' > "$FAKE_HOME/.claude/last-msg/sl-selftest"
out_l1=$(run 160 "$J")
case "$out_l1" in
  *$'\033'"[31mINJECT"*) echo "  ★ FAIL raw ESC from last-msg leaked"; fail=1 ;;
  *INJECT*) echo "  last-msg ESC stripped (inert text kept) OK" ;;
  *) echo "  ★ FAIL last-msg content unexpectedly dropped: [$(printf '%s' "$out_l1" | sed 's/\x1b\[[0-9;]*m//g')]"; fail=1 ;;
esac
chk check exact $((160-EDGE_PAD)) <<<"$out_l1"   # width still exact → vis_width did not desync into a wrap
printf '06-07 19:38\n' > "$FAKE_HOME/.claude/last-msg/sl-selftest"   # restore
# L2: a session_id shaped like a traversal must make the read be skipped, so the planted secret never appears.
printf 'SECRET-TRAVERSAL-LEAK\n' > "$FAKE_HOME/secret"
JTRAV=$(echo "$J" | jq -c '.session_id="../../secret"')
out_l2=$(run 160 "$JTRAV" | sed 's/\x1b\[[0-9;]*m//g')
case "$out_l2" in *SECRET-TRAVERSAL-LEAK*) echo "  ★ FAIL path traversal: arbitrary file leaked"; fail=1 ;; *) echo "  session_id traversal blocked OK" ;; esac

echo "── M. ROB-01: perl absent on the narrow-truncation path → still single line, no overflow/wrap"
mkdir -p "$WORK/bin"
printf '#!/bin/sh\nexit 127\n' > "$WORK/bin/perl"; chmod +x "$WORK/bin/perl"   # shadow perl with a failing stub
JLONGM=$(jq -cn --arg cwd "$SL" --arg proj "$SL" --arg tp "$TP" '
  { workspace:{current_dir:$cwd, project_dir:$proj}, model:{display_name:"Opus 4.8 (1M context)"},
    context_window:{used_percentage:3}, effort:{level:"high"}, session_id:"sl-selftest", transcript_path:$tp,
    session_name:"a deliberately long session name to force the narrow-terminal truncation path" }')
mbad=0
for cols in 70 90 110 130; do
  o=$(printf '%s' "$JLONGM" | env PATH="$WORK/bin:$PATH" COLUMNS="$cols" HOME="$FAKE_HOME" bash "$SL/statusline-command.sh")
  nl=$(printf '%s' "$o" | grep -c '')
  w=$(printf '%s' "$o" | vw)
  [ "$nl" -eq 1 ]            || { echo "  ★ FAIL perl-absent C=$cols not single line: $nl"; mbad=1; }
  [ "$w" -le $((cols-EDGE_PAD)) ] || { echo "  ★ FAIL perl-absent C=$cols overflow: width=$w > $((cols-EDGE_PAD))"; mbad=1; }
done
[ "$mbad" -eq 0 ] && echo "  perl-absent 70..130: single line, never overflows OK" || fail=1

echo "── I. half-width katakana (known limitation): only shrinks, never blows up — single line, width ≤120"
JKANA=$(jq -cn --arg cwd "$SL" --arg proj "$SL" --arg tp "$TP" '
  { workspace:{current_dir:$cwd, project_dir:$proj}, model:{display_name:"Opus 4.8 (1M context)"},
    session_name:"ｾｯｼｮﾝ", session_id:"sl-selftest", transcript_path:$tp, effort:{level:"xhigh"} }')
chk check max 120 < <(run 120 "$JKANA")

echo "── J. long name + narrow terminal (original bug scenario): sweep 80..150, never overflow, name segment always present"
jbad=0
for cols in 80 100 110 120 125 130 135 140 145 150; do
  o=$(run "$cols" "$JLONG")
  w=$(printf '%s' "$o" | vw)
  nl=$(printf '%s' "$o" | grep -c '')
  [ "$w" -le "$cols" ]       || { echo "  ★ FAIL C=$cols overflow: width=$w"; jbad=1; }
  [ "$nl" -eq 1 ]            || { echo "  ★ FAIL C=$cols not single line: $nl"; jbad=1; }
  [ "$w" -eq $((cols-EDGE_PAD)) ] || { echo "  ★ FAIL C=$cols width $w != edge $((cols-EDGE_PAD))"; jbad=1; }
  if [ "$cols" -ge 120 ]; then
    case "$o" in *Conso*) : ;; *) echo "  ★ FAIL C=$cols name segment vanished"; jbad=1 ;; esac
  fi
done
[ "$jbad" -eq 0 ] && echo "  80..150: single line, no overflow, width=edge; >=120 name present OK" || fail=1

echo "── N. SEC-02: C1 controls U+0080-U+009F (8-bit CSI/OSC) stripped from session_name AND last-msg"
# U+009B == "ESC [" on a UTF-8 terminal that honors C1; it survived the old C0/DEL-only strip and could inject.
noc1() { python3 -c 'import sys; sys.exit(1 if b"\xc2\x9b" in sys.stdin.buffer.read() else 0)'; }   # exit 0 = clean
JC1=$(jq -cn --arg cwd "$SL" --arg proj "$SL" --arg tp "$TP" '
  { workspace:{current_dir:$cwd, project_dir:$proj}, model:{display_name:"Opus 4.8 (1M context)"},
    session_name:(([155]|implode)+"2J"), session_id:"sl-selftest", transcript_path:$tp, effort:{level:"xhigh"} }')
if run 160 "$JC1" | noc1; then echo "  session_name C1 stripped OK"; else echo "  ★ FAIL C1 byte leaked from session_name"; fail=1; fi
chk check exact $((160-EDGE_PAD)) < <(run 160 "$JC1")   # width still exact → no vis_width desync/wrap
printf '06-07 \302\2332J\n' > "$FAKE_HOME/.claude/last-msg/sl-selftest"   # raw U+009B in the last-msg file (bypasses parse_input)
if run 160 "$J" | noc1; then echo "  last-msg C1 stripped OK"; else echo "  ★ FAIL C1 byte leaked from last-msg"; fail=1; fi
printf '06-07 19:38\n' > "$FAKE_HOME/.claude/last-msg/sl-selftest"   # restore

echo "── O. PERF-01: a multi-KB session_name can't stall the frame (vis_width's ASCII strip is O(n^2); input capped at 256)"
OBIG=$(printf 'x%.0s' $(seq 1 8000))
JOBIG=$(jq -cn --arg cwd "$SL" --arg proj "$SL" --arg sn "$OBIG" --arg tp "$TP" '
  { workspace:{current_dir:$cwd, project_dir:$proj}, model:{display_name:"Opus"}, session_name:$sn,
    session_id:"sl-selftest", transcript_path:$tp }')
SECONDS=0; run 120 "$JOBIG" >/dev/null
if [ "$SECONDS" -lt 3 ]; then echo "  8KB name frame ${SECONDS}s (uncapped this was ~4-5s, 20KB ~33s) OK"; else echo "  ★ FAIL 8KB name frame ${SECONDS}s — quadratic not bounded"; fail=1; fi

echo "── P. left-only line (no git/worktree/session) is width-bounded — a long left on a narrow terminal never overflows"
printf 'a fairly long recent-activity note that pads the left part well past a narrow terminal width\n' > "$FAKE_HOME/.claude/last-msg/sl-selftest"
JLEFT=$(jq -cn --arg cwd /private/tmp/not-a-git-repo --arg tp "$TP" '
  { workspace:{current_dir:$cwd}, model:{display_name:"Opus 4.8 (1M context)"}, effort:{level:"high"},
    context_window:{used_percentage:90}, session_id:"sl-selftest", transcript_path:$tp }')   # no project_dir/session_name, fake cwd → git empty → right part empty
pbad=0
for cols in 60 80 100 120; do
  o=$(run "$cols" "$JLEFT"); w=$(printf '%s' "$o" | vw); l=$(printf '%s' "$o" | grep -c '')
  [ "$l" -eq 1 ]                  || { echo "  ★ FAIL C=$cols not single line: $l"; pbad=1; }
  [ "$w" -le $((cols-EDGE_PAD)) ] || { echo "  ★ FAIL C=$cols left-only overflow: width=$w > $((cols-EDGE_PAD))"; pbad=1; }
done
[ "$pbad" -eq 0 ] && echo "  left-only 60..120: single line, never overflows COLUMNS-EDGE_PAD OK" || fail=1
printf '06-07 19:38\n' > "$FAKE_HOME/.claude/last-msg/sl-selftest"   # restore

echo "── Q. ROB-02: perl-absent truncation of a CJK name never emits invalid UTF-8 (no mid-char byte cut)"
# reuses the failing perl stub planted by test M at $WORK/bin/perl
JQCJK=$(jq -cn --arg cwd "$SL" --arg proj "$SL" --arg tp "$TP" '
  { workspace:{current_dir:$cwd, project_dir:$proj}, model:{display_name:"Opus"},
    session_name:"把狀態列整成一行測試把狀態列整成一行", session_id:"sl-selftest", transcript_path:$tp }')
qbad=0
for cols in 90 95 100 105 110 115; do
  o=$(printf '%s' "$JQCJK" | env PATH="$WORK/bin:$PATH" COLUMNS="$cols" HOME="$FAKE_HOME" bash "$SL/statusline-command.sh")
  printf '%s' "$o" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 || { echo "  ★ FAIL C=$cols invalid UTF-8 (mid-char cut)"; qbad=1; }
done
[ "$qbad" -eq 0 ] && echo "  perl-absent CJK trunc 90..115: always valid UTF-8 OK" || fail=1

echo "── R. trunc_head negative cap (COLUMNS 1-2): no perl 'Unrecognized switch' on stderr, still single line"
rbad=0
for cols in 1 2; do
  err=$(run "$cols" "$J" 2>&1 >/dev/null)
  [ -z "$err" ]                          || { echo "  ★ FAIL C=$cols stderr noise: [$err]"; rbad=1; }
  [ "$(run "$cols" "$J" | grep -c '')" -eq 1 ] || { echo "  ★ FAIL C=$cols not single line"; rbad=1; }
done
[ "$rbad" -eq 0 ] && echo "  COLUMNS 1-2: stderr clean, single line OK" || fail=1

echo "── S. rate-limit used_percentage>100 clamps 'remaining' to 0% (never a negative number)"
# cwd is a fixed-name, non-git directory, not "$SL": the glob below scans the whole line, and the path segment leads it, so
# a checkout named like a verifier's worktree ("wt-924c378") put a "-<digit>" ahead of the "%" and read as a negative number.
SDIR="$WORK/clamp"; mkdir -p "$SDIR"
JS=$(jq -cn --arg cwd "$SDIR" --arg proj "$SDIR" --arg tp "$TP" '
  { workspace:{current_dir:$cwd, project_dir:$proj}, model:{display_name:"Opus"},
    rate_limits:{five_hour:{used_percentage:120, resets_at:(now+100|floor)}},
    session_id:"sl-selftest", transcript_path:$tp }')
sout=$(run 200 "$JS" | sed 's/\x1b\[[0-9;]*m//g')
case "$sout" in *-[0-9]*%*) echo "  ★ FAIL negative remaining %: [$sout]"; fail=1 ;; *) echo "  no negative % OK" ;; esac

echo "── T. RATE-SYNC: per-CLASS (W5/W7) authority = the freshest observation — climb / cap-raise drop / anti-reversal / persistence / re-key / toggle / prune / legacy / roll-adoption / class-isolation / sanity-bound"
SLC="$FAKE_HOME/.claude/sl-ratelimit-cache"
nocol() { sed 's/\x1b\[[0-9;]*m//g'; }
# Fixture session ids MUST be UUID-shaped. lib/collect.sh's sid_persistable gate only lets a real Claude Code session id
# (8-4-4-4-12 lowercase hex) persist an observation into the shared cache; a readable label like "sessOld" takes the
# read-only degradation path instead, so every write scenario below would silently pass for the wrong reason. sidof()
# maps a label to a stable UUID-shaped id so the call sites keep their names; seeds and asserts call it for the same label.
sidof() {  # $1=fixture label → its stable UUID-shaped session id
  local h; h=$(printf 'sl-fixture-%s' "$1" | md5 -q)
  printf '%s-%s-%s-%s-%s' "${h:0:8}" "${h:8:4}" "${h:12:4}" "${h:16:4}" "${h:20:12}"
}
rsj() {  # $1=used% $2=resets_at $3=session_id → minimal five_hour-only json (ctx pinned 5% so the only other "%" token is the rate)
  jq -cn --arg cwd "$SL" --arg tp "$TP" --arg sid "$(sidof "${3:-sl-selftest}")" --argjson u "$1" --argjson r "$2" '
  { workspace:{current_dir:$cwd}, model:{display_name:"Opus"}, context_window:{used_percentage:5},
    rate_limits:{five_hour:{used_percentage:$u, resets_at:$r}}, session_id:$sid, transcript_path:$tp }'; }
# Scenarios pre-seed controlled observation epochs; the one legacy fixture also checks first_seen-based upgrade behavior.
NOW=$(jq -n 'now|floor'); RT=$((NOW + 9000))   # active window key (~2.5h to reset)
OLD=$((NOW - 5000)); RECENT=$((NOW - 100))     # an old vs a recent session's first_seen
# T1 climb: authority is an OLD session at 40; a NEW session (first_seen=now > OLD) reports higher 75 → adopt → remaining 25%
printf "S $(sidof sessOld) %s %s 40 %s - - -\nW5 %s 40 %s\n" "$OLD" "$RT" "$OLD" "$RT" "$OLD" > "$SLC"
t1=$(run 120 "$(rsj 75 "$RT" sessNew)" | nocol)
case "$t1" in *" 25%"*) echo "  T1 newer session raises (climb) → 25% OK" ;; *) echo "  ★ FAIL T1 expected 25% remaining: [$t1]"; fail=1 ;; esac
# T2 cap-raise (THE incident): authority OLD at 70; a NEW session reports LOWER 38 → adopt → remaining 62%, not the stale 30%
printf "S $(sidof sessOld) %s %s 70 %s - - -\nW5 %s 70 %s\n" "$OLD" "$RT" "$OLD" "$RT" "$OLD" > "$SLC"
t2=$(run 120 "$(rsj 38 "$RT" sessNew)" | nocol)
case "$t2" in *" 62%"*) echo "  T2 newer session lowers (cap raised) → 62%, not stale 30% OK" ;; *" 30%"*) echo "  ★ FAIL T2 stuck on stale high 70 (showed 30%): [$t2]"; fail=1 ;; *) echo "  ★ FAIL T2 expected 62%: [$t2]"; fail=1 ;; esac
# T3 older can't override + persistence: authority set by a RECENT session at 75; an OLD frozen-low session reports 40 → ignored → stays 25% (setter need not be rendering)
printf "S $(sidof sessRecent) %s %s 75 %s - - -\nS $(sidof sessOldFrozen) %s %s 40 %s - - -\nW5 %s 75 %s\n" "$RECENT" "$RT" "$RECENT" "$OLD" "$RT" "$OLD" "$RT" "$RECENT" > "$SLC"
t3=$(run 120 "$(rsj 40 "$RT" sessOldFrozen)" | nocol)
case "$t3" in *" 25%"*) echo "  T3 older session can't lower authority (no under-report) → 25% OK" ;; *" 60%"*) echo "  ★ FAIL T3 old frozen-low session overrode authority (showed 60%): [$t3]"; fail=1 ;; *) echo "  ★ FAIL T3 expected 25%: [$t3]"; fail=1 ;; esac
# T4 anti-reversal: after a newer session lowers 70→38, the OLD frozen-HIGH session rendering again must NOT bounce it back to 30%
printf "S $(sidof sessOld) %s %s 70 %s - - -\nW5 %s 70 %s\n" "$OLD" "$RT" "$OLD" "$RT" "$OLD" > "$SLC"
run 120 "$(rsj 38 "$RT" sessNew)" >/dev/null     # newer session lowers to 38 (becomes authority @ now)
t4=$(run 120 "$(rsj 70 "$RT" sessOld)" | nocol)  # the old session reports its stale 70 again
case "$t4" in *" 62%"*) echo "  T4 stale-high old session can't undo the cap-raise → still 62% OK" ;; *" 30%"*) echo "  ★ FAIL T4 reverted to stale 70 (showed 30%): [$t4]"; fail=1 ;; *) echo "  ★ FAIL T4 expected 62%: [$t4]"; fail=1 ;; esac
# T5 keying: a session reporting a NEWER window re-keys the class to its own report — it must NOT inherit the old window's value
printf "S $(sidof sessOld) %s %s 40 %s - - -\nW5 %s 40 %s\n" "$OLD" "$RT" "$OLD" "$RT" "$OLD" > "$SLC"
t5=$(run 120 "$(rsj 0 "$((NOW + 22000))" sessOther)" | nocol)
case "$t5" in *" 100%"*) echo "  T5 separate window not polluted → 100% OK" ;; *) echo "  ★ FAIL T5 window polluted: [$t5]"; fail=1 ;; esac
# T6 toggle: RL_SYNC=false must ignore the cache entirely → a frozen used=0 shows the raw 100% (cache still holds the RT authority)
printf "S $(sidof sessOld) %s %s 70 %s - - -\nW5 %s 70 %s\n" "$OLD" "$RT" "$OLD" "$RT" "$OLD" > "$SLC"
mkdir -p "$WORK/nosync/lib" && cp "$SL"/lib/*.sh "$WORK/nosync/lib/"
sed 's/^RL_SYNC=true/RL_SYNC=false/' "$SL/statusline-command.sh" > "$WORK/nosync/statusline-command.sh"
t6=$(printf '%s' "$(rsj 0 "$RT" sessOld)" | env COLUMNS=120 HOME="$FAKE_HOME" bash "$WORK/nosync/statusline-command.sh" | nocol)
case "$t6" in *" 100%"*) echo "  T6 RL_SYNC=false ignores cache (100%) OK" ;; *) echo "  ★ FAIL T6 false-path consulted cache: [$t6]"; fail=1 ;; esac
# T7 prune: a frame whose window already expired (resets_at<=now) must NOT be persisted as a W line
rm -f "$SLC"; RTpast=$((NOW - 100))
run 120 "$(rsj 90 "$RTpast" sessX)" >/dev/null
if grep -q "^W5 $RTpast " "$SLC" 2>/dev/null; then echo "  ★ FAIL T7 expired window persisted to cache"; fail=1; else echo "  T7 expired window pruned from cache OK"; fi
# T8 legacy: an old-format "<resets_at> <used>" line is ignored (dropped), not read as an authority
printf '%s 99\n' "$RT" > "$SLC"
t8=$(run 120 "$(rsj 10 "$RT" sessZ)" | nocol)
case "$t8" in *" 90%"*) echo "  T8 legacy 2-col line ignored → own 90% OK" ;; *" 1%"*) echo "  ★ FAIL T8 legacy line treated as authority (showed 1%): [$t8]"; fail=1 ;; *) echo "  ★ FAIL T8 expected 90%: [$t8]"; fail=1 ;; esac
# T9 (1.3) RL_REG_TTL clamp: an undersized OR non-numeric RL_REG_TTL must be raised to the 604800 floor, so a still-alive old session's
# registry (S) line is NOT pruned — pruning it makes that session re-rank as NEW next frame and seize authority with its frozen used%.
t9bad=0; OLDF=$((NOW-18000))   # first_seen 5h ago, still well within the 7d window
for ttl in 3600 abc; do
  mkdir -p "$WORK/ttl$ttl/lib" && cp "$SL"/lib/*.sh "$WORK/ttl$ttl/lib/"
  sed "s/^RL_REG_TTL=604800/RL_REG_TTL=$ttl/" "$SL/statusline-command.sh" > "$WORK/ttl$ttl/statusline-command.sh"
  printf "S $(sidof sOldLive) %s %s 70 %s - - -\nW5 %s 70 %s\n" "$OLDF" "$RT" "$OLDF" "$RT" "$OLDF" > "$SLC"
  printf '%s' "$(rsj 70 "$RT" sOldLive)" | env COLUMNS=120 HOME="$FAKE_HOME" bash "$WORK/ttl$ttl/statusline-command.sh" >/dev/null 2>&1
  grep -q "^S $(sidof sOldLive) " "$SLC" 2>/dev/null || { echo "  ★ FAIL T9 RL_REG_TTL=$ttl pruned a live session's registry (clamp missing)"; t9bad=1; }
done
[ "$t9bad" -eq 0 ] && echo "  T9 undersized/non-numeric RL_REG_TTL clamped to 604800 floor (live registry kept) OK" || fail=1
# T10 window-roll adoption (regression: frozen sessions went permanently stale after a roll — showed the pre-roll used% and a
# perpetual 0m countdown): a frame whose OWN resets_at expired must adopt the live per-class authority — value AND resets_at
# (countdown) — for both classes, and must sample the P series under the adopted (effective) live key.
rsj2() {  # $1=used5 $2=reset5 $3=used7 $4=reset7 $5=session_id → five_hour+seven_day json
  jq -cn --arg cwd "$SL" --arg tp "$TP" --arg sid "$(sidof "${5:-sl-selftest}")" --argjson u5 "$1" --argjson r5 "$2" --argjson u7 "$3" --argjson r7 "$4" '
  { workspace:{current_dir:$cwd}, model:{display_name:"Opus"}, context_window:{used_percentage:5},
    rate_limits:{five_hour:{used_percentage:$u5, resets_at:$r5}, seven_day:{used_percentage:$u7, resets_at:$r7}},
    session_id:$sid, transcript_path:$tp }'; }
RT7=$((NOW + 300000))
printf "S $(sidof sFrozen) %s %s 87 %s %s 79 %s\nS $(sidof sFresh) %s %s 3 %s %s 24 %s\nW5 %s 3 %s\nW7 %s 24 %s\n" \
  "$OLD" "$((NOW-2000))" "$OLD" "$((NOW-1000))" "$OLD" \
  "$RECENT" "$RT" "$RECENT" "$RT7" "$RECENT" "$RT" "$RECENT" "$RT7" "$RECENT" > "$SLC"
t10=$(run 200 "$(rsj2 87 $((NOW-2000)) 79 $((NOW-1000)) sFrozen)" | nocol)
t10bad=0
case "$t10" in *"2H"*" 97%"*) ;; *) echo "  ★ FAIL T10 5h did not adopt live authority value+countdown: [$t10]"; t10bad=1 ;; esac
case "$t10" in *" 76%"*) ;; *) echo "  ★ FAIL T10 7d did not adopt live authority: [$t10]"; t10bad=1 ;; esac
case "$t10" in *" 13%"*|*" 21%"*) echo "  ★ FAIL T10 frozen pre-roll used% leaked into the display: [$t10]"; t10bad=1 ;; esac
grep -q "^P $RT " "$SLC" 2>/dev/null || { echo "  ★ FAIL T10 frozen frame did not sample under the effective live key"; t10bad=1; }
[ "$t10bad" -eq 0 ] && echo "  T10 post-roll frame adopts live W5+W7 authority (value + countdown + effective-key sample) OK" || fail=1
# T11 class isolation: with only a live W7 authority, an expired 5h window must NOT cross-adopt it — the 5h segment keeps the
# frozen fallback (own value + 0m countdown, the documented no-authority residual), while 7d adopts its own class authority.
printf "S $(sidof sFrozen) %s %s 87 %s %s 79 %s\nS $(sidof sFresh) %s - - - %s 24 %s\nW7 %s 24 %s\n" \
  "$OLD" "$((NOW-2000))" "$OLD" "$((NOW-1000))" "$OLD" "$RECENT" "$RT7" "$RECENT" "$RT7" "$RECENT" > "$SLC"
t11=$(run 200 "$(rsj2 87 $((NOW-2000)) 79 $((NOW-1000)) sFrozen)" | nocol)
t11bad=0
case "$t11" in *"0m 13%"*) ;; *) echo "  ★ FAIL T11 expected frozen 5h fallback (0m 13%): [$t11]"; t11bad=1 ;; esac
case "$t11" in *" 76%"*) ;; *) echo "  ★ FAIL T11 7d did not adopt its class authority: [$t11]"; t11bad=1 ;; esac
if grep -q "^W5 " "$SLC" 2>/dev/null; then echo "  ★ FAIL T11 an expired 5h report was persisted as authority"; t11bad=1; fi
[ "$t11bad" -eq 0 ] && echo "  T11 class isolation: 5h keeps frozen fallback, 7d adopts W7 OK" || fail=1
# T12 window-key sanity bound: an absurd far-future key (>= now+691200, 8d) must be refused on load AND on report — it can never
# become an immortal authority (the real user cache carried a W 9999999999 line for over a month before this guard).
printf "S $(sidof sFroz) %s %s 10 %s - - -\nW5 9999999999 28 %s\n" "$OLD" "$RT" "$OLD" "$RECENT" > "$SLC"
t12=$(run 200 "$(rsj 10 "$RT" sFroz)" | nocol)
t12bad=0
case "$t12" in *" 90%"*) ;; *) echo "  ★ FAIL T12 absurd stored key won authority (expected own 90%): [$t12]"; t12bad=1 ;; esac
if grep -q "^W[57] 9999999999 " "$SLC" 2>/dev/null; then echo "  ★ FAIL T12 absurd authority key survived the rewrite"; t12bad=1; fi
run 200 "$(rsj 10 9999999999 sAbsRep)" >/dev/null
if grep -q "^W[57] 9999999999 " "$SLC" 2>/dev/null; then echo "  ★ FAIL T12 absurd reported key became authority"; t12bad=1; fi
[ "$t12bad" -eq 0 ] && echo "  T12 far-future keys refused on load and report (no immortal authority) OK" || fail=1
# T13 legacy/malformed migration: the one retained 3-field S fixture upgrades in place, valid 9-field S survives,
# wrong-arity S and untagged W are dropped, and the legacy session seeds W5 because no valid authority exists.
printf "S $(sidof sOld2) %s\nS sNine %s %s 20 %s - - -\nS sBroken %s %s 20\nW %s 40 %s\n" \
  "$OLD" "$RECENT" "$RT" "$RECENT" "$OLD" "$RT" "$RT" "$RECENT" > "$SLC"
t13=$(run 200 "$(rsj 75 "$RT" sOld2)" | nocol)
t13bad=0
case "$t13" in *" 25%"*) ;; *"60%"*) echo "  ★ FAIL T13 legacy W line adopted as authority (showed 60%): [$t13]"; t13bad=1 ;; *) echo "  ★ FAIL T13 expected 25%: [$t13]"; t13bad=1 ;; esac
if grep -q "^W $RT " "$SLC" 2>/dev/null; then echo "  ★ FAIL T13 legacy W line carried forward"; t13bad=1; fi
grep -q "^W5 $RT 75 " "$SLC" 2>/dev/null || { echo "  ★ FAIL T13 own report did not seed the class authority"; t13bad=1; }
awk -v r="$RT" -v fs="$OLD" -v sid="$(sidof sOld2)" '$1=="S"&&NF==11&&$2==sid&&$3==fs&&$4==r&&$5==75&&$6==fs&&$7=="-"&&$8=="-"&&$9=="-"&&$10=="-"&&$11~/^[0-9]+$/{ok=1} END{exit !ok}' "$SLC" || { echo "  ★ FAIL T13 legacy S row was not upgraded to 11 fields with first_seen observation"; t13bad=1; }
grep -q "^S sNine $RECENT $RT 20 $RECENT - - - - $RECENT$" "$SLC" || { echo "  ★ FAIL T13 valid 9-field S row did not survive"; t13bad=1; }
grep -q '^S sBroken ' "$SLC" && { echo "  ★ FAIL T13 wrong-arity S row survived"; t13bad=1; }
[ "$t13bad" -eq 0 ] && echo "  T13 legacy S upgraded; valid 9-field S kept; malformed S and untagged W dropped OK" || fail=1

# T14 older active session overrides an idle newer session when its reported pair changes.
printf "S $(sidof sActive) %s %s 40 %s %s 24 %s\nS $(sidof sIdle) %s %s 70 %s %s 24 %s\nW5 %s 70 %s\nW7 %s 24 %s\n" \
  "$OLD" "$RT" "$OLD" "$RT7" "$OLD" "$RECENT" "$RT" "$RECENT" "$RT7" "$RECENT" "$RT" "$RECENT" "$RT7" "$RECENT" > "$SLC"
t14=$(run 200 "$(rsj2 75 "$RT" 24 "$RT7" sActive)" | nocol); t14bad=0
case "$t14" in *" 25%"*) ;; *) echo "  ★ FAIL T14 older active session did not replace idle authority: [$t14]"; t14bad=1 ;; esac
if ! awk -v r="$RT" -v min="$RECENT" '$1=="W5"&&NF==4&&$2==r&&$3==75&&$4>min{ok=1} END{exit !ok}' "$SLC"; then echo "  ★ FAIL T14 W5 did not persist the changed pair with fresh observed_at"; t14bad=1; fi
if ! awk -v r="$RT" -v min="$RECENT" -v sid="$(sidof sActive)" '$1=="S"&&NF==11&&$10=="-"&&$11~/^[0-9]+$/&&$2==sid&&$4==r&&$5==75&&$6>min{ok=1} END{exit !ok}' "$SLC"; then echo "  ★ FAIL T14 active S row did not record the changed pair"; t14bad=1; fi
[ "$t14bad" -eq 0 ] && echo "  T14 older active session overrides idle newer session with freshest observation OK" || fail=1

# T17 follows T14: the idle session reports its unchanged stale pair and must not take authority back.
wbefore=$(grep "^W5 $RT " "$SLC")
t17=$(run 200 "$(rsj2 70 "$RT" 24 "$RT7" sIdle)" | nocol); t17bad=0
case "$t17" in *" 25%"*) ;; *) echo "  ★ FAIL T17 idle unchanged session re-took authority: [$t17]"; t17bad=1 ;; esac
wafter=$(grep "^W5 $RT " "$SLC")
[ "$wbefore" = "$wafter" ] || { echo "  ★ FAIL T17 W5 changed: before=[$wbefore] after=[$wafter]"; t17bad=1; }
awk -v r="$RT" -v o="$RECENT" -v sid="$(sidof sIdle)" '$1=="S"&&NF==11&&$10=="-"&&$11~/^[0-9]+$/&&$2==sid&&$4==r&&$5==70&&$6==o{ok=1} END{exit !ok}' "$SLC" || { echo "  ★ FAIL T17 idle S row refreshed its carried observation"; t17bad=1; }
[ "$t17bad" -eq 0 ] && echo "  T17 idle unchanged session cannot re-take authority OK" || fail=1

# T15 a cap increase can lower used%; the changed lower pair is still the freshest observation.
printf "S $(sidof sActive) %s %s 70 %s - - -\nS $(sidof sIdle) %s %s 70 %s - - -\nW5 %s 70 %s\n" \
  "$OLD" "$RT" "$OLD" "$RECENT" "$RT" "$RECENT" "$RT" "$RECENT" > "$SLC"
t15=$(run 200 "$(rsj 38 "$RT" sActive)" | nocol); t15bad=0
case "$t15" in *" 62%"*) ;; *) echo "  ★ FAIL T15 cap-raise drop was not adopted: [$t15]"; t15bad=1 ;; esac
awk -v r="$RT" -v min="$RECENT" '$1=="W5"&&NF==4&&$2==r&&$3==38&&$4>min{ok=1} END{exit !ok}' "$SLC" || { echo "  ★ FAIL T15 lower W5 value/observation not persisted"; t15bad=1; }
awk -v r="$RT" -v min="$RECENT" -v sid="$(sidof sActive)" '$1=="S"&&NF==11&&$10=="-"&&$11~/^[0-9]+$/&&$2==sid&&$4==r&&$5==38&&$6>min{ok=1} END{exit !ok}' "$SLC" || { echo "  ★ FAIL T15 active S row did not record the lowered pair"; t15bad=1; }
[ "$t15bad" -eq 0 ] && echo "  T15 cap-raise drop adopted by freshest observation OK" || fail=1

# T16 a changed reset key is a fresh observation and re-keys the whole class without retaining the old W5.
RTOLD=$((NOW+120)); RTNEW=$((NOW+9000))
printf "S $(sidof sActive) %s %s 87 %s - - -\nS $(sidof sIdle) %s %s 87 %s - - -\nW5 %s 87 %s\n" \
  "$OLD" "$RTOLD" "$OLD" "$RECENT" "$RTOLD" "$RECENT" "$RTOLD" "$RECENT" > "$SLC"
t16=$(run 200 "$(rsj 3 "$RTNEW" sActive)" | nocol); t16bad=0
case "$t16" in *" 97%"*) ;; *) echo "  ★ FAIL T16 rolled window was not adopted: [$t16]"; t16bad=1 ;; esac
awk -v r="$RTNEW" -v min="$RECENT" '$1=="W5"&&NF==4&&$2==r&&$3==3&&$4>min{n++} END{exit !(n==1)}' "$SLC" || { echo "  ★ FAIL T16 new W5 key/value/observation not persisted exactly once"; t16bad=1; }
awk -v r="$RTNEW" -v min="$RECENT" -v sid="$(sidof sActive)" '$1=="S"&&NF==11&&$10=="-"&&$11~/^[0-9]+$/&&$2==sid&&$4==r&&$5==3&&$6>min{ok=1} END{exit !ok}' "$SLC" || { echo "  ★ FAIL T16 active S row did not record the rolled pair"; t16bad=1; }
grep -q "^W5 $RTOLD " "$SLC" && { echo "  ★ FAIL T16 old W5 key survived window re-key"; t16bad=1; }
[ "$t16bad" -eq 0 ] && echo "  T16 window roll adopts new key and drops old class record OK" || fail=1

# T18 family (2026-09-28 incident): an idle session on an older Claude Code build re-sends its last reading as the unrounded
# product utilization*100 (e.g. 56.00000000000001). The cache stores it through awk's six-digit conversion as 56, so a pair test
# on the raw numbers saw a change on every frame and handed the idle session the class authority once a minute. Every other case
# in this section uses integer literals, which is why T17 passed while the field failed.
# ccpct() prints what each known build sends, computed in IEEE-754 doubles by jq (byte-identical to Node for these formulas):
# old = utilization*100 unrounded, new = Math.round(utilization*1000)/10. Session ids go through sidof: a non-UUID id takes the
# read-only path of the writer gate and every case below would pass vacuously on the unfixed tree.
ccpct() {  # $1=utilization $2=old|new → the used_percentage literal that build sends
  case "$2" in
    old) jq -n --argjson u "$1" '$u*100' ;;
    new) jq -n --argjson u "$1" '($u*1000|round)/10' ;;
  esac
}
rsj7() {  # $1=used7% literal $2=resets_at $3=session label → seven_day-only json (sid via sidof)
  jq -cn --arg cwd "$SL" --arg tp "$TP" --arg sid "$(sidof "$3")" --argjson u "$1" --argjson r "$2" '
  { workspace:{current_dir:$cwd}, model:{display_name:"Opus"}, context_window:{used_percentage:5},
    rate_limits:{seven_day:{used_percentage:$u, resets_at:$r}}, session_id:$sid, transcript_path:$tp }'; }
# Helper self-check: the literal table of the spec requirement "Pair-change test compares used% rounded to one decimal place".
t18hbad=0
while read -r hu hold hnew; do
  [ "$(ccpct "$hu" old)" = "$hold" ] || { echo "  ★ FAIL T18 helper: $hu old gave [$(ccpct "$hu" old)], want [$hold]"; t18hbad=1; }
  [ "$(ccpct "$hu" new)" = "$hnew" ] || { echo "  ★ FAIL T18 helper: $hu new gave [$(ccpct "$hu" new)], want [$hnew]"; t18hbad=1; }
done <<'CCPCT'
0.07 7.000000000000001 7
0.29 28.999999999999996 29
0.56 56.00000000000001 56
0.58 57.99999999999999 58
0.5612345 56.12345 56.1
0.5831 58.309999999999995 58.3
CCPCT
[ "$t18hbad" -eq 0 ] && echo "  T18 fixture helper reproduces both Claude Code formulas (spec table) OK" || fail=1
T18FS=$((NOW - 2000)); T18O=$((NOW - 1500))   # idle session: first seen long ago, last observed before the newer W record

# T18 the incident: a newer session holds W7 at 73; the idle session whose row records 56 renders twice with the 0.56 old literal.
t18lit=$(ccpct 0.56 old); t18bad=0; t18sid=$(sidof sIdle18)
printf "S %s %s - - - %s 73 %s\nS %s %s - - - %s 56 %s\nW7 %s 73 %s\n" \
  "$(sidof sNewer18)" "$RECENT" "$RT7" "$RECENT" "$t18sid" "$T18FS" "$RT7" "$T18O" "$RT7" "$RECENT" > "$SLC"
t18w=$(grep '^W7 ' "$SLC"); t18j=$(rsj7 "$t18lit" "$RT7" sIdle18)
case "$t18j" in *"\"used_percentage\":$t18lit,"*) ;; *) echo "  ★ FAIL T18 fixture lost the unrounded literal [$t18lit]: [$t18j]"; t18bad=1 ;; esac
for t18n in 1 2; do
  t18=$(run 200 "$t18j" | nocol)
  case "$t18" in *" 27%"*) ;; *) echo "  ★ FAIL T18 frame $t18n: idle session repeating $t18lit took the 7d authority (expected 27% left): [$t18]"; t18bad=1 ;; esac
  [ "$(grep '^W7 ' "$SLC")" = "$t18w" ] || { echo "  ★ FAIL T18 frame $t18n: W7 changed: before=[$t18w] after=[$(grep '^W7 ' "$SLC")]"; t18bad=1; }
  awk -v sid="$t18sid" -v r="$RT7" -v o="$T18O" '$1=="S"&&NF==11&&$10=="-"&&$11~/^[0-9]+$/&&$2==sid&&$7==r&&$8==56&&$9==o{ok=1} END{exit !ok}' "$SLC" || { echo "  ★ FAIL T18 frame $t18n: idle row o7 moved: [$(grep "^S $t18sid " "$SLC")]"; t18bad=1; }
done
[ "$t18bad" -eq 0 ] && echo "  T18 idle session repeating an unrounded 7d literal ($t18lit) cannot re-take the authority OK" || fail=1

# T18b the five-hour twin: a newer session holds W5 at 20; the idle session whose row records 7 renders with the 0.07 old literal.
t18blit=$(ccpct 0.07 old); t18bbad=0; t18bsid=$(sidof sIdle18b)
printf "S %s %s %s 20 %s - - -\nS %s %s %s 7 %s - - -\nW5 %s 20 %s\n" \
  "$(sidof sNewer18b)" "$RECENT" "$RT" "$RECENT" "$t18bsid" "$T18FS" "$RT" "$T18O" "$RT" "$RECENT" > "$SLC"
t18bw=$(grep '^W5 ' "$SLC")
t18b=$(run 200 "$(rsj "$t18blit" "$RT" sIdle18b)" | nocol)
case "$t18b" in *" 80%"*) ;; *) echo "  ★ FAIL T18b idle session repeating $t18blit took the 5h authority (expected 80% left): [$t18b]"; t18bbad=1 ;; esac
[ "$(grep '^W5 ' "$SLC")" = "$t18bw" ] || { echo "  ★ FAIL T18b W5 changed: before=[$t18bw] after=[$(grep '^W5 ' "$SLC")]"; t18bbad=1; }
awk -v sid="$t18bsid" -v r="$RT" -v o="$T18O" '$1=="S"&&NF==11&&$10=="-"&&$11~/^[0-9]+$/&&$2==sid&&$4==r&&$5==7&&$6==o{ok=1} END{exit !ok}' "$SLC" || { echo "  ★ FAIL T18b idle row o5 moved: [$(grep "^S $t18bsid " "$SLC")]"; t18bbad=1; }
[ "$t18bbad" -eq 0 ] && echo "  T18b idle session repeating an unrounded 5h literal ($t18blit) cannot re-take the authority OK" || fail=1

# T18c formula sweep: p = 0..100, utilization p/100, both formulas, both classes in one frame. The idle row starts with no
# recorded pair; the first frame records it, and the repeat must move neither the observation times nor either class record.
# No value is pre-selected, so the sweep encodes no assumption about which literals carry float noise.
t18cbad=0; t18cn=0; t18csid=$(sidof sSweep18)
t18csnap() { awk -v sid="$t18csid" '$1=="S"&&$2==sid{s=s $4" "$6" "$7" "$9} $1=="W5"||$1=="W7"{s=s" | "$0} END{print s}' "$SLC"; }   # one line: "r5 o5 r7 o7 | W5 ... | W7 ..."
for t18cp in $(seq 0 100); do
  t18cu=$(jq -n --argjson p "$t18cp" '$p/100')
  for t18cf in old new; do
    t18clit=$(ccpct "$t18cu" "$t18cf"); t18cn=$((t18cn + 1))
    printf "S %s %s - - - - - -\nW5 %s 50 %s\nW7 %s 50 %s\n" "$t18csid" "$OLD" "$RT" "$RECENT" "$RT7" "$RECENT" > "$SLC"
    t18cj=$(rsj2 "$t18clit" "$RT" "$t18clit" "$RT7" sSweep18)
    run 200 "$t18cj" >/dev/null; t18c1=$(t18csnap)
    run 200 "$t18cj" >/dev/null; t18c2=$(t18csnap)
    case "$t18c1" in "$RT $OLD $RT7 $OLD |"*) ;; *) echo "  ★ FAIL T18c p=$t18cp $t18cf literal=$t18clit: first frame did not record the pair: [$t18c1]"; t18cbad=1; continue ;; esac
    [ "$t18c1" = "$t18c2" ] || { echo "  ★ FAIL T18c p=$t18cp $t18cf literal=$t18clit: repeat moved an observation time or class record: [$t18c1] -> [$t18c2]"; t18cbad=1; }
  done
done
[ "$t18cbad" -eq 0 ] && echo "  T18c formula sweep: $t18cn cases (p=0..100 x old/new, both classes), no repeat re-stamps a session OK" || fail=1

# T18d a row written before rounding existed (56.1234) re-reported as 56.12345: the same tenth, so the observation is carried over
# and the row is rewritten as 56.1. Rounding only the incoming value would compare 56.1 with 56.1234 and re-stamp it once at upgrade.
t18dbad=0; t18dsid=$(sidof sB18d)
printf "S %s %s - - - %s 56.1234 %s\nW7 %s 73 %s\n" "$t18dsid" "$T18FS" "$RT7" "$T18O" "$RT7" "$RECENT" > "$SLC"
t18dw=$(grep '^W7 ' "$SLC")
run 200 "$(rsj7 56.12345 "$RT7" sB18d)" >/dev/null
[ "$(grep '^W7 ' "$SLC")" = "$t18dw" ] || { echo "  ★ FAIL T18d W7 changed: before=[$t18dw] after=[$(grep '^W7 ' "$SLC")]"; t18dbad=1; }
grep -q "^S $t18dsid $T18FS - - - $RT7 56\\.1 $T18O - [0-9][0-9]*\$" "$SLC" || { echo "  ★ FAIL T18d pre-rounding row was not carried over as 56.1: [$(grep "^S $t18dsid " "$SLC")]"; t18dbad=1; }
[ "$t18dbad" -eq 0 ] && echo "  T18d pre-rounding row (56.1234) re-reported as 56.12345 keeps its o7 and is rewritten as 56.1 OK" || fail=1

# T18e positive control: a genuine change of one tenth (56 -> 56.1) is a fresh observation, stamped now and adopted.
# It holds before and after the fix; rounding coarser than one decimal would hide the change and turn it red.
t18ebad=0; t18esid=$(sidof sA18e)
printf "S %s %s - - - %s 56 %s\nW7 %s 56 %s\n" "$t18esid" "$T18FS" "$RT7" "$T18O" "$RT7" "$T18O" > "$SLC"
t18et=$(date +%s)
run 200 "$(rsj7 56.1 "$RT7" sA18e)" >/dev/null
awk -v sid="$t18esid" -v r="$RT7" -v t="$t18et" '$1=="S"&&NF==11&&$10=="-"&&$11~/^[0-9]+$/&&$2==sid&&$7==r&&$8=="56.1"&&$9>=t{ok=1} END{exit !ok}' "$SLC" || { echo "  ★ FAIL T18e a 0.1 change was not stamped now: [$(grep "^S $t18esid " "$SLC")]"; t18ebad=1; }
awk -v r="$RT7" -v t="$t18et" '$1=="W7"&&NF==4&&$2==r&&$3=="56.1"&&$4>=t{ok=1} END{exit !ok}' "$SLC" || { echo "  ★ FAIL T18e W7 did not adopt 56.1 at now: [$(grep '^W7 ' "$SLC")]"; t18ebad=1; }
[ "$t18ebad" -eq 0 ] && echo "  T18e a 0.1 change (56 -> 56.1) is stamped now and adopted as W7 56.1 OK" || fail=1
rm -f "$SLC"

# T19-T22 (rate-sync-freshness-from-api-counter): the observation time comes from Claude Code's API-activity counter,
# cost.total_api_duration_ms, which moves only when a model response completed after its rate-limit headers were applied.
# A counter that did not advance means no new data, whatever the reported number does; a report with no recorded counter
# gets observation time 0 (freshness unknown). Assertions marked "(format)" pin the eleven-field row
# `S <sid> <first_seen> <r5> <u5> <o5> <r7> <u7> <o7> <api_ms> <last_seen>`; every other assertion is behavioural (the displayed
# remaining %, the W5/W7 record, a P sample, a sighting file), so a red run on the pre-change tree can be read by reason.
# Most cases seed the previous nine-field row, which both trees read, and let one frame of the code under test record the
# counter baseline before the frame that is judged; that keeps the behavioural verdict free of the format difference.
# rsjc: statusline JSON with any combination of five_hour / seven_day and a VERBATIM cost.total_api_duration_ms literal.
rsjc() {  # $1=used5 $2=reset5 $3=used7 $4=reset7 ("-" omits the class) $5=counter JSON literal or "absent" $6=label (via sidof) or raw:<sid>
  local sid
  case "$6" in raw:*) sid=${6#raw:} ;; *) sid=$(sidof "$6") ;; esac
  jq -cn --arg cwd "$SL" --arg tp "$TP" --arg sid "$sid" --arg u5 "$1" --arg r5 "$2" --arg u7 "$3" --arg r7 "$4" --arg c "$5" '
    ( (if $u5 == "-" then {} else {five_hour:{used_percentage:($u5|fromjson), resets_at:($r5|fromjson)}} end)
    + (if $u7 == "-" then {} else {seven_day:{used_percentage:($u7|fromjson), resets_at:($r7|fromjson)}} end) ) as $rl
    | { workspace:{current_dir:$cwd}, model:{display_name:"Opus"}, context_window:{used_percentage:5},
        session_id:$sid, transcript_path:$tp }
    + (if $rl == {} then {} else {rate_limits:$rl} end)
    + (if $c == "absent" then {} else {cost:{total_api_duration_ms:($c|fromjson)}} end)'
}
srow() { awk -v sid="$(sidof "$1")" '$1=="S"&&$2==sid' "$SLC"; }   # $1=label → that session's registry row as stored
SEEN="$SLC.seen"; T19LOCK="$SLC.lock"
t19wait() { while [ "$(date +%s)" -le "$1" ]; do sleep 0.2; done; }  # $1=epoch second → return once the clock has passed it
# Helper self-check: each counter literal reaches the script byte-for-byte, and "absent" sends no cost object.
t19hbad=0
for t19hl in 43500 0 null 12.5 '"abc"' absent; do
  t19hw="{\"total_api_duration_ms\":$t19hl}"; [ "$t19hl" = absent ] && t19hw=null
  t19hg=$(rsjc 10 "$RT" 56.00000000000001 "$RT7" "$t19hl" sHelp19 | jq -c .cost)
  [ "$t19hg" = "$t19hw" ] || { echo "  ★ FAIL T19 helper: counter literal [$t19hl] reached the script as [$t19hg], want [$t19hw]"; t19hbad=1; }
done
case "$(rsjc 10 "$RT" 56.00000000000001 "$RT7" 0 sHelp19)" in *'"used_percentage":56.00000000000001,'*) ;;
  *) echo "  ★ FAIL T19 helper lost the unrounded used% literal"; t19hbad=1 ;; esac
[ "$(rsjc - - - - absent sHelp19 | jq -c '.rate_limits')" = null ] || { echo "  ★ FAIL T19 helper: omitting both classes still sent rate_limits"; t19hbad=1; }
[ "$t19hbad" -eq 0 ] && echo "  T19 fixture helper passes every counter literal (digits, 0, null, 12.5, string, absent) through verbatim OK" || fail=1

# T19a an advanced counter stamps the report now even when the value is unchanged (spec: a busy session confirms 74).
t19abad=0; tn=$(date +%s); t19afs=$((tn-5000))
printf "S %s %s - - - %s 74 %s\nW7 %s 74 %s\n" "$(sidof sAct19a)" "$t19afs" "$RT7" $((tn-3000)) "$RT7" $((tn-100)) > "$SLC"
t19aw=$(grep '^W7 ' "$SLC")
run 200 "$(rsjc - - 74 "$RT7" 42000 sAct19a)" >/dev/null        # records the counter baseline; nothing new, nothing re-stamped
[ "$(grep '^W7 ' "$SLC")" = "$t19aw" ] || { echo "  ★ FAIL T19a the baseline frame re-stamped W7: [$(grep '^W7 ' "$SLC")]"; t19abad=1; }
t19a=$(run 200 "$(rsjc - - 74 "$RT7" 43500 sAct19a)" | nocol)     # a response arrived: the counter advanced, the value did not change
case "$t19a" in *" 26%"*) ;; *) echo "  ★ FAIL T19a expected 26% remaining: [$t19a]"; t19abad=1 ;; esac
awk -v r="$RT7" -v t="$tn" '$1=="W7"&&NF==4&&$2==r&&$3==74&&$4>=t{ok=1} END{exit !ok}' "$SLC" || { echo "  ★ FAIL T19a an advanced counter did not re-stamp W7 (same value, new data): [$(grep '^W7 ' "$SLC")]"; t19abad=1; }
srow sAct19a | awk -v fs="$t19afs" -v r="$RT7" -v t="$tn" 'NF==11&&$3==fs&&$4=="-"&&$5=="-"&&$6=="-"&&$7==r&&$8==74&&$9>=t&&$10=="43500"&&$11>=t{ok=1} END{exit !ok}' || { echo "  ★ FAIL T19a (format) row: [$(srow sAct19a)]"; t19abad=1; }
[ "$t19abad" -eq 0 ] && echo "  T19a an advanced counter re-stamps an unchanged 74 as a fresh observation OK" || fail=1

# T19b an idle session with an unchanged counter keeps its observation time, in any float formatting (guards E1).
t19bbad=0; tn=$(date +%s); t19bo=$((tn-3000))
printf "S %s %s - - - %s 56 %s\nW7 %s 73 %s\n" "$(sidof sIdle19b)" $((tn-5000)) "$RT7" "$t19bo" "$RT7" $((tn-100)) > "$SLC"
t19bw=$(grep '^W7 ' "$SLC")
for t19bn in 1 2 3; do                                             # frame 1 records the baseline; frames 2 and 3 repeat it
  t19bt=$(date +%s)
  t19b=$(run 200 "$(rsjc - - 56.00000000000001 "$RT7" 42000 sIdle19b)" | nocol)
  case "$t19b" in *" 27%"*) ;; *) echo "  ★ FAIL T19b frame $t19bn: idle session took the 7d authority (expected 27% left): [$t19b]"; t19bbad=1 ;; esac
  [ "$(grep '^W7 ' "$SLC")" = "$t19bw" ] || { echo "  ★ FAIL T19b frame $t19bn: W7 changed: [$(grep '^W7 ' "$SLC")]"; t19bbad=1; }
  srow sIdle19b | awk -v o="$t19bo" '$9==o{ok=1} END{exit !ok}' || { echo "  ★ FAIL T19b frame $t19bn: o7 moved: [$(srow sIdle19b)]"; t19bbad=1; }
  srow sIdle19b | awk -v r="$RT7" -v o="$t19bo" -v t="$t19bt" 'NF==11&&$7==r&&$8==56&&$9==o&&$10=="42000"&&$11>=t{ok=1} END{exit !ok}' || { echo "  ★ FAIL T19b frame $t19bn (format) row: [$(srow sIdle19b)]"; t19bbad=1; }
done
[ "$t19bbad" -eq 0 ] && echo "  T19b idle session repeating 56.00000000000001 with an unchanged counter keeps o7 and shows 27% OK" || fail=1

# T19c a changed pair without a counter advance does not refresh the observation (spec: a quota probe changed the reading).
t19cbad=0; tn=$(date +%s); t19cfs=$((tn-5000)); t19co=$((tn-3000))
printf "S %s %s - - - %s 70 %s\nW7 %s 73 %s\n" "$(sidof sProbe19c)" "$t19cfs" "$RT7" "$t19co" "$RT7" $((tn-100)) > "$SLC"
t19cw=$(grep '^W7 ' "$SLC")
run 200 "$(rsjc - - 70 "$RT7" 42000 sProbe19c)" >/dev/null        # baseline
t19c=$(run 200 "$(rsjc - - 75 "$RT7" 42000 sProbe19c)" | nocol)   # the value moved, the counter did not
case "$t19c" in *" 27%"*) ;; *) echo "  ★ FAIL T19c a changed pair without a counter advance took the authority (expected 27% left): [$t19c]"; t19cbad=1 ;; esac
[ "$(grep '^W7 ' "$SLC")" = "$t19cw" ] || { echo "  ★ FAIL T19c W7 changed: before=[$t19cw] after=[$(grep '^W7 ' "$SLC")]"; t19cbad=1; }
srow sProbe19c | awk -v o="$t19co" '$8==75&&$9==o{ok=1} END{exit !ok}' || { echo "  ★ FAIL T19c the new pair was not recorded with the carried o7: [$(srow sProbe19c)]"; t19cbad=1; }
srow sProbe19c | awk -v fs="$t19cfs" -v r="$RT7" -v o="$t19co" -v t="$tn" 'NF==11&&$3==fs&&$7==r&&$8==75&&$9==o&&$10=="42000"&&$11>=t{ok=1} END{exit !ok}' || { echo "  ★ FAIL T19c (format) row: [$(srow sProbe19c)]"; t19cbad=1; }
[ "$t19cbad" -eq 0 ] && echo "  T19c a changed pair without a counter advance keeps its o7 and leaves W7 alone OK" || fail=1

# T19d (E-clear) a new session id carrying an older reading cannot take the authority; its first advanced frame is fresh.
t19dbad=0; tn=$(date +%s)
printf "W7 %s 73 %s\n" "$RT7" $((tn-100)) > "$SLC"
t19dw=$(grep '^W7 ' "$SLC")
t19d=$(run 200 "$(rsjc - - 56 "$RT7" 0 sNew19d)" | nocol)          # /clear in an idle process: new id, counter 0, hours-old 56
case "$t19d" in *" 27%"*) ;; *) echo "  ★ FAIL T19d (E-clear) a new id with counter 0 took the authority with its old 56 (expected 27% left): [$t19d]"; t19dbad=1 ;; esac
[ "$(grep '^W7 ' "$SLC")" = "$t19dw" ] || { echo "  ★ FAIL T19d (E-clear) W7 changed: [$(grep '^W7 ' "$SLC")]"; t19dbad=1; }
t19dfs=$(srow sNew19d | awk '{print $3}')
srow sNew19d | awk -v r="$RT7" -v t="$tn" 'NF==11&&$3>=t&&$4=="-"&&$7==r&&$8==56&&$9=="0"&&$10=="0"&&$11>=t{ok=1} END{exit !ok}' || { echo "  ★ FAIL T19d (format) first row: [$(srow sNew19d)]"; t19dbad=1; }
t19dt=$(date +%s)
t19d2=$(run 200 "$(rsjc - - 75 "$RT7" 1800 sNew19d)" | nocol)      # the first reply: counter 0 -> 1800
case "$t19d2" in *" 25%"*) ;; *) echo "  ★ FAIL T19d the first advanced frame was not adopted (expected 25% left): [$t19d2]"; t19dbad=1 ;; esac
awk -v r="$RT7" -v t="$t19dt" '$1=="W7"&&NF==4&&$2==r&&$3==75&&$4>=t{ok=1} END{exit !ok}' "$SLC" || { echo "  ★ FAIL T19d W7 did not take 75 at now: [$(grep '^W7 ' "$SLC")]"; t19dbad=1; }
srow sNew19d | awk -v fs="$t19dfs" -v r="$RT7" -v t="$t19dt" 'NF==11&&$3==fs&&$7==r&&$8==75&&$9>=t&&$10=="1800"&&$11>=t{ok=1} END{exit !ok}' || { echo "  ★ FAIL T19d (format) second row: [$(srow sNew19d)]"; t19dbad=1; }
[ "$t19dbad" -eq 0 ] && echo "  T19d (E-clear) a new id with counter 0 cannot take W7; its first advanced frame is adopted OK" || fail=1

# T19e (E-first) a session registered at startup, before its first reply, is fresh on its first real report.
t19ebad=0; tn=$(date +%s); t19efs=$((tn-5000))
printf "S %s %s - - - - - -\nW7 %s 70 %s\n" "$(sidof sStart19e)" "$t19efs" "$RT7" $((tn-100)) > "$SLC"
run 200 "$(rsjc - - - - 0 sStart19e)" >/dev/null                  # startup frame: no rate_limits yet, counter 0
srow sStart19e | awk -v fs="$t19efs" -v t="$tn" 'NF==11&&$3==fs&&$4=="-"&&$7=="-"&&$10=="0"&&$11>=t{ok=1} END{exit !ok}' || { echo "  ★ FAIL T19e (format) startup row: [$(srow sStart19e)]"; t19ebad=1; }
t19e=$(run 200 "$(rsjc - - 73 "$RT7" 5200 sStart19e)" | nocol)     # first reply: first real report, counter advanced
case "$t19e" in *" 27%"*) ;; *) echo "  ★ FAIL T19e (E-first) the first real report lost to an older record (expected 27% left): [$t19e]"; t19ebad=1 ;; esac
awk -v r="$RT7" -v t="$tn" '$1=="W7"&&NF==4&&$2==r&&$3==73&&$4>=t{ok=1} END{exit !ok}' "$SLC" || { echo "  ★ FAIL T19e (E-first) W7 did not take 73 at now: [$(grep '^W7 ' "$SLC")]"; t19ebad=1; }
srow sStart19e | awk -v fs="$t19efs" -v r="$RT7" -v t="$tn" 'NF==11&&$3==fs&&$7==r&&$8==73&&$9>=t&&$10=="5200"&&$11>=t{ok=1} END{exit !ok}' || { echo "  ★ FAIL T19e (format) row: [$(srow sStart19e)]"; t19ebad=1; }
[ "$t19ebad" -eq 0 ] && echo "  T19e (E-first) the first report after the first reply is stamped now, not first_seen OK" || fail=1

# T19f a smaller counter (a resumed session) becomes the new baseline, and the next increase is fresh.
t19fbad=0; tn=$(date +%s); t19fo=$((tn-100))
printf "S %s %s - - - %s 73 %s\nW7 %s 73 %s\n" "$(sidof sRes19f)" $((tn-5000)) "$RT7" "$t19fo" "$RT7" "$t19fo" > "$SLC"
t19fw=$(grep '^W7 ' "$SLC")
run 200 "$(rsjc - - 73 "$RT7" 50000 sRes19f)" >/dev/null           # baseline 50000
run 200 "$(rsjc - - 73 "$RT7" 20000 sRes19f)" >/dev/null           # resumed: restored to a smaller saved counter
[ "$(grep '^W7 ' "$SLC")" = "$t19fw" ] || { echo "  ★ FAIL T19f a smaller counter counted as an advance: [$(grep '^W7 ' "$SLC")]"; t19fbad=1; }
srow sRes19f | awk -v o="$t19fo" '$9==o&&$10=="20000"{ok=1} END{exit !ok}' || { echo "  ★ FAIL T19f (format) the smaller counter was not recorded as the baseline: [$(srow sRes19f)]"; t19fbad=1; }
t19ft=$(date +%s)
run 200 "$(rsjc - - 73 "$RT7" 20500 sRes19f)" >/dev/null           # 20000 -> 20500: a response after the resume
awk -v r="$RT7" -v t="$t19ft" '$1=="W7"&&NF==4&&$2==r&&$3==73&&$4>=t{ok=1} END{exit !ok}' "$SLC" || { echo "  ★ FAIL T19f the increase past the smaller baseline was not fresh: [$(grep '^W7 ' "$SLC")]"; t19fbad=1; }
srow sRes19f | awk -v t="$t19ft" 'NF==11&&$9>=t&&$10=="20500"&&$11>=t{ok=1} END{exit !ok}' || { echo "  ★ FAIL T19f (format) row: [$(srow sRes19f)]"; t19fbad=1; }
[ "$t19fbad" -eq 0 ] && echo "  T19f a smaller counter becomes the baseline and the next increase is fresh OK" || fail=1

# T19g the usable/unusable counter table. A usable counter decides the observation time (here: no recorded counter yet, so the
# changed pair is carried, not stamped); an unusable one falls back to the pair-change rule (the changed pair is stamped now).
t19gbad=0
while read -r t19gl t19gpct t19gfld; do
  tn=$(date +%s); t19go=$((tn-3000))
  printf "S %s %s %s 14 %s - - -\nW5 %s 20 %s\n" "$(sidof "sTab19g$t19gl")" $((tn-5000)) "$RT" "$t19go" "$RT" $((tn-100)) > "$SLC"
  t19g=$(run 200 "$(rsjc 21 "$RT" - - "$t19gl" "sTab19g$t19gl")" | nocol)
  case "$t19g" in *" $t19gpct%"*) ;; *) echo "  ★ FAIL T19g counter [$t19gl]: expected $t19gpct% left: [$t19g]"; t19gbad=1 ;; esac
  srow "sTab19g$t19gl" | awk -v f="$t19gfld" 'NF==11&&$10==f{ok=1} END{exit !ok}' || { echo "  ★ FAIL T19g (format) counter [$t19gl] should be recorded as [$t19gfld]: [$(srow "sTab19g$t19gl")]"; t19gbad=1; }
done <<'T19G'
43500 80 43500
0 80 0
absent 79 -
null 79 -
12.5 79 -
"abc" 79 -
T19G
[ "$t19gbad" -eq 0 ] && echo "  T19g digits (incl. 0) are a usable counter; absent/null/12.5/string fall back to the pair rule and record '-' OK" || fail=1

# T20 (E5) Claude Code leaves an expired window out of the JSON. A session whose own row shows it reported that class keeps showing
# the live class authority (value and countdown); a session that never reported the class stays silent.
t20bad=0; tn=$(date +%s)
printf "S %s %s %s 10 %s %s 56 %s\nW7 %s 2 %s\n" "$(sidof sIdle20)" $((tn-5000)) "$RT" $((tn-3000)) $((tn-100)) $((tn-4000)) "$RT7" $((tn-50)) > "$SLC"
t20=$(run 200 "$(rsjc 10 "$RT" - - 42000 sIdle20)" | nocol)       # 5h object only: the weekly window rolled while it idled
case "$t20" in *"3D11H 98%"*) ;; *) echo "  ★ FAIL T20 (E5) an idle session that stopped receiving seven_day did not show the live W7 (3D11H 98%): [$t20]"; t20bad=1 ;; esac
srow sIdle20 | awk -v r=$((tn-100)) -v o=$((tn-4000)) '$7==r&&$8==56&&$9==o{ok=1} END{exit !ok}' || { echo "  ★ FAIL T20 the adopting session's own 7d triple changed: [$(srow sIdle20)]"; t20bad=1; }
mkdir "$T19LOCK" 2>/dev/null                                       # same frame, read-only (lock held): adoption is identical
t20ro=$(run 200 "$(rsjc 10 "$RT" - - 42000 sIdle20)" | nocol); rmdir "$T19LOCK" 2>/dev/null
case "$t20ro" in *"3D11H 98%"*) ;; *) echo "  ★ FAIL T20 (E5) a read-only frame did not show the live W7: [$t20ro]"; t20bad=1 ;; esac
tn=$(date +%s)
printf "S %s %s %s 40 %s - - -\nW5 %s 3 %s\n" "$(sidof sIdle20b)" $((tn-5000)) $((tn-100)) $((tn-4000)) "$RT" $((tn-50)) > "$SLC"
t20b=$(run 200 "$(rsjc - - - - 42000 sIdle20b)" | nocol)           # no rate_limits object at all
case "$t20b" in *"2H"*" 97%"*) ;; *) echo "  ★ FAIL T20 (E5) an idle session that stopped receiving five_hour did not show the live W5 (2H.. 97%): [$t20b]"; t20bad=1 ;; esac
awk -v r="$RT" -v t="$tn" '$1=="P"&&$2==r&&$3>=t&&$4==3{n++} END{exit !(n==1)}' "$SLC" || { echo "  ★ FAIL T20 (E5) no single P sample under the W5 key with the W5 value: [$(grep '^P ' "$SLC")]"; t20bad=1; }
srow sIdle20b | awk -v r=$((tn-100)) -v o=$((tn-4000)) '$4==r&&$5==40&&$6==o{ok=1} END{exit !ok}' || { echo "  ★ FAIL T20 the adopting session's own 5h triple changed: [$(srow sIdle20b)]"; t20bad=1; }
tn=$(date +%s)
printf "S %s %s %s 10 %s - - -\nW7 %s 2 %s\n" "$(sidof sOther20)" $((tn-5000)) "$RT" $((tn-3000)) "$RT7" $((tn-50)) > "$SLC"
t20c=$(run 200 "$(rsjc 10 "$RT" - - 42000 sOther20)" | nocol)     # never reported seven_day
case "$t20c" in *" 90%"*) ;; *) echo "  ★ FAIL T20 positive control: the five-hour-only session lost its own 5h segment: [$t20c]"; t20bad=1 ;; esac
case "$t20c" in *"98%"*) echo "  ★ FAIL T20 a session that never reported seven_day surfaced another session's W7: [$t20c]"; t20bad=1 ;; esac
t20d=$(run 200 "$(rsjc 10 "$RT" - - 42000 raw:sl-e5probe)" | nocol)   # refused id, no row
case "$t20d" in *" 90%"*) ;; *) echo "  ★ FAIL T20 positive control: the refused id lost its own 5h segment: [$t20d]"; t20bad=1 ;; esac
case "$t20d" in *"98%"*) echo "  ★ FAIL T20 a refused id with no row surfaced another session's W7: [$t20d]"; t20bad=1 ;; esac
[ "$t20bad" -eq 0 ] && echo "  T20 (E5) a session whose row shows the class keeps showing the live authority and sampling 5h; others stay silent OK" || fail=1

# T21 (E4) a lock-contention frame records when it first saw a new API-activity count, so a later writable frame cannot stamp
# that older reading with a later second (spec example: A's 72 seen at 1000 loses to B's 73 observed at 1030).
t21bad=0; tn=$(date +%s); t21a=$(sidof sA21); t21b=$(sidof sB21)
printf "S %s %s - - - %s 71 %s\nS %s %s - - - %s 72 %s\nW7 %s 72 %s\n" \
  "$t21a" $((tn-5000)) "$RT7" $((tn-3000)) "$t21b" $((tn-5000)) "$RT7" $((tn-100)) "$RT7" $((tn-100)) > "$SLC"
run 200 "$(rsjc - - 71 "$RT7" 40000 sA21)" >/dev/null; run 200 "$(rsjc - - 72 "$RT7" 90000 sB21)" >/dev/null   # baselines
cp "$SLC" "$WORK/t21.before"
mkdir "$T19LOCK" 2>/dev/null                                       # another writer holds the lock
t21t0=$(date +%s)
t21c1=$(run 200 "$(rsjc - - 72 "$RT7" 41000 sA21)" | nocol)       # A's response arrived; its frame is read-only
t21t1=$(date +%s); rmdir "$T19LOCK" 2>/dev/null
case "$t21c1" in *" 28%"*) ;; *) echo "  ★ FAIL T21 the contention frame did not display the authority it read (28%): [$t21c1]"; t21bad=1 ;; esac
cmp -s "$SLC" "$WORK/t21.before" || { echo "  ★ FAIL T21 the contention frame changed the shared cache"; t21bad=1; }
t21s=""; [ -f "$SEEN.$t21a" ] && read -r t21sc t21s < "$SEEN.$t21a"
if [ "${t21sc:-}" = 41000 ] && [ -n "$t21s" ] && [ "$t21s" -ge "$t21t0" ] && [ "$t21s" -le "$t21t1" ]; then :; else
  echo "  ★ FAIL T21 (E4) the contention frame did not write the sighting '41000 <second>': [$(cat "$SEEN.$t21a" 2>/dev/null)]"; t21bad=1; t21s=$t21t1; fi
[ "$(stat -f '%Lp' "$SEEN.$t21a" 2>/dev/null)" = 600 ] || { echo "  ★ FAIL T21 the sighting is not mode 600: [$(stat -f '%Lp' "$SEEN.$t21a" 2>/dev/null)]"; t21bad=1; }
t19wait "$t21s"                                                    # B's observation is strictly later than A's sighting
run 200 "$(rsjc - - 73 "$RT7" 91000 sB21)" >/dev/null
t21w=$(grep '^W7 ' "$SLC")
case "$t21w" in "W7 $RT7 73 "*) ;; *) echo "  ★ FAIL T21 B's newer 73 was not adopted: [$t21w]"; t21bad=1 ;; esac
t21c2=$(run 200 "$(rsjc - - 72 "$RT7" 41000 sA21)" | nocol)       # A's next frame is writable, same counter as the sighting
case "$t21c2" in *" 27%"*) ;; *) echo "  ★ FAIL T21 (E4) A's older 72 took the authority from B's 73 (expected 27% left): [$t21c2]"; t21bad=1 ;; esac
[ "$(grep '^W7 ' "$SLC")" = "$t21w" ] || { echo "  ★ FAIL T21 (E4) W7 moved off B's record: before=[$t21w] after=[$(grep '^W7 ' "$SLC")]"; t21bad=1; }
srow sA21 | awk -v s="$t21s" '$8==72&&$9==s{ok=1} END{exit !ok}' || { echo "  ★ FAIL T21 (E4) A's o7 is not the sighting's second $t21s: [$(srow sA21)]"; t21bad=1; }
srow sA21 | awk -v s="$t21s" 'NF==11&&$9==s&&$10=="41000"&&$11>=s{ok=1} END{exit !ok}' || { echo "  ★ FAIL T21 (format) A's row: [$(srow sA21)]"; t21bad=1; }
[ -e "$SEEN.$t21a" ] && { echo "  ★ FAIL T21 the used sighting was not removed"; t21bad=1; }
[ "$t21bad" -eq 0 ] && echo "  T21 (E4) a change first seen under lock contention keeps that second and loses to a later observation OK" || fail=1

# T21b a sighting that does not match the frame's advanced counter (another value, a future second, or malformed) is not used,
# and the writable frame removes it after its cache write.
t21bbad=0
for t21bk in other future junk; do
  tn=$(date +%s); t21bs=$(sidof "sA21b$t21bk")
  printf "S %s %s - - - %s 71 %s\nW7 %s 72 %s\n" "$t21bs" $((tn-5000)) "$RT7" $((tn-3000)) "$RT7" $((tn-100)) > "$SLC"
  run 200 "$(rsjc - - 71 "$RT7" 40000 "sA21b$t21bk")" >/dev/null  # baseline 40000
  case "$t21bk" in
    other)  printf '41000 %s\n' $((tn-2000)) > "$SEEN.$t21bs" ;;   # an older response's sighting
    future) printf '42500 %s\n' $((tn+100000)) > "$SEEN.$t21bs" ;; # right counter, a second in the future
    junk)   printf 'garbage\n' > "$SEEN.$t21bs" ;;
  esac
  t21bt=$(date +%s)
  run 200 "$(rsjc - - 72 "$RT7" 42500 "sA21b$t21bk")" >/dev/null
  srow "sA21b$t21bk" | awk -v t="$t21bt" '$8==72&&$9>=t&&$9<=t+60{ok=1} END{exit !ok}' || { echo "  ★ FAIL T21b [$t21bk] sighting was used instead of now: [$(srow "sA21b$t21bk")]"; t21bbad=1; }
  [ -e "$SEEN.$t21bs" ] && { echo "  ★ FAIL T21b [$t21bk] the unused sighting was not removed"; t21bbad=1; }
done
[ "$t21bbad" -eq 0 ] && echo "  T21b a sighting for another counter, a future second or a malformed one is ignored and removed OK" || fail=1

# T21c frames without a contended advance create no sighting; a symbolic link at the sighting path is never written through.
t21cbad=0; tn=$(date +%s); t21cs=$(sidof sC21c); rm -f "$SEEN".* 2>/dev/null   # judge only what these frames create
t21cnone() {  # $1=case label → FAIL when any sighting file exists
  for f in "$SEEN".*; do [ -e "$f" ] || [ -L "$f" ] || continue; echo "  ★ FAIL T21c [$1] created a sighting: [${f##*/}]"; t21cbad=1; rm -f "$f"; done; }
printf "S %s %s - - - %s 71 %s\nW7 %s 72 %s\n" "$t21cs" $((tn-5000)) "$RT7" $((tn-3000)) "$RT7" $((tn-100)) > "$SLC"
run 200 "$(rsjc - - 71 "$RT7" 40000 sC21c)" >/dev/null             # baseline 40000
run 200 "$(rsjc - - 72 "$RT7" 41000 sC21c)" >/dev/null; t21cnone uncontended
mkdir "$T19LOCK" 2>/dev/null
run 200 "$(rsjc - - 72 "$RT7" 41000 sC21c)" >/dev/null; t21cnone not-advanced
run 200 "$(rsjc - - 72 "$RT7" absent sC21c)" >/dev/null; t21cnone unusable-counter
run 200 "$(rsjc - - 72 "$RT7" 99000 raw:sl-e4probe)" >/dev/null; t21cnone refused-id
run 200 "$(rsjc - - 72 "$RT7" 99000 raw:)" >/dev/null; t21cnone empty-id
printf "S %s %s - - - %s 71 %s\n" "$(sidof sD21c)" $((tn-5000)) "$RT7" $((tn-3000)) >> "$SLC"
run 200 "$(rsjc - - 72 "$RT7" 99000 sD21c)" >/dev/null; t21cnone no-recorded-counter
printf 'keep\n' > "$WORK/t21c.target"; ln -s "$WORK/t21c.target" "$SEEN.$t21cs"
t21cl=$(run 200 "$(rsjc - - 72 "$RT7" 99000 sC21c)" | nocol)     # advanced under contention, but the path is a link
rmdir "$T19LOCK" 2>/dev/null
[ -L "$SEEN.$t21cs" ] && [ "$(cat "$WORK/t21c.target")" = keep ] || { echo "  ★ FAIL T21c a sighting was written through or over a symbolic link"; t21cbad=1; }
case "$t21cl" in *" 28%"*) ;; *) echo "  ★ FAIL T21c the frame facing a linked sighting path did not display normally: [$t21cl]"; t21cbad=1 ;; esac
printf '99000 %s\n' $((tn-2000)) > "$WORK/t21c.target"; t21ct=$(date +%s)
run 200 "$(rsjc - - 73 "$RT7" 99000 sC21c)" >/dev/null             # writable: a linked sighting that would match is not used
srow sC21c | awk -v t="$t21ct" '$9>=t{ok=1} END{exit !ok}' || { echo "  ★ FAIL T21c a linked sighting was used: [$(srow sC21c)]"; t21cbad=1; }
rm -f "$SEEN.$t21cs"
[ "$t21cbad" -eq 0 ] && echo "  T21c no sighting from uncontended, non-advanced, unusable, refused or empty ids; links are never written or used OK" || fail=1

# T21d the age sweep: a sighting orphaned by a session that ended is removed once it is older than RL_REG_TTL, and only by a frame
# that wrote or removed a sighting; a young sighting of another session survives.
t21dbad=0; tn=$(date +%s); t21ds=$(sidof sA21d); rm -f "$SEEN".* 2>/dev/null
printf "S %s %s - - - %s 71 %s\nW7 %s 72 %s\n" "$t21ds" $((tn-5000)) "$RT7" $((tn-3000)) "$RT7" $((tn-100)) > "$SLC"
run 200 "$(rsjc - - 71 "$RT7" 40000 sA21d)" >/dev/null             # baseline 40000
t21dold="$SEEN.$(sidof sGone21d)"; t21dyoung="$SEEN.$(sidof sYoung21d)"
printf '5000 %s\n' $((tn-8*86400)) > "$t21dold"; touch -t "$(date -r $((tn-8*86400)) +%Y%m%d%H%M.%S)" "$t21dold"
printf '5000 %s\n' $((tn-60)) > "$t21dyoung"
run 200 "$(rsjc - - 71 "$RT7" 40000 sA21d)" >/dev/null             # neither writes nor removes a sighting: no sweep
[ -f "$t21dold" ] || { echo "  ★ FAIL T21d a frame that neither wrote nor removed a sighting ran the sweep"; t21dbad=1; }
printf '41000 %s\n' $((tn-30)) > "$SEEN.$t21ds"
run 200 "$(rsjc - - 72 "$RT7" 41000 sA21d)" >/dev/null             # consumes its own sighting, then sweeps
[ -e "$t21dold" ] && { echo "  ★ FAIL T21d an orphaned sighting older than RL_REG_TTL survived the sweep"; t21dbad=1; }
[ -f "$t21dyoung" ] || { echo "  ★ FAIL T21d the sweep removed a young sighting of another session"; t21dbad=1; }
rm -f "$SEEN".* 2>/dev/null
[ "$t21dbad" -eq 0 ] && echo "  T21d orphaned sightings older than RL_REG_TTL are swept only by a frame that wrote or removed one OK" || fail=1

# T21e a foreign object at this frame's sighting temp path (<cache>.seen.<sid>.<pid>) must not cost the contended frame its display,
# must never be moved into place or written through, and must print nothing. The reconcile core is sourced in a subshell with
# HOME=$FAKE_HOME so the pid in that path is known: $$ is this harness in the subshell as in the core.
t21ebad=0; tn=$(date +%s); t21es=$(sidof sA21e); t21et="$SEEN.$t21es.$$"; rm -f "$SEEN".* 2>/dev/null
printf "S %s %s - - - %s 71 %s\nW7 %s 72 %s\n" "$t21es" $((tn-5000)) "$RT7" $((tn-3000)) "$RT7" $((tn-100)) > "$SLC"
run 200 "$(rsjc - - 71 "$RT7" 40000 sA21e)" >/dev/null             # baseline 40000
t21ecore() {  # the core's five-field output for sA21e reporting 72 with counter 41000 while another writer holds the lock
  ( HOME="$FAKE_HOME"; export HOME; LC_ALL=C; export LC_ALL; RL_REG_TTL=604800
    . "$SL/lib/collect.sh"; RL_LOCK_TRIES=3
    session_id=$t21es now=$(date +%s) api_ms=41000 five_h="" five_reset="" seven_d=72 seven_reset=$RT7
    _reconcile_core ) 2>"$WORK/t21e.err"
}
mkdir "$T19LOCK" 2>/dev/null
for t21ek in dir link none; do
  case "$t21ek" in
    dir)  mkdir "$t21et" ;;
    link) printf 'keep\n' > "$WORK/t21e.target"; ln -s "$WORK/t21e.target" "$t21et" ;;
  esac
  t21eo=$(t21ecore)
  [ "$t21eo" = "||72|$RT7|" ] || { echo "  ★ FAIL T21e [$t21ek] the contended frame lost its display (want [||72|$RT7|]): [$t21eo]"; t21ebad=1; }
  [ -s "$WORK/t21e.err" ] && { echo "  ★ FAIL T21e [$t21ek] printed on stderr: [$(cat "$WORK/t21e.err")]"; t21ebad=1; }
  case "$t21ek" in
    dir)  [ -d "$t21et" ] || { echo "  ★ FAIL T21e [dir] the foreign directory at the temp path was moved or removed"; t21ebad=1; }
          [ -e "$SEEN.$t21es" ] && { echo "  ★ FAIL T21e [dir] a sighting appeared from a foreign temp object"; t21ebad=1; } ;;
    link) [ -L "$t21et" ] && [ "$(cat "$WORK/t21e.target")" = keep ] || { echo "  ★ FAIL T21e [link] the sighting was written through or over a link at the temp path"; t21ebad=1; }
          [ -e "$SEEN.$t21es" ] && { echo "  ★ FAIL T21e [link] a sighting appeared from a foreign temp object"; t21ebad=1; } ;;
    none) t21esc=""; [ -f "$SEEN.$t21es" ] && read -r t21esc t21ess < "$SEEN.$t21es"
          [ "$t21esc" = 41000 ] || { echo "  ★ FAIL T21e positive control: with a free temp path the sighting was not written: [$(cat "$SEEN.$t21es" 2>/dev/null)]"; t21ebad=1; }
          [ -e "$t21et" ] && { echo "  ★ FAIL T21e the sighting temp file was left behind"; t21ebad=1; } ;;
  esac
  rm -rf "$t21et" "$SEEN.$t21es"
done
rmdir "$T19LOCK" 2>/dev/null; rm -f "$SEEN".* 2>/dev/null
[ "$t21ebad" -eq 0 ] && echo "  T21e a foreign object at the sighting temp path costs no display, is never moved or written through OK" || fail=1

# T22 the eleven-field row, its upgrades, and retention measured from the session's last write.
t22bad=0; tn=$(date +%s); rm -f "$SLC"
run 200 "$(rsjc 20 "$RT" - - 5000 sFmt22)" >/dev/null
srow sFmt22 | awk -v r="$RT" -v t="$tn" 'NF==11&&$3>=t&&$4==r&&$5==20&&$10=="5000"&&$11>=t{ok=1} END{exit !ok}' || { echo "  ★ FAIL T22 (format) the frame's own row is not eleven fields: [$(srow sFmt22)]"; t22bad=1; }
# upgrade table: row before | frame counter | expected o5 and counter; W5 must stay the newer record in every row
while read -r t22row t22ctr t22o t22f; do
  tn=$(date +%s); t22fs=$((tn-5000)); t22sid=$(sidof "sUp22$t22row")
  case "$t22row" in
    three*) printf "S %s %s\nW5 %s 20 %s\n" "$t22sid" "$t22fs" "$RT" $((tn-100)) > "$SLC" ;;
    nine)   printf "S %s %s %s 14 %s - - -\nW5 %s 20 %s\n" "$t22sid" "$t22fs" "$RT" $((tn-4000)) "$RT" $((tn-100)) > "$SLC" ;;
  esac
  t22w=$(grep '^W5 ' "$SLC")
  run 200 "$(rsjc 14 "$RT" - - "$t22ctr" "sUp22$t22row")" >/dev/null
  [ "$(grep '^W5 ' "$SLC")" = "$t22w" ] || { echo "  ★ FAIL T22 upgrading a $t22row row handed it the authority: [$(grep '^W5 ' "$SLC")]"; t22bad=1; }
  case "$t22o" in fs) t22o=$t22fs ;; o9) t22o=$((tn-4000)) ;; esac
  srow "sUp22$t22row" | awk -v fs="$t22fs" -v r="$RT" -v o="$t22o" -v f="$t22f" -v t="$tn" 'NF==11&&$3==fs&&$4==r&&$5==14&&$6==o&&$7=="-"&&$8=="-"&&$9=="-"&&$10==f&&$11>=t{ok=1} END{exit !ok}' || { echo "  ★ FAIL T22 (format) upgrade of a $t22row row with counter [$t22ctr]: [$(srow "sUp22$t22row")]"; t22bad=1; }
done <<'T22U'
three absent fs -
threec 42000 0 42000
nine 42000 o9 42000
T22U
# other sessions' rows across one rewrite: eleven kept as is, nine and three upgraded, malformed dropped
tn=$(date +%s); t22fs=$((tn-5000)); t22ls=$((tn-50))
{ printf "S eleven22 %s %s 20 %s - - - 42000 %s\n" "$t22fs" "$RT" $((tn-4000)) "$t22ls"
  printf "S nine22 %s %s 20 %s - - -\n" "$t22fs" "$RT" $((tn-4000))
  printf "S three22 %s\n" "$t22fs"
  printf "S broken22 %s %s 20\n" "$t22fs" "$RT"
  printf "S ten22 %s - - - - - - 42000\n" "$t22fs"
  printf "S badctr22 %s - - - - - - x %s\n" "$t22fs" "$t22ls"
  printf "S badls22 %s - - - - - - 42000 y\n" "$t22fs"; } > "$SLC"
run 200 "$(rsjc 20 "$RT" - - 5000 sWriter22)" >/dev/null
grep -qx "S eleven22 $t22fs $RT 20 $((tn-4000)) - - - 42000 $t22ls" "$SLC" || { echo "  ★ FAIL T22 (format) a current eleven-field row did not survive unchanged: [$(grep '^S eleven22 ' "$SLC")]"; t22bad=1; }
grep -qx "S nine22 $t22fs $RT 20 $((tn-4000)) - - - - $t22fs" "$SLC" || { echo "  ★ FAIL T22 (format) a nine-field row was not upgraded with last_seen = first_seen: [$(grep '^S nine22 ' "$SLC")]"; t22bad=1; }
grep -qx "S three22 $t22fs - - - - - - - $t22fs" "$SLC" || { echo "  ★ FAIL T22 (format) a three-field row was not upgraded: [$(grep '^S three22 ' "$SLC")]"; t22bad=1; }
grep -q '^S \(broken22\|ten22\|badctr22\|badls22\) ' "$SLC" && { echo "  ★ FAIL T22 a malformed S row survived: [$(grep '^S \(broken22\|ten22\|badctr22\|badls22\) ' "$SLC")]"; t22bad=1; }
# E3 a terminal left open for eight days: first_seen is old, last_seen is recent, so another session's rewrite keeps its row
tn=$(date +%s); t22lfs=$((tn-8*86400)); t22lo=$((tn-8*86400+50000)); t22lid=$(sidof sLong22)
printf "S %s %s - - - %s 56 %s 880000 %s\nS %s %s %s 20 %s - - - 5000 %s\nW7 %s 73 %s\n" "$t22lid" "$t22lfs" "$RT7" "$t22lo" $((tn-60)) \
  "$(sidof sWriter22)" $((tn-5000)) "$RT" $((tn-4000)) $((tn-60)) "$RT7" $((tn-100)) > "$SLC"
t22w=$(grep '^W7 ' "$SLC")
run 200 "$(rsjc 20 "$RT" - - 5000 sWriter22)" >/dev/null          # another session rewrites the cache
[ -n "$(srow sLong22)" ] || { echo "  ★ FAIL T22 (E3) a session still writing lost its row to another session's rewrite"; t22bad=1; }
t22l=$(run 200 "$(rsjc - - 56 "$RT7" 880000 sLong22)" | nocol)
case "$t22l" in *" 27%"*) ;; *) echo "  ★ FAIL T22 (E3) a session open for eight days re-took the authority with its frozen 56 (expected 27% left): [$t22l]"; t22bad=1 ;; esac
[ "$(grep '^W7 ' "$SLC")" = "$t22w" ] || { echo "  ★ FAIL T22 (E3) W7 changed: [$(grep '^W7 ' "$SLC")]"; t22bad=1; }
srow sLong22 | awk -v fs="$t22lfs" -v o="$t22lo" -v t="$tn" 'NF==11&&$3==fs&&$9==o&&$10=="880000"&&$11>=t{ok=1} END{exit !ok}' || { echo "  ★ FAIL T22 (format) E3 row: [$(srow sLong22)]"; t22bad=1; }
# E3b the same session carried over as a nine-field row (no last_seen yet) is pruned, and its next report cannot take the authority
tn=$(date +%s)
printf "S %s %s - - - %s 56 %s\nW7 %s 73 %s\n" "$(sidof sLong22b)" $((tn-8*86400)) "$RT7" $((tn-8*86400+50000)) "$RT7" $((tn-100)) > "$SLC"
t22w=$(grep '^W7 ' "$SLC")
run 200 "$(rsjc 20 "$RT" - - 5000 sWriter22)" >/dev/null
t22lb=$(run 200 "$(rsjc - - 56 "$RT7" 880000 sLong22b)" | nocol)
case "$t22lb" in *" 27%"*) ;; *) echo "  ★ FAIL T22 (E3b) a re-registered session re-took the authority with its frozen 56 (expected 27% left): [$t22lb]"; t22bad=1 ;; esac
[ "$(grep '^W7 ' "$SLC")" = "$t22w" ] || { echo "  ★ FAIL T22 (E3b) W7 changed: [$(grep '^W7 ' "$SLC")]"; t22bad=1; }
# a row not written within the retention is pruned by another session's rewrite
tn=$(date +%s)
printf "S gone22 %s %s 20 %s - - - 42000 %s\n" $((tn-700000)) "$RT" $((tn-700000)) $((tn-604900)) > "$SLC"
run 200 "$(rsjc 20 "$RT" - - 5000 sWriter22)" >/dev/null
grep -q '^S gone22 ' "$SLC" && { echo "  ★ FAIL T22 a row last written more than RL_REG_TTL ago was not pruned"; t22bad=1; }
[ -n "$(srow sWriter22)" ] || { echo "  ★ FAIL T22 positive control: the writer's own row is missing"; t22bad=1; }
[ "$t22bad" -eq 0 ] && echo "  T22 eleven-field rows, previous-format upgrades, malformed rows dropped, retention from last activity (E3) OK" || fail=1
rm -f "$SLC" "$SEEN".* 2>/dev/null; rm -rf "$T19LOCK" 2>/dev/null

echo "── T2. RATE-SYNC CONCURRENCY: mkdir-lock serialises read+awk+mv (no lost-update), lock-contention safe-skip, empty-sid read-only, torn-cache survives"
LOCK="$SLC.lock"
rm -f "$SLC"; rm -rf "$LOCK" 2>/dev/null
# T2.0 stale carried observation loses to a fresher authority for the same live window.
RTc=$((NOW + 9000)); OLDc=$((NOW - 5000)); NEWc=$((NOW - 100))
printf "S sNew %s %s 47 %s - - -\nS $(sidof sOldLow) %s %s 12 %s - - -\nW5 %s 47 %s\n" \
  "$NEWc" "$RTc" "$NEWc" "$OLDc" "$RTc" "$OLDc" "$RTc" "$NEWc" > "$SLC"
t20=$(run 120 "$(rsj 12 "$RTc" sOldLow)" | nocol)
case "$t20" in *" 53%"*) echo "  T2.0 old frozen-low adopts newer authority 47 → remaining 53% OK" ;;
  *" 88%"*) echo "  ★ FAIL T2.0 old session used its own frozen 12 (showed 88%): [$t20]"; fail=1 ;;
  *) echo "  ★ FAIL T2.0 expected 53% remaining: [$t20]"; fail=1 ;; esac
wline=$(grep "^W5 $RTc " "$SLC")
case "$wline" in "W5 $RTc 47 $NEWc") echo "  T2.0 persisted W5 = freshest value+auth_observed_at (47 $NEWc), stale frame didn't clobber OK" ;;
  *) echo "  ★ FAIL T2.0 W line clobbered by older session: [$wline]"; fail=1 ;; esac

# T2.1 (5.1) Two sessions render CONCURRENTLY on DIFFERENT classes (one 5h, one 7d) → both class authority lines survive
# (no lost-update from racing rewrites; same-class distinct keys converge to the newest by design, so the race is cross-class)
rm -f "$SLC"; rm -rf "$LOCK" 2>/dev/null
rsj7() {  # $1=used% $2=resets_at $3=session_id → seven_day-only json (mirror of rsj for the other class)
  jq -cn --arg cwd "$SL" --arg tp "$TP" --arg sid "$(sidof "${3:-sl-selftest}")" --argjson u "$1" --argjson r "$2" '
  { workspace:{current_dir:$cwd}, model:{display_name:"Opus"}, context_window:{used_percentage:5},
    rate_limits:{seven_day:{used_percentage:$u, resets_at:$r}}, session_id:$sid, transcript_path:$tp }'; }
WA=$((NOW + 9000)); WB=$((NOW + 300000))                             # a live 5h window and a live 7d window
N=16
for i in $(seq 1 $N); do
  run 120 "$(rsj 30 "$WA" sConcA)" >/dev/null 2>&1 &
  run 120 "$(rsj7 55 "$WB" sConcB)" >/dev/null 2>&1 &
done
wait
ca=$(grep -c "^W5 $WA " "$SLC" 2>/dev/null); ca=${ca:-0}
cb=$(grep -c "^W7 $WB " "$SLC" 2>/dev/null); cb=${cb:-0}
if [ "$ca" -ge 1 ] && [ "$cb" -ge 1 ]; then echo "  T2.1 concurrent cross-class renders: both class authorities survive (no lost-update) OK"
else echo "  ★ FAIL T2.1 lost-update under concurrency: W5-lines=$ca W7-lines=$cb"; fail=1; fi
rm -rf "$LOCK" 2>/dev/null

# T2.2 (5.1) Lock CONTENTION: a held (fresh) lock makes the frame SKIP the write, but it STILL displays the adopted authority value.
rm -f "$SLC"; rm -rf "$LOCK" 2>/dev/null
printf 'S sNew %s %s 47 %s - - -\nW5 %s 47 %s\n' "$NEWc" "$RTc" "$NEWc" "$RTc" "$NEWc" > "$SLC"    # cache holds authority 47
mkdir "$LOCK" 2>/dev/null                                           # another writer "holds" the lock (fresh mtime → not stealable)
szbefore=$(wc -c < "$SLC"); szbefore=${szbefore// /}; mtbefore=$(stat -f '%m' "$SLC")
t22=$(run 120 "$(rsj 12 "$RTc" sContend)" | nocol)                  # this frame can't get the lock → must read-only adopt 47
case "$t22" in *" 53%"*) echo "  T2.2 lock-contention frame still adopts authority 47 -> 53% OK" ;;
  *" 88%"*) echo "  ★ FAIL T2.2 contention frame fell back to its own 12 (showed 88%): [$t22]"; fail=1 ;;
  *) echo "  ★ FAIL T2.2 expected 53%: [$t22]"; fail=1 ;; esac
szafter=$(wc -c < "$SLC"); szafter=${szafter// /}; mtafter=$(stat -f '%m' "$SLC")
if [ "$szbefore" = "$szafter" ] && [ "$mtbefore" = "$mtafter" ]; then echo "  T2.2 contention frame did NOT rewrite the cache (skipped write) OK"
else echo "  ★ FAIL T2.2 contention frame rewrote the cache (size $szbefore-$szafter mtime $mtbefore-$mtafter)"; fail=1; fi
rm -rf "$LOCK" 2>/dev/null

# T2.3 (5.1) STALE lock (older than the steal horizon) is stolen → the frame proceeds with its write
rm -f "$SLC"; rm -rf "$LOCK" 2>/dev/null
printf 'S sNew %s %s 47 %s - - -\nW5 %s 47 %s\n' "$OLDc" "$RTc" "$OLDc" "$RTc" "$OLDc" > "$SLC"   # authority carries an old observation
mkdir "$LOCK" 2>/dev/null
touch -t 200001010000 "$LOCK" 2>/dev/null                          # make the lock ancient → stealable
t23=$(run 120 "$(rsj 60 "$RTc" sFresh)" | nocol)                   # a fresh session reports 60 → after stealing the lock it becomes authority
case "$t23" in *" 40%"*) echo "  T2.3 stale lock stolen → fresh session writes authority 60 → 40% OK" ;;
  *) echo "  ★ FAIL T2.3 stale lock not stolen / wrong value: [$t23]"; fail=1 ;; esac
[ -d "$LOCK" ] && { echo "  ★ FAIL T2.3 lock dir leaked after a successful write"; fail=1; } || echo "  T2.3 lock released after the serialized write OK"

# T2.4 (5.2) EMPTY session_id: read-only adopt — must display the authority but NOT rewrite the cache (inode/size/mtime unchanged)
# Built inline (NOT via rsj, whose ${3:-default} would turn an empty sid into a real one) so session_id is genuinely "".
rsjempty() {  # $1=used% $2=resets_at → five_hour-only json with an EMPTY session_id
  jq -cn --arg cwd "$SL" --arg tp "$TP" --argjson u "$1" --argjson r "$2" '
  { workspace:{current_dir:$cwd}, model:{display_name:"Opus"}, context_window:{used_percentage:5},
    rate_limits:{five_hour:{used_percentage:$u, resets_at:$r}}, session_id:"", transcript_path:$tp }'; }
rm -f "$SLC"; rm -rf "$LOCK" 2>/dev/null
printf 'S sessA %s %s 47 %s - - -\nW5 %s 47 %s\n' "$NEWc" "$RTc" "$NEWc" "$RTc" "$NEWc" > "$SLC"
inob=$(stat -f '%i' "$SLC"); szb=$(wc -c < "$SLC"); szb=${szb// /}; mtb=$(stat -f '%m' "$SLC")
t24=$(run 120 "$(rsjempty 80 "$RTc")" | nocol)                     # empty sid reporting a HIGHER 80 — must be ignored, 47 adopted
case "$t24" in *" 53%"*) echo "  T2.4 empty-sid frame adopts authority 47 (ignores its own 80) -> 53% OK" ;;
  *" 20%"*) echo "  ★ FAIL T2.4 empty-sid overrode authority with its own 80 (showed 20%): [$t24]"; fail=1 ;;
  *) echo "  ★ FAIL T2.4 expected 53%: [$t24]"; fail=1 ;; esac
inoa=$(stat -f '%i' "$SLC"); sza=$(wc -c < "$SLC"); sza=${sza// /}; mta=$(stat -f '%m' "$SLC")
cafter=$(cat "$SLC")
if [ "$inob" = "$inoa" ] && [ "$szb" = "$sza" ] && [ "$mtb" = "$mta" ]; then echo "  T2.4 empty-sid did NOT rewrite the cache (inode/size/mtime unchanged) OK"
else echo "  ★ FAIL T2.4 empty-sid rewrote the cache (inode $inob-$inoa size $szb-$sza mtime $mtb-$mta)"; fail=1; fi
case "$cafter" in "S sessA $NEWc $RTc 47 $NEWc - - -"*"W5 $RTc 47 $NEWc"*) echo "  T2.4 empty-sid left S and W lines intact OK" ;;
  *) echo "  ★ FAIL T2.4 empty-sid mutated cache contents: [$cafter]"; fail=1 ;; esac

# T2.5 (5.3) TORN / BINARY cache fixture: reconcile must not crash, frame stays single-line with a valid %, stderr clean
rm -f "$SLC"; rm -rf "$LOCK" 2>/dev/null
{ printf 'S sNew %s %s 47 %s - - -\nW5 %s 47 %s\n' "$NEWc" "$RTc" "$NEWc" "$RTc" "$NEWc"; printf 'W5 garbage notnum xx\nW garbage notnum xx\n'; head -c 64 /dev/urandom; printf '\nP %s notime nope\n' "$RTc"; } > "$SLC"
t25o=$(run 120 "$(rsj 33 "$RTc" sTorn)" 2>/dev/null)
t25e=$(run 120 "$(rsj 33 "$RTc" sTorn)" 2>&1 >/dev/null)
t25nl=$(printf '%s' "$t25o" | grep -c ''); t25p=$(printf '%s' "$t25o" | nocol)
t25bad=0
[ "$t25nl" -eq 1 ] || { echo "  ★ FAIL T2.5 torn cache → not single line ($t25nl)"; t25bad=1; }
[ -z "$t25e" ]     || { echo "  ★ FAIL T2.5 torn cache → stderr noise: [$t25e]"; t25bad=1; }
case "$t25p" in *%*) ;; *) echo "  ★ FAIL T2.5 torn cache → no valid % rendered: [$t25p]"; t25bad=1 ;; esac
[ "$t25bad" -eq 0 ] && echo "  T2.5 torn/binary cache survives: single line, valid %, clean stderr OK" || fail=1

# T2.6 (5.4) reconcile is BACKGROUNDED (overlapped with git): a function named reconcile_start must open an FD job and reconcile_read must reap it,
# both honouring the </dev/null hard rule (the bg job must NOT read the stdin JSON pipe). Behaviour-equivalent to the old sync path (T section above stays green).
T2C=$(grep -c 'reconcile_start\|reconcile_read' "$SL/lib/collect.sh")
[ "$T2C" -ge 2 ] && echo "  T2.6 reconcile split into start/read FD-job pair OK" || { echo "  ★ FAIL T2.6 reconcile not backgrounded (reconcile_start/reconcile_read absent)"; fail=1; }
# the bg reconcile job must redirect stdin from /dev/null (hard rule) — assert a reconcile procsub job carries </dev/null
grep -q 'exec [0-9]*< <(_reconcile.*</dev/null)' "$SL/lib/collect.sh" && echo "  T2.6 reconcile bg job has </dev/null (stdin hard rule) OK" || { echo "  ★ FAIL T2.6 reconcile bg job missing </dev/null"; fail=1; }
# T2.7 (1.1) mv guard: an awk-FAILURE frame (empty tmpfile) must NOT clobber the shared authority cache — a failing awk (here a PATH-shim
# awk that exits 0 producing nothing) leaves an empty per-pid temp; the unconditional mv would wipe what prior sessions persisted.
mkdir -p "$WORK/awkfail"; printf '#!/bin/sh\nexit 0\n' > "$WORK/awkfail/awk"; chmod +x "$WORK/awkfail/awk"
printf "S $(sidof sKeep) %s %s 47 %s - - -\nW5 %s 47 %s\n" "$RECENT" "$RT" "$RECENT" "$RT" "$RECENT" > "$SLC"; t27seed=$(cat "$SLC")
printf '%s' "$(rsj 80 "$RT" sKeep)" | env PATH="$WORK/awkfail:$PATH" COLUMNS=120 HOME="$FAKE_HOME" bash "$SL/statusline-command.sh" >/dev/null 2>&1
t27after=$(cat "$SLC" 2>/dev/null)
[ "$t27seed" = "$t27after" ] && echo "  T2.7 awk-failure frame preserved the authority cache (mv guarded on empty tmpfile) OK" || { echo "  ★ FAIL T2.7 empty tmpfile clobbered the cache: before=[$t27seed] after=[$t27after]"; fail=1; }
rm -f "$SLC"; rm -rf "$LOCK" 2>/dev/null

echo "── T3. SYNTHETIC-SID GATE (2026-08-31 incident): only a real UUID session id may persist into the shared cache"
# The incident: a demo frame rendered against the real $HOME with the made-up id `sl-sepdemo` became the freshest observation
# and won the W7 authority election, flipping every live session's 7d segment from "84% left / 6D15H" to a red "16% left / 1D7H".
# lib/collect.sh's sid_persistable now refuses to persist any session id that is not UUID-shaped (8-4-4-4-12 lowercase hex);
# such a frame takes the same read-only path as an empty sid — it adopts what it reads and writes nothing at all.
rsjraw() {  # $1=used7% $2=resets_at $3=RAW session_id (deliberately NOT run through sidof) → seven_day-only json
  jq -cn --arg cwd "$SL" --arg tp "$TP" --arg sid "$3" --argjson u "$1" --argjson r "$2" '
  { workspace:{current_dir:$cwd}, model:{display_name:"Opus"}, context_window:{used_percentage:5},
    rate_limits:{seven_day:{used_percentage:$u, resets_at:$r}}, session_id:$sid, transcript_path:$tp }'; }
rm -f "$SLC"; rm -rf "$LOCK" 2>/dev/null
RT7g=$((NOW + 500000)); AUTHOBS=$((NOW - 200))
# What a real session established: 7d used 16% → the line shows 84% remaining. A synthetic frame reporting 84% used (16% remaining,
# the incident's red number) is NEWER, so without the gate it would take authority and every session would show 16%.
printf "S %s %s - - - %s 16 %s\nW7 %s 16 %s\n" "$(sidof sReal7)" "$AUTHOBS" "$RT7g" "$AUTHOBS" "$RT7g" "$AUTHOBS" > "$SLC"
t3seed=$(cat "$SLC"); t3bad=0
for badsid in sl-sepdemo sl-live-check sl-probe sl sl-selftest E3C7E9B8-EE85-4237-B9EF-F42F666D8C91; do
  t3out=$(printf '%s' "$(rsjraw 84 "$RT7g" "$badsid")" | env COLUMNS=120 HOME="$FAKE_HOME" bash "$SL/statusline-command.sh" | nocol)
  grep -q "^S $badsid " "$SLC" 2>/dev/null && { echo "  ★ FAIL T3 synthetic sid [$badsid] wrote its own S row into the shared cache"; t3bad=1; }
  [ "$t3seed" = "$(cat "$SLC")" ] || { echo "  ★ FAIL T3 synthetic sid [$badsid] rewrote the shared cache: [$(cat "$SLC")]"; t3bad=1; }
  case "$t3out" in *" 84%"*) ;;
    *" 16%"*) echo "  ★ FAIL T3 synthetic sid [$badsid] seized the authority — the 2026-08-31 incident reproduced (showed 16%): [$t3out]"; t3bad=1 ;;
    *) echo "  ★ FAIL T3 synthetic sid [$badsid] did not read-only-adopt the authority (expected 84% remaining): [$t3out]"; t3bad=1 ;; esac
done
# Positive control: the gate rejects by SHAPE, it does not switch syncing off — a real UUID session id must still take authority.
t3real=$(sidof sRealWriter)
t3rout=$(printf '%s' "$(rsjraw 90 "$RT7g" "$t3real")" | env COLUMNS=120 HOME="$FAKE_HOME" bash "$SL/statusline-command.sh" | nocol)
grep -q "^S $t3real " "$SLC" 2>/dev/null || { echo "  ★ FAIL T3 a real UUID session id failed to persist (gate rejects too much)"; t3bad=1; }
case "$t3rout" in *" 10%"*) ;; *) echo "  ★ FAIL T3 real UUID session id did not take authority (expected 10% remaining): [$t3rout]"; t3bad=1 ;; esac
[ "$t3bad" -eq 0 ] && echo "  T3 synthetic session ids cannot touch the shared authority; real UUIDs still sync OK" || fail=1
rm -f "$SLC"; rm -rf "$LOCK" 2>/dev/null

echo "── T4. SANDBOX DISCIPLINE: nothing here may render the statusline against the real \$HOME"
t4bad=0
# (a) Self-audit: every invocation of the real command in THIS harness must carry a HOME override (or go through sandbox-run.sh).
#     Backslash-continued lines are joined first, so an `env … HOME=… \` + `bash …statusline-command.sh` pair reads as one command.
t4audit() {  # $1=harness file → its un-isolated command invocations, one per line (empty = clean)
  python3 - "$1" <<'PYAUDIT'
import sys, re
joined = re.sub(r'\\\n\s*', ' ', open(sys.argv[1]).read())
bad = [l.strip() for l in joined.split('\n')
       if re.search(r'bash\s+"\$(SL|WORK)[^"]*/statusline-command\.sh"', l)
       and 'HOME=' not in l and 'sandbox-run.sh' not in l]
print('\n'.join(bad))
PYAUDIT
}
t4esc=$(t4audit "$SL/tests/run-tests.sh")
[ -z "$t4esc" ] || { printf '  ★ FAIL T4 harness renders the statusline with no HOME override:\n%s\n' "$t4esc"; t4bad=1; }
# (d) The subagent command writes under $HOME too (~/.claude/sl-subagents), so the audit must flag an un-isolated run of it,
#     by path and through $SASCRIPT. The synthetic lines are assembled with %s so this source line itself never matches.
printf 'o=$(printf x | bash "$SL/subagent-status-%s.sh")\nprintf x | bash "$%s" >/dev/null\nprintf x | env HOME="$FAKE_HOME" bash "$%s"\n' \
  line SASCRIPT SASCRIPT > "$WORK/t4d.sh"
t4d=$(t4audit "$WORK/t4d.sh")
[ "$(printf '%s' "$t4d" | grep -c 'subagent-status-line\.sh\|SASCRIPT" >')" = 2 ] && [ "$(printf '%s\n' "$t4d" | grep -c .)" = 2 ] \
  || { printf '  ★ FAIL T4(d) the audit missed an un-isolated subagent command run (or flagged an isolated one):\n%s\n' "$t4d"; t4bad=1; }
# (b) MACHINE-STATE AUDIT — the ONE check in this file that is not a hermetic code test. Everything else here renders against
#     $FAKE_HOME and asserts a property of the CODE; this block opens the user's REAL shared cache and asserts a property of the
#     MACHINE, so its verdict depends on state no test fixture controls. It is kept deliberately: it is the standing detector for
#     the 2026-08-31 incident, the only place that would notice if a frame ever again stamped a synthetic session row into the
#     file every live session reads. The judge is the production gate itself (sid_persistable, sourced in a subshell) so the
#     audit can never drift from the shipped rule. It is read-only — it never writes the real cache.
#     Being machine-state, it has two failure modes an ordinary assert does not, and both are handled explicitly:
#       * FALSE GREEN — no cache file (a fresh machine, a CI box, a different user) used to fall through this whole branch in
#         silence while the section still printed its OK line. It now prints a SKIP and the section summary says, in words, that
#         the audit did not run. A skip is never reported as a pass.
#       * FALSE RED — the delta spec is explicit that a refused id's row is never deleted or rewritten, so a LEGAL leftover row
#         written before the gate shipped may sit in this file forever. Failing on it would keep the suite red for a machine
#         state this change never claimed to repair. Attribution is therefore BY TIME: a synthetic row fails only when the newest
#         numeric stamp on it (first_seen / o5 / o7 / last_seen, i.e. fields 3, 6, 9 and 11 of "S <sid> <first_seen> <r5> <u5> <o5>
#         <r7> <u7> <o7> <api_ms> <last_seen>") is at or after HARNESS_T0, the second this run started — only then could this run have written it. Anything
#         older is reported as pre-existing residue and does not fail. Conservative edge: a synthetic row written by a CONCURRENT
#         third party mid-run is indistinguishable from one of ours and does fail — that is still a true pollution report.
#     SL_AUDIT_CACHE overrides the file inspected, so this audit is itself auditable: point it at a fixture to exercise the
#     absent-file and the old-residue branches without ever touching the real cache. Read-only; defaults to the real path.
echo "  ── T4(b) MACHINE-STATE AUDIT (not a hermetic test: reads the real shared cache, judges this machine)"
t4cache=${SL_AUDIT_CACHE:-$HOME/.claude/sl-ratelimit-cache}
t4audited=no
if ! ( . "$SL/lib/collect.sh" 2>/dev/null; type sid_persistable >/dev/null 2>&1 ); then
  echo "  ★ FAIL T4 lib/collect.sh defines no sid_persistable — the synthetic-sid write gate is gone"; t4bad=1
elif [ ! -f "$t4cache" ]; then
  echo "  SKIP T4(b) no shared cache at [$t4cache] — there is no machine state to audit here; this check did NOT run and is NOT a pass"
else
  t4audited=yes
  # Emits one "NEW:<sid>" or "OLD:<sid>" token per synthetic row: NEW = stampable by this run (fails), OLD = pre-existing (reported only).
  t4synth=$( . "$SL/lib/collect.sh" 2>/dev/null
             while read -r t4tag t4sid t4fs t4r5 t4u5 t4o5 t4r7 t4u7 t4o7 t4api t4ls; do
               [ "$t4tag" = "S" ] || continue
               sid_persistable "$t4sid" && continue
               t4newest=0
               for t4ts in "$t4fs" "$t4o5" "$t4o7" "$t4ls"; do
                 case "$t4ts" in (''|*[!0-9]*) continue ;; esac      # "-" placeholders and junk carry no attribution. The
                 # leading "(" is load-bearing: bash 3.2 (macOS /bin/bash) cannot parse a bare case pattern inside $( ).
                 [ "$t4ts" -gt "$t4newest" ] && t4newest=$t4ts
               done
               if [ "$t4newest" -ge "$HARNESS_T0" ]; then printf 'NEW:%s ' "$t4sid"; else printf 'OLD:%s ' "$t4sid"; fi
             done < "$t4cache" )
  t4new=""; t4old=""
  for t4tok in $t4synth; do
    case "$t4tok" in NEW:*) t4new="$t4new ${t4tok#NEW:}" ;; OLD:*) t4old="$t4old ${t4tok#OLD:}" ;; esac
  done
  [ -z "$t4new" ] || { echo "  ★ FAIL T4(b) a synthetic session row was stamped into the REAL shared cache DURING this run — the 2026-08-31 incident is live again:$t4new"; t4bad=1; }
  [ -z "$t4old" ] || echo "  NOTE T4(b) pre-existing synthetic rows predate this run; the gate leaves them alone by design (spec: refused ids are never deleted or rewritten), so this is not a failure:$t4old"
  [ -n "$t4new$t4old" ] || echo "  T4(b) real shared cache [$t4cache]: every S row is a real session id"
fi
# (c) scripts/sandbox-run.sh must FAIL CLOSED when the sandbox HOME would land under /Users. The probe TMPDIR is a fresh
#     directory under /Users/Shared (the world-writable sticky directory every macOS install ships), not "$SL/tests": that
#     only reached the guard while the checkout itself sat under /Users, so a verifier's worktree under /private/tmp handed
#     sandbox-run.sh a harmless TMPDIR, it rendered normally, and this case read red. /Users/Shared is also outside any real
#     $HOME, so only the /Users/* branch of the guard can refuse it; under "$SL/tests" the $REAL_HOME branch refused as well
#     and would have hidden a guard that lost its /Users/* branch. No probe directory means FAIL, never a skip.
T4UDIR=$(mktemp -d /Users/Shared/sl-t4probe.XXXXXX 2>/dev/null) || T4UDIR=""
if [ -z "$T4UDIR" ]; then
  echo "  ★ FAIL T4 could not create a probe directory under /Users/Shared, so the /Users guard of sandbox-run.sh went untested"; t4bad=1
else
  t4sb=$(printf '{}' | env TMPDIR="$T4UDIR" bash "$SL/scripts/sandbox-run.sh" --columns 80 2>&1); t4sbrc=$?
  rm -rf "$T4UDIR"; T4UDIR=""
  [ "$t4sbrc" = 2 ] || { echo "  ★ FAIL T4 sandbox-run.sh did not refuse a /Users sandbox HOME (rc=$t4sbrc): [$t4sb]"; t4bad=1; }
  case "$t4sb" in *"refusing to run"*) ;; *) echo "  ★ FAIL T4 sandbox-run.sh guard message missing: [$t4sb]"; t4bad=1 ;; esac
fi
# (c, continued) …and must still render a normal frame from its own throwaway HOME.
t4line=$(printf '%s' "$(rsj 20 "$RT" sSandbox)" | bash "$SL/scripts/sandbox-run.sh" --columns 120); t4nl=$(printf '%s' "$t4line" | grep -c '')
[ "$t4nl" -eq 1 ] || { echo "  ★ FAIL T4 sandbox-run.sh did not emit a single line ($t4nl): [$t4line]"; t4bad=1; }
case "$(printf '%s' "$t4line" | nocol)" in *%*) ;; *) echo "  ★ FAIL T4 sandbox-run.sh rendered no percentage: [$t4line]"; t4bad=1 ;; esac
# (e) --subagents SID=FILE seeds this session's subagent state in the throwaway HOME (fresh epoch when FILE holds only the
#     seven counts), so a hand-rendered frame shows the summary line; the same frame without the option shows one line.
printf '0 0 0 2 0 0 0\n' > "$WORK/t4e.sub"
t4e=$(printf '%s' "$(rsj 20 "$RT" sSandbox)" | bash "$SL/scripts/sandbox-run.sh" --subagents "$(sidof sSandbox)=$WORK/t4e.sub" --columns 140 2>&1)
t4e1=$(printf '%s\n' "$t4e" | sed -n 1p | nocol); t4e2=$(printf '%s\n' "$t4e" | sed -n 2p | nocol)
[ "$SUBPOS" != below ] || { t4ex=$t4e1; t4e1=$t4e2; t4e2=$t4ex; }
[ "$(printf '%s\n' "$t4e" | grep -c '')" = 2 ] && [ "$t4e1" = "sub 2 │ RUN 2" ] && case "$t4e2" in *%*) true ;; *) false ;; esac \
  || { echo "  ★ FAIL T4(e) sandbox-run.sh --subagents did not render the summary line next to the session line: [$(printf '%s' "$t4e" | nocol)]"; t4bad=1; }
t4e0=$(printf '%s' "$(rsj 20 "$RT" sSandbox)" | bash "$SL/scripts/sandbox-run.sh" --columns 140 2>&1)
[ "$(printf '%s\n' "$t4e0" | grep -c '')" = 1 ] || { echo "  ★ FAIL T4(e) without --subagents the frame is not one line: [$(printf '%s' "$t4e0" | nocol)]"; t4bad=1; }
# The summary must state whether (b) actually ran: "OK" with the machine-state audit skipped would be the very false green above.
if [ "$t4bad" -ne 0 ]; then fail=1
elif [ "$t4audited" = yes ]; then echo "  T4 harness is HOME-isolated, real-cache audit ran and found no row this run could have written, sandbox-run.sh fails closed and renders OK"
else echo "  T4 harness is HOME-isolated, sandbox-run.sh fails closed and renders OK — machine-state audit (b) SKIPPED, not passed"; fi

echo "── U. LAST-MSG: 'HH:MM (Δ)' cache-age delta — <1m hides Δ, 5m/1h colour tiers, old format verbatim, cross-day date prefix"
NOWS=$(jq -n 'now|floor')
LMF="$FAKE_HOME/.claude/last-msg/sl-selftest"
# lmset <clock> <epoch>: write the per-session last-msg file AND set the transcript mtime to the same epoch.
# The (Δ) idle delta anchors on the transcript mtime (last activity ≈ turn end); lm_epoch still drives the clock
# label + cross-day prefix. Setting both to <epoch> keeps the delta reading as (now-epoch), so these fixtures
# assert the same outputs after the anchor moved from prompt time to last activity.
lmset() { printf '%s %s\n' "$1" "$2" > "$LMF"; touch -t "$(date -r "$2" '+%Y%m%d%H%M.%S')" "$TP" 2>/dev/null; }
lmrun() { lmset 09:30 "$(( NOWS - $1 ))"; run 200 "$J"; }                        # $1=idle sec → render with that last-activity age
pcode() { sed -E 's/.*\x1b\[([0-9;]*)m\(.*/\1/'; }    # SGR code right before the LAST "(" (the Δ segment)
strip()  { sed 's/\x1b\[[0-9;]*m//g'; }
# U1 Δ<1min suppressed → clock time only (no "(" after the time)
u1=$(lmrun 30 | strip)
case "$u1" in *"09:30 ("*) echo "  ★ FAIL U1 <1min should hide Δ: [$u1]"; fail=1 ;; *"09:30"*) echo "  U1 <1min: time only OK" ;; *) echo "  ★ FAIL U1 time missing"; fail=1 ;; esac
# U2 ~10min → minutes Δ (5m–1h yellow tier)
u2raw=$(lmrun 600); u2=$(printf '%s' "$u2raw" | strip)
case "$u2" in *"09:30 (10m)"*|*"09:30 (11m)"*) echo "  U2 10min: (10m) Δ OK" ;; *) echo "  ★ FAIL U2 expected (10m): [$u2]"; fail=1 ;; esac
# U3 ~2h → H/m Δ (≥1h red tier)
u3raw=$(lmrun 7200); u3=$(printf '%s' "$u3raw" | strip)
case "$u3" in *"09:30 (2H0m)"*|*"09:30 (1H59m)"*) echo "  U3 2h: (2H0m) Δ OK" ;; *) echo "  ★ FAIL U3 expected (2H0m): [$u3]"; fail=1 ;; esac
# U4 the three TTL tiers (warm <5m / 5m–1h / ≥1h) must be coloured differently
cw=$(lmrun 120 | pcode); cm=$(printf '%s' "$u2raw" | pcode); cc=$(printf '%s' "$u3raw" | pcode)
if [ -n "$cw" ] && [ -n "$cm" ] && [ -n "$cc" ] && [ "$cw" != "$cm" ] && [ "$cm" != "$cc" ] && [ "$cw" != "$cc" ]; then
  echo "  U4 three cache-TTL colour tiers distinct OK"
else echo "  ★ FAIL U4 tiers not distinct: warm=[$cw] mid=[$cm] cold=[$cc]"; fail=1; fi
# U5 backward compat — old "MM-DD HH:MM" (no epoch tail) shown verbatim
printf '06-07 19:38\n' > "$LMF"
u5=$(run 200 "$J" | strip)
case "$u5" in *"06-07 19:38"*) echo "  U5 old format verbatim OK" ;; *) echo "  ★ FAIL U5 old format dropped: [$u5]"; fail=1 ;; esac
# U6 cross-day (26h ago): different local calendar day → the timestamp gains a "MM-DD" date prefix (not a bare HH:MM)
U6AGE=$(( 26*3600 )); U6EP=$(( NOWS - U6AGE )); U6MD=$(date -r "$U6EP" '+%m-%d' 2>/dev/null)
u6=$(lmrun "$U6AGE" | strip)
case "$u6" in *"$U6MD 09:30 ("*) echo "  U6 cross-day (26h) date-prefixed $U6MD 09:30 OK" ;;
  *"09:30 ("*) echo "  ★ FAIL U6 cross-day NOT date-prefixed (expected $U6MD): [$u6]"; fail=1 ;;
  *) echo "  ★ FAIL U6 time segment missing: [$u6]"; fail=1 ;; esac
# U7 10 min ago (already U2): normally same LOCAL day → BARE HH:MM, no date prefix. But within
# 10 min after local midnight, now-600 lands on YESTERDAY — the spec's normative cross-midnight-
# under-one-hour case — so the prefix is then REQUIRED. Derive the expectation from the fixture
# epoch's own calendar day instead of assuming wall-clock (the suite was flaky 00:00–00:10).
U7EP=$(( NOWS - 600 )); U7MD=$(date -r "$U7EP" '+%m-%d' 2>/dev/null)
u7=$(lmrun 600 | strip)
if [ "$U7MD" = "$(date -r "$NOWS" '+%m-%d' 2>/dev/null)" ]; then
  case "$u7" in *[0-9][0-9]-[0-9][0-9]" 09:30 ("*) echo "  ★ FAIL U7 same-day wrongly date-prefixed: [$u7]"; fail=1 ;;
    *"09:30 ("*) echo "  U7 same-day bare HH:MM (no date prefix) OK" ;;
    *) echo "  ★ FAIL U7 time segment missing: [$u7]"; fail=1 ;; esac
else
  case "$u7" in *"$U7MD 09:30 ("*) echo "  U7 cross-midnight (<1h) date-prefixed $U7MD OK" ;;
    *"09:30 ("*) echo "  ★ FAIL U7 cross-midnight NOT date-prefixed (expected $U7MD): [$u7]"; fail=1 ;;
    *) echo "  ★ FAIL U7 time segment missing: [$u7]"; fail=1 ;; esac
fi
# U8 cross-day prefix does NOT alter the delta colour tier: 26h ≥ LASTMSG_STALE → still the red (≥1h) tier, same as a bare-time ≥1h delta
u8cross=$(lmrun "$U6AGE" | pcode); u8bare=$(printf '%s' "$u3raw" | pcode)
if [ -n "$u8cross" ] && [ "$u8cross" = "$u8bare" ]; then echo "  U8 date prefix keeps the same Δ colour tier (red) OK";
else echo "  ★ FAIL U8 date prefix changed the Δ colour tier (cross=[$u8cross] bare=[$u8bare])"; fail=1; fi
# U9 REGRESSION: (Δ) anchors on the turn's last activity (transcript mtime), NOT the prompt time (lm_epoch).
# A prompt submitted 2h10m ago whose turn last wrote 90s ago must read as a warm ~(1m) idle, never a red (2H10m).
# Falsifiable: revert the render change (delta back on lm_epoch) and this asserts (2H10m) → FAIL.
printf '09:30 %s\n' "$(( NOWS - 7800 ))" > "$LMF"                 # prompt 2h10m ago (drives the clock label only)
touch -t "$(date -r "$(( NOWS - 90 ))" '+%Y%m%d%H%M.%S')" "$TP"  # last activity 90s ago (drives the idle delta)
u9=$(run 200 "$J" | strip)
case "$u9" in
  *"09:30 (1m)"*|*"09:30 (2m)"*) echo "  U9 idle anchored on transcript mtime (warm ~1m, not 2H10m) OK" ;;
  *"(1H"*|*"(2H"*) echo "  ★ FAIL U9 delta anchored on prompt time, not last activity: [$u9]"; fail=1 ;;
  *) echo "  ★ FAIL U9 expected 09:30 (1m): [$u9]"; fail=1 ;;
esac
# U10 FALLBACK: transcript_path points at a missing file → act_epoch empty → (Δ) falls back to lm_epoch (prompt
# time), reproducing pre-change behavior for hosts/renders without a usable transcript.
printf '09:30 %s\n' "$(( NOWS - 600 ))" > "$LMF"
JNOTP=$(jq -cn --arg cwd "$SL" '
  { workspace:{current_dir:$cwd, project_dir:$cwd}, model:{display_name:"Opus 4.8 (1M context)"},
    context_window:{used_percentage:6.2},
    rate_limits:{ five_hour:{used_percentage:23, resets_at:(now+3960|floor)},
                  seven_day:{used_percentage:84, resets_at:(now+112000|floor)} },
    session_id:"sl-selftest", transcript_path:"/nonexistent/sl-missing.jsonl" }')
u10=$(run 200 "$JNOTP" | strip)
case "$u10" in *"09:30 (10m)"*|*"09:30 (11m)"*) echo "  U10 transcript-missing falls back to lm_epoch (10m) OK" ;; *) echo "  ★ FAIL U10 fallback expected 09:30 (10m): [$u10]"; fail=1 ;; esac
printf '06-07 19:38\n' > "$LMF"   # restore baseline

echo "── DUR. SESSION DURATION drives the time segment: cost.total_duration_ms → '<dur> (Δ)', replaces clock, keeps Δ, format boundaries"
# mkdur: a standard roomy frame WITH cost.total_duration_ms ($1 = ms). Same session_id so the U-section last-msg file applies.
mkdur() { jq -cn --arg cwd "$SL" --arg tp "$TP" --argjson d "$1" '
  { workspace:{current_dir:$cwd, project_dir:$cwd}, model:{display_name:"Opus 4.8 (1M context)"},
    context_window:{used_percentage:6.2},
    rate_limits:{ five_hour:{used_percentage:23, resets_at:(now+3960|floor)},
                  seven_day:{used_percentage:84, resets_at:(now+112000|floor)} },
    session_id:"sl-selftest", transcript_path:$tp, cost:{total_duration_ms:$d} }'; }
# DUR1: duration is the PRIMARY text, the absolute clock 09:30 is REPLACED, the Δ-since-last-prompt is kept → "1H15m (10m)"
lmset 09:30 "$(( NOWS - 600 ))"
d1=$(run 200 "$(mkdur 4521000)" | strip)
case "$d1" in *"1H15m (10m)"*|*"1H15m (11m)"*) echo "  DUR1 duration primary + Δ kept (1H15m (10m)) OK" ;; *) echo "  ★ FAIL DUR1 expected 1H15m (10m): [$d1]"; fail=1 ;; esac
case "$d1" in *"09:30"*) echo "  ★ FAIL DUR1 absolute clock 09:30 not replaced by duration: [$d1]"; fail=1 ;; esac
# DUR2: last prompt <1min → Δ hidden, duration alone (clock still replaced)
lmset 09:30 "$(( NOWS - 30 ))"
d2=$(run 200 "$(mkdur 4521000)" | strip)
case "$d2" in *"1H15m ("*) echo "  ★ FAIL DUR2 <1min should hide Δ: [$d2]"; fail=1 ;; *"1H15m"*) echo "  DUR2 <1min: duration only, no Δ OK" ;; *) echo "  ★ FAIL DUR2 duration missing: [$d2]"; fail=1 ;; esac
# DUR3: no last-msg file at all → duration still shows (the segment is duration-driven, not last-msg-driven)
rm -f "$LMF"
d3=$(run 200 "$(mkdur 4521000)" | strip)
case "$d3" in *"1H15m"*) echo "  DUR3 duration shows with no last-msg file OK" ;; *) echo "  ★ FAIL DUR3 duration missing with no last-msg: [$d3]"; fail=1 ;; esac
# DUR4: fmt_dur boundaries — <1h has no H (40m); >=1 day uses D/H (2D3H)
d4a=$(run 200 "$(mkdur 2400000)" | strip)     # 2,400,000 ms = 40 m
case "$d4a" in *"40m"*) echo "  DUR4a <1h → 40m OK" ;; *) echo "  ★ FAIL DUR4a expected 40m: [$d4a]"; fail=1 ;; esac
d4b=$(run 200 "$(mkdur 183600000)" | strip)   # 183,600,000 ms = 2 d 3 h
case "$d4b" in *"2D3H"*) echo "  DUR4b >=1day → 2D3H OK" ;; *) echo "  ★ FAIL DUR4b expected 2D3H: [$d4b]"; fail=1 ;; esac
# DUR5: no cost field → legacy clock fallback unchanged (the absolute clock still renders with its Δ)
lmset 09:30 "$(( NOWS - 600 ))"
d5=$(run 200 "$J" | strip)
case "$d5" in *"09:30 (10m)"*|*"09:30 (11m)"*) echo "  DUR5 no-cost → legacy clock fallback (09:30) OK" ;; *) echo "  ★ FAIL DUR5 expected clock fallback 09:30 (10m): [$d5]"; fail=1 ;; esac
printf '06-07 19:38\n' > "$LMF"   # restore baseline

echo "── API. API THINKING TIME is the top-priority primary: cost.total_api_duration_ms → fmt_dur_s '<dur> (Δ)', overrides duration+clock, 3-level fallback"
# mkapi: a standard roomy frame whose cost object ($1 = whole JSON cost object) drives the time segment. Same session_id → the last-msg file applies.
mkapi() { jq -cn --arg cwd "$SL" --arg tp "$TP" --argjson c "$1" '
  { workspace:{current_dir:$cwd, project_dir:$cwd}, model:{display_name:"Opus 4.8 (1M context)"},
    context_window:{used_percentage:6.2},
    rate_limits:{ five_hour:{used_percentage:23, resets_at:(now+3960|floor)},
                  seven_day:{used_percentage:84, resets_at:(now+112000|floor)} },
    session_id:"sl-selftest", transcript_path:$tp, cost:$c }'; }
# API1: api time is the PRIMARY (overrides BOTH the duration 1H15m and the clock 09:30); the Δ-since-last-prompt is kept → "3m45s (10m)"
lmset 09:30 "$(( NOWS - 600 ))"
a1=$(run 200 "$(mkapi '{"total_duration_ms":4521000,"total_api_duration_ms":225000}')" | strip)
case "$a1" in *"3m45s (10m)"*|*"3m45s (11m)"*) echo "  API1 api primary + Δ kept (3m45s (10m)) OK" ;; *) echo "  ★ FAIL API1 expected 3m45s (10m): [$a1]"; fail=1 ;; esac
case "$a1" in *"1H15m"*) echo "  ★ FAIL API1 duration form 1H15m leaked (api must replace it): [$a1]"; fail=1 ;; esac
case "$a1" in *"09:30"*) echo "  ★ FAIL API1 absolute clock 09:30 not replaced by api time: [$a1]"; fail=1 ;; esac
# API2: fmt_dur_s boundary table (remove last-msg so only the bare primary shows, no Δ noise). Delegates to fmt_dur at >=1h.
rm -f "$LMF"
for pair in "500:0s" "45000:45s" "60000:1m0s" "3599000:59m59s" "4500000:1H15m" "97200000:1D3H"; do
  ms=${pair%%:*}; want=${pair##*:}
  a2=$(run 200 "$(mkapi "{\"total_api_duration_ms\":$ms}")" | strip)
  case "$a2" in *"$want"*) : ;; *) echo "  ★ FAIL API2 api=${ms}ms expected $want: [$a2]"; fail=1 ;; esac
done
echo "  API2 fmt_dur_s boundaries (0s/45s/1m0s/59m59s/1H15m/1D3H) OK"   # 500ms row pins the sub-second s=0 branch (spec table row 1)
a2p=$(run 200 "$(mkapi '{"total_api_duration_ms":45000}')" | strip)   # pin: sub-minute value carries NO minute prefix
case "$a2p" in *"m45s"*) echo "  ★ FAIL API2 45s carries a spurious minute prefix: [$a2p]"; fail=1 ;; *"45s"*) echo "  API2 45s has no minute prefix OK" ;; *) echo "  ★ FAIL API2 45s missing: [$a2p]"; fail=1 ;; esac
a2z=$(run 200 "$(mkapi '{"total_api_duration_ms":500}')" | strip)     # pin: sub-second (spec table row 1, s=0) is EXACTLY "0s", never "0m0s" — a plain *"0s"* substring would wrongly match "0m0s"
case "$a2z" in *"m0s"*) echo "  ★ FAIL API2 sub-second carries a minute prefix (0m0s): [$a2z]"; fail=1 ;; *"0s"*) echo "  API2 sub-second → 0s (no minute prefix) OK" ;; *) echo "  ★ FAIL API2 0s missing: [$a2z]"; fail=1 ;; esac
# API3: api time present, NO duration field → api is still the primary → "3m45s"
a3=$(run 200 "$(mkapi '{"total_api_duration_ms":225000}')" | strip)
case "$a3" in *"3m45s"*) echo "  API3 api primary with no duration field OK" ;; *) echo "  ★ FAIL API3 expected 3m45s: [$a3]"; fail=1 ;; esac
# API4: invalid api time (0 / non-numeric / negative) falls back to the session-duration 1H15m (never a spurious 0s).
# Build the frame JSON into a variable first: an inline $(run … "$(mkapi "…\":$bad")") triple-nests command subs and bash mangles the escaped quotes → empty frame.
a4ok=1
for bad in '0' '"abc"' '-5000'; do
  j4=$(mkapi "{\"total_duration_ms\":4521000,\"total_api_duration_ms\":$bad}")
  a4=$(run 200 "$j4" | strip)
  case "$a4" in *"1H15m"*) : ;; *) echo "  ★ FAIL API4 api=$bad should fall back to 1H15m: [$a4]"; fail=1; a4ok=0 ;; esac
  case "$a4" in *"0s"*) echo "  ★ FAIL API4 api=$bad rendered as 0s instead of falling back: [$a4]"; fail=1; a4ok=0 ;; esac
done
[ "$a4ok" = 1 ] && echo "  API4 invalid api (0/\"abc\"/-5000) falls back to duration 1H15m OK"
# API5: cost object present but NEITHER field usable → clock fallback with its Δ → "09:30 (10m)"
lmset 09:30 "$(( NOWS - 600 ))"
a5=$(run 200 "$(mkapi '{"total_duration_ms":0,"total_api_duration_ms":0}')" | strip)
case "$a5" in *"09:30 (10m)"*|*"09:30 (11m)"*) echo "  API5 both cost fields unusable → clock fallback 09:30 (10m) OK" ;; *) echo "  ★ FAIL API5 expected clock fallback 09:30 (10m): [$a5]"; fail=1 ;; esac
# API6: last prompt <1min → Δ hidden, api primary alone → "3m45s" with no "("
lmset 14:05 "$(( NOWS - 30 ))"
a6=$(run 200 "$(mkapi '{"total_api_duration_ms":225000}')" | strip)
case "$a6" in *"3m45s ("*) echo "  ★ FAIL API6 sub-minute prompt should hide Δ: [$a6]"; fail=1 ;; *"3m45s"*) echo "  API6 <1min prompt → api primary only, no Δ OK" ;; *) echo "  ★ FAIL API6 api primary missing: [$a6]"; fail=1 ;; esac
# API7: cross-day prompt (26h ago → prior local calendar day) with an API primary → the elapsed-span primary is NEVER date-prefixed
# (spec normative "An elapsed-span primary is never date-prefixed"); the date "MM-DD" prefix is a clock-fallback-only concern. The Δ still shows.
lmset 12:00 "$(( NOWS - 93600 ))"
a7=$(run 200 "$(mkapi '{"total_api_duration_ms":225000}')" | strip)
case "$a7" in
  *[0-9][0-9]-[0-9][0-9]\ 3m45s*) echo "  ★ FAIL API7 elapsed-span primary got a date prefix: [$a7]"; fail=1 ;;
  *"3m45s (1D2H)"*|*"3m45s (1D3H)"*) echo "  API7 cross-day api primary: no date prefix, elapsed Δ kept OK" ;;
  *) echo "  ★ FAIL API7 expected bare 3m45s with (1D2H) Δ: [$a7]"; fail=1 ;;
esac
# API8-API10 string-typed cost fields. CC sends numbers, but jq's tostring erases the type, so a string-typed value
# reaches the arithmetic verbatim and a leading zero would be read as octal: "0900000" aborts the expression and spills
# "value too great for base" onto the statusline (its output IS the screen), while a legal octal like "04521000" is
# worse, formatting a wrong duration with no symptom. Each case asserts exit 0, empty stderr, and the DECIMAL reading.
runapi() {   # $1=cost object → stdout in $WORK/api.out, stderr in $WORK/api.err, exit code in ARC
  printf '%s' "$(mkapi "$1")" | env COLUMNS=200 HOME="$FAKE_HOME" bash "$SL/statusline-command.sh" >"$WORK/api.out" 2>"$WORK/api.err"; ARC=$?
}
chkapi() {   # $1=label $2=expected substring in the rendered line
  local out errb; out=$(strip < "$WORK/api.out"); errb=$(wc -c < "$WORK/api.err" | tr -d ' ')
  if   [ "$ARC" -ne 0 ];   then echo "  ★ FAIL $1 exited $ARC (expected 0)"; fail=1
  elif [ "$errb" != "0" ]; then echo "  ★ FAIL $1 wrote $errb bytes to stderr: [$(cat "$WORK/api.err")]"; fail=1
  else case "$out" in *"$2"*) echo "  $1 OK" ;; *) echo "  ★ FAIL $1 expected [$2]: [$out]"; fail=1 ;; esac; fi
}
rm -f "$LMF"                                                   # bare primary, no Δ noise
# API8 api time as a leading-zero string → decimal 900000ms = 900s → 15m0s (octal would abort the expression)
runapi '{"total_api_duration_ms":"0900000"}'; chkapi API8 "15m0s"
# API9 junk api time → falls through to the session-duration primary, still silently
runapi '{"total_duration_ms":4521000,"total_api_duration_ms":"12a"}'; chkapi API9 "1H15m"
# API10 the level-2 field carries the leading zero → decimal 4521000ms = 1H15m (octal 04521000 would render 20m)
runapi '{"total_duration_ms":"04521000"}'; chkapi API10 "1H15m"
printf '06-07 19:38\n' > "$LMF"   # restore baseline

echo "── W. TOKENS: cumulative in+out, subagent ⊂ only when >0, foreground reads cache (never blocks)"
# Seed the token cache with the transcript's REAL size/mtime so the detached bg job hits its gate (sources unchanged →
# no recompute) and the seeded token VALUES are preserved; this makes the assertions deterministic despite the bg job.
TKC="$FAKE_HOME/.claude/sl-tokens-cache"
TSZ=$(stat -f '%z' "$TP" 2>/dev/null); TMT=$(stat -f '%m' "$TP" 2>/dev/null)
printf 'T sl-selftest 562000 0 %s %s 0 0\n' "$TSZ" "$TMT" > "$TKC"      # W1: session-only → 562k, no ⊂
w1=$(run 200 "$J" | nocol)
case "$w1" in *"⊂"*) echo "  ★ FAIL W1 ⊂ shown with zero subagent: [$w1]"; fail=1 ;;
  *"562k"*) echo "  W1 session-only 562k, no ⊂ OK" ;; *) echo "  ★ FAIL W1 expected 562k: [$w1]"; fail=1 ;; esac
printf 'T sl-selftest 562000 1100000 %s %s 0 0\n' "$TSZ" "$TMT" > "$TKC"  # W2: subagent>0 → 562k ⊂1.1M
w2=$(run 200 "$J" | nocol)
case "$w2" in *"562k"*"⊂1.1M"*) echo "  W2 session 562k + subagent ⊂1.1M OK" ;; *) echo "  ★ FAIL W2 expected 562k ⊂1.1M: [$w2]"; fail=1 ;; esac
printf 'T sl-selftest 950 0 %s %s 0 0\n' "$TSZ" "$TMT" > "$TKC"           # W3: fmt_tok sub-1000 raw
w3=$(run 200 "$J" | nocol)
case "$w3" in *"950"*) echo "  W3 sub-1000 raw count OK" ;; *) echo "  ★ FAIL W3 expected raw 950: [$w3]"; fail=1 ;; esac
rm -f "$TKC"                                                              # W4: no cache → token segment omitted, frame still one line
chk check max $((200-1)) < <(run 200 "$J")
# W5: input-sanitization "A traversal transcript_path disables dependent reads", the token half (EFF-32 is the effort half).
# A transcript_path holding ".." is blanked, so the detached re-sum never reads it and no cache line appears for that sid.
# W5a is the control: the same file under its clean path IS summed within the same wait, so a missing W5 line means
# "never read", not "not written yet". The wait is the PEER-9 idiom: a detached job is a fork of the frame's own bash.
WTD="$WORK/wtok"; mkdir -p "$WTD/sub"   # sub/ must exist for sub/../s.jsonl to resolve to a real file
printf '{"message":{"id":"m1","usage":{"input_tokens":700,"output_tokens":34}}}\n' > "$WTD/s.jsonl"
wtoksettle() { local n=0; while [ "$n" -lt 20 ] && pgrep -f "$SL/statusline-command.sh" >/dev/null 2>&1; do sleep 0.1; n=$((n+1)); done; }
wtokframe() {  # $1=session_id $2=transcript_path → one frame; returns once any token job it started has finished (<=2s)
  run 200 "$(printf '%s' "$J" | jq -c --arg s "$1" --arg t "$2" '.session_id=$s | .transcript_path=$t')" >/dev/null
  wtoksettle
}
wtokline() { awk -v s="$1" '$1=="T" && $2==s' "$TKC" 2>/dev/null; }   # $1=sid → its cache line, empty when none
wtoksettle   # W4's frame started a job on the same cache lock; a job still holding it would make W5a's job skip
wtokframe sl-tokok "$WTD/s.jsonl"
case "$(wtokline sl-tokok)" in
  "T sl-tokok 734 "*) echo "  W5a clean transcript_path summed → 734 OK" ;;
  *) echo "  ★ FAIL W5a control: the clean path was not summed: [$(wtokline sl-tokok)]"; fail=1 ;;
esac
wtokframe sl-toktrav "$WTD/sub/../s.jsonl"
case "$(wtokline sl-toktrav)" in
  "") echo "  W5 traversal transcript_path never read for tokens OK" ;;
  *) echo "  ★ FAIL W5 a traversal transcript_path was summed: [$(wtokline sl-toktrav)]"; fail=1 ;;
esac
rm -f "$TKC" "$TKC".* 2>/dev/null; rm -rf "$TKC".lock 2>/dev/null

echo "── V. parse_input positional contract: each field lands in its own global (sentinel)"
# Source collect.sh and feed a JSON where every field carries a distinct value; assert each global got its own.
# A jq-array / read-block misalignment (the codebase's most fragile spot) makes one field's value land in another → caught here.
VFEED=$(jq -cn '{
  workspace:{current_dir:"S_cwd", project_dir:"S_proj"},
  model:{display_name:"S_model"}, session_name:"S_sname",
  context_window:{used_percentage:"S_used", exceeds_200k_tokens:true, context_window_size:"S_win",
                  current_usage:{input_tokens:"S_in", cache_creation_input_tokens:"S_cc",
                                 cache_read_input_tokens:"S_cr", output_tokens:"S_out"}}, worktree:{name:"S_wt"},
  effort:{level:"S_effort"}, thinking:{enabled:false},
  rate_limits:{ five_hour:{used_percentage:"S_5h", resets_at:"S_5r"},
                seven_day:{used_percentage:"S_7d", resets_at:"S_7r"} },
  session_id:"S_sid", transcript_path:"S_tp", cost:{total_duration_ms:4521000, total_api_duration_ms:987654} }')
if printf '%s' "$VFEED" | ( . "$SL/lib/collect.sh"; parse_input
   rc=0
   chkv() { [ "$2" = "$3" ] || { echo "  ★ FAIL $1=[$2] expected [$3]"; rc=1; }; }
   chkv cwd "$cwd" S_cwd;                 chkv project_dir "$project_dir" S_proj
   chkv model "$model" S_model;           chkv session_name "$session_name" S_sname
   chkv used_pct "$used_pct" S_used;      chkv worktree_name "$worktree_name" S_wt
   chkv effort "$effort" S_effort;        chkv thinking "$thinking" false
   chkv five_h "$five_h" S_5h;            chkv seven_d "$seven_d" S_7d
   chkv five_reset "$five_reset" S_5r;    chkv seven_reset "$seven_reset" S_7r
   chkv session_id "$session_id" S_sid;   chkv transcript_path "$transcript_path" S_tp
   chkv exceeds_200k "$exceeds_200k" true; chkv dur_ms "$dur_ms" 4521000
   chkv api_ms "$api_ms" 987654
   chkv ctx_in_tok "$ctx_in_tok" S_in;    chkv ctx_cc_tok "$ctx_cc_tok" S_cc
   chkv ctx_cr_tok "$ctx_cr_tok" S_cr;    chkv ctx_out_tok "$ctx_out_tok" S_out
   chkv ctx_win_size "$ctx_win_size" S_win
   case "$now" in ''|*[!0-9]*) echo "  ★ FAIL now not numeric: [$now]"; rc=1 ;; esac
   exit $rc ); then echo "  all 23 fields land in their own global OK"; else fail=1; fi

echo "── CTX. CONTEXT-METER: budget-aware red threshold (1M model not red at 85%, 200k model is) + decoupled 200k cliff marker ⚑"
# mkctx: build a statusline JSON with controllable model / used% / exceeds_200k. Width is roomy (no degrade) so the ctx% renders full.
# ctxpcode extracts the SGR colour code on the segment IMMEDIATELY preceding "N%" — that is ctx_color, so we can assert red-or-not
# without hardcoding the theme's exact red triple. RD (tokyo-night-claude) = 38;2;247;118;142 ; WH = 38;2;222;214;202.
mkctx() {  # $1=model display_name $2=used% $3=exceeds(true|false|omit)
  if [ "$3" = "omit" ]; then
    jq -cn --arg cwd "$SL" --arg m "$1" --argjson up "$2" --arg tp "$TP" \
      '{workspace:{current_dir:$cwd, project_dir:$cwd}, model:{display_name:$m}, context_window:{used_percentage:$up}, session_id:"sl-selftest", transcript_path:$tp}'
  else
    jq -cn --arg cwd "$SL" --arg m "$1" --argjson up "$2" --argjson ex "$3" --arg tp "$TP" \
      '{workspace:{current_dir:$cwd, project_dir:$cwd}, model:{display_name:$m}, context_window:{used_percentage:$up, exceeds_200k_tokens:$ex}, session_id:"sl-selftest", transcript_path:$tp}'
  fi
}
# ctxpcode: the SGR code that colours the "N%" token — grab the code from the last "\e[<code>mNN%" match. That is ctx_color.
ctxpcode() { perl -ne 'while(/\x1b\[([0-9;]*)m([0-9]+)%/g){$c=$1} END{print $c}'; }
# Derive the palette's red/normal ctx codes EMPIRICALLY (theme-agnostic): a 200k model far over threshold is guaranteed red,
# a 1M model far under threshold is guaranteed normal. No colour triple is hardcoded — the asserts track the live palette.
RDCODE=$(run 200 "$(mkctx 'Sonnet 4.6' 99 omit)" | ctxpcode)             # guaranteed-red reference (200k @99%)
NMCODE=$(run 200 "$(mkctx 'Opus 4.8 (1M context)' 10 omit)" | ctxpcode)  # guaranteed-normal reference (1M @10%)
if [ -n "$RDCODE" ] && [ -n "$NMCODE" ] && [ "$RDCODE" != "$NMCODE" ]; then echo "  CTX0 red/normal ctx colours derived OK"
else echo "  ★ FAIL CTX0 could not derive distinct red/normal colours (red=[$RDCODE] normal=[$NMCODE])"; fail=1; fi

echo "── M1-M7. 1M detection follows context_window_size, with display-name fallback and unchanged compact form"
# mk1m: one-line statusline JSON with independently controlled model and reported window. The window is deliberately
# string-typed so the render gate sees the same hostile shapes jq's tostring preserves; "omit" leaves the field absent.
# Existing mkctx/mkctxa signatures remain unchanged because their CTX fixtures exercise separate contracts.
mk1m() {  # $1=model display_name $2=context_window_size (or omit) $3=used_percentage
  jq -cn --arg m "$1" --arg win "$2" --arg up "$3" '
    { workspace:{current_dir:"/private/tmp"}, model:{display_name:$m},
      context_window: ({used_percentage:($up|tonumber)}
        + (if $win == "omit" then {} else {context_window_size:$win} end)) }'
}

m1=$(run 200 "$(mk1m 'Opus 5' 1000000 85)" | nocol)
case "$m1" in
  *"Opus 5(1M)"*) case "$m1" in *"Opus 5 (1M)"*) echo "  ★ FAIL M1 appended marker has a separating space: [$m1]"; fail=1 ;;
                     *) echo "  M1 reported 1000000 appends Opus 5(1M) with no space OK" ;; esac ;;
  *) echo "  ★ FAIL M1 missing appended marker: [$m1]"; fail=1 ;;
esac
m2=$(run 200 "$(mk1m 'Sonnet 5' 200000 85)" | nocol)
case "$m2" in *"Sonnet 5"*) case "$m2" in *"(1M)"*) echo "  ★ FAIL M2 standard window gained marker: [$m2]"; fail=1 ;;
                                      *) echo "  M2 reported 200000 leaves Sonnet 5 unmarked OK" ;; esac ;;
  *) echo "  ★ FAIL M2 model missing: [$m2]"; fail=1 ;;
esac
m3=$(run 200 "$(mk1m 'Opus 4.8 (1M context)' 1000000 85)" | nocol)
case "$m3" in *"Opus 4.8(1M)"*) case "$m3" in *"(1M)(1M)"*) echo "  ★ FAIL M3 duplicate marker: [$m3]"; fail=1 ;;
                                             *) echo "  M3 announced + reported extended window yields one marker OK" ;; esac ;;
  *) echo "  ★ FAIL M3 legacy rewrite missing: [$m3]"; fail=1 ;;
esac
m4=$(run 200 "$(mk1m 'Opus 4.8 (1M context)' omit 85)" | nocol)
case "$m4" in *"Opus 4.8(1M)"*) echo "  M4 absent size falls back to announced 1M name OK" ;;
  *) echo "  ★ FAIL M4 display-name fallback missing: [$m4]"; fail=1 ;;
esac
m5=$(run 200 "$(mk1m 'Sonnet 5' omit 85)" | nocol)
case "$m5" in *"Sonnet 5"*) case "$m5" in *"(1M)"*) echo "  ★ FAIL M5 absent size invented marker: [$m5]"; fail=1 ;;
                                      *) echo "  M5 absent size + silent name remains unmarked OK" ;; esac ;;
  *) echo "  ★ FAIL M5 model missing: [$m5]"; fail=1 ;;
esac
m6=$(run 22 "$(mk1m 'Opus 5' 1000000 85)" | nocol)
case "$m6" in *"Opus"*) case "$m6" in *"Opus 5(1M)"*) echo "  ★ FAIL M6 full model survived compact tier: [$m6]"; fail=1 ;;
                                  *) echo "  M6 compact form stays the raw leading word Opus OK" ;; esac ;;
  *) echo "  ★ FAIL M6 compact model missing: [$m6]"; fail=1 ;;
esac
m7e=$(run 200 "$(mk1m 'Opus 5' 1000000 85)" | ctxpcode)
m7s=$(run 200 "$(mk1m 'Sonnet 5' 200000 85)" | ctxpcode)
if [ "$m7e" = "$NMCODE" ] && [ "$m7s" = "$RDCODE" ] && [ "$m7e" != "$m7s" ]; then
  echo "  M7 reported window drives 92/80 threshold at identical 85% OK"
else
  echo "  ★ FAIL M7 threshold did not follow size (1M=[$m7e] normal=[$NMCODE] 200k=[$m7s] red=[$RDCODE])"; fail=1
fi

# Predicate robustness: every unusable size falls back without arithmetic diagnostics; a leading-zero decimal remains usable.
m8bad=0
for spec in 'nonnumeric|abc|Opus 4.8 (1M context)|Opus 4.8(1M)' 'leading-zero|01000000|Opus 5|Opus 5(1M)' '40-digit|9999999999999999999999999999999999999999|Sonnet 5|Sonnet 5'; do
  label=${spec%%|*}; rest=${spec#*|}; win=${rest%%|*}; rest=${rest#*|}; m8model=${rest%%|*}; want=${rest#*|}
  printf '%s' "$(mk1m "$m8model" "$win" 85)" | env COLUMNS=200 HOME="$FAKE_HOME" bash "$SL/statusline-command.sh" >"$WORK/m8.out" 2>"$WORK/m8.err"; m8rc=$?
  m8plain=$(nocol < "$WORK/m8.out"); m8lines=$(grep -c '' "$WORK/m8.out"); m8err=$(wc -c < "$WORK/m8.err" | tr -d ' ')
  [ "$m8rc" -eq 0 ] || { echo "  ★ FAIL M8 $label exited $m8rc"; m8bad=1; }
  [ "$m8lines" -eq 1 ] || { echo "  ★ FAIL M8 $label emitted $m8lines lines"; m8bad=1; }
  [ "$m8err" = 0 ] || { echo "  ★ FAIL M8 $label wrote $m8err stderr bytes: [$(cat "$WORK/m8.err")]"; m8bad=1; }
  case "$m8plain" in *"$want"*) ;; *) echo "  ★ FAIL M8 $label fallback/decimal result missing [$want]: [$m8plain]"; m8bad=1 ;; esac
done
[ "$m8bad" -eq 0 ] && echo "  M8 nonnumeric/leading-zero/40-digit frames: one line, stderr clean, correct fallback OK" || fail=1

# CTX1 1M model at 85% → NOT red (the spec worked example)
c1=$(run 200 "$(mkctx 'Opus 4.8 (1M context)' 85 omit)" | ctxpcode)
if [ "$c1" != "$RDCODE" ]; then echo "  CTX1 1M @85% ctx% NOT red OK"; else echo "  ★ FAIL CTX1 1M @85% wrongly red ([$c1] == RD)"; fail=1; fi
# CTX2 200k model (no 1M marker) at 85% → red
c2=$(run 200 "$(mkctx 'Sonnet 4.6' 85 omit)" | ctxpcode)
if [ "$c2" = "$RDCODE" ]; then echo "  CTX2 200k @85% ctx% red OK"; else echo "  ★ FAIL CTX2 200k @85% not red ([$c2] != RD [$RDCODE])"; fail=1; fi
# CTX3 threshold is budget-driven, not a constant: identical 85% differs in colour only by the 1M marker (CTX1 vs CTX2)
if [ "$c1" != "$c2" ]; then echo "  CTX3 budget-driven threshold (1M≠200k at same 85%) OK"; else echo "  ★ FAIL CTX3 1M and 200k coloured identically at 85% ([$c1]=[$c2])"; fail=1; fi
# CTX4 over-200k indicator TRUE at 70% on a 1M model → cliff ⚑ present, % still normal (decoupled)
c4out=$(run 200 "$(mkctx 'Opus 4.8 (1M context)' 70 true)"); c4=$(printf '%s' "$c4out" | ctxpcode)
case "$c4out" in *"⚑"*) if [ "$c4" != "$RDCODE" ]; then echo "  CTX4 ⚑ shown + % normal (decoupled) OK"; else echo "  ★ FAIL CTX4 % unexpectedly red"; fail=1; fi ;;
  *) echo "  ★ FAIL CTX4 ⚑ cliff marker missing when exceeds_200k=true"; fail=1 ;; esac
# CTX5 over-200k indicator FALSE at 95% → NO ⚑ even at high %
c5out=$(run 200 "$(mkctx 'Opus 4.8 (1M context)' 95 false)")
case "$c5out" in *"⚑"*) echo "  ★ FAIL CTX5 ⚑ shown when exceeds_200k=false: present"; fail=1 ;; *) echo "  CTX5 no ⚑ when exceeds_200k=false OK" ;; esac
# CTX6 absent indicator → no ⚑ (default off)
c6out=$(run 200 "$(mkctx 'Opus 4.8 (1M context)' 95 omit)")
case "$c6out" in *"⚑"*) echo "  ★ FAIL CTX6 ⚑ shown when indicator absent"; fail=1 ;; *) echo "  CTX6 no ⚑ when indicator absent OK" ;; esac
# CTX7 decoupled matrix: 200k @85% true → BOTH red % AND ⚑ (coloring and marker independent)
c7out=$(run 200 "$(mkctx 'Sonnet 4.6' 85 true)"); c7=$(printf '%s' "$c7out" | ctxpcode)
if [ "$c7" = "$RDCODE" ]; then case "$c7out" in *"⚑"*) echo "  CTX7 200k @85% true → red % + ⚑ (both independent) OK" ;;
  *) echo "  ★ FAIL CTX7 ⚑ missing"; fail=1 ;; esac
else echo "  ★ FAIL CTX7 % not red ([$c7])"; fail=1; fi

# CTX8-CTX14: warning-aligned percentage source. The displayed % is computed locally on Claude Code's
# "Context low (N% remaining)" basis instead of echoing the upstream used_percentage: T = the four current_usage token
# counts summed, P = context_window_size - CTX_RESERVE, R = round-half-up(100*(P-T)/P) with (P-T) clamped at 0, and the
# displayed N = 100 - R. So the statusline number and the warning's remaining number always add up to 100.
mkctxa() {  # $1=model $2=input $3=cache_creation $4=cache_read $5=output $6=context_window_size $7=used% ("omit") $8=exceeds ("omit")
  jq -cn --arg cwd "$SL" --arg m "$1" --argjson i "$2" --argjson cc "$3" --argjson cr "$4" --argjson o "$5" \
     --arg win "$6" --arg up "$7" --arg ex "$8" --arg tp "$TP" '
    { workspace:{current_dir:$cwd, project_dir:$cwd}, model:{display_name:$m},
      context_window: ( {current_usage:{input_tokens:$i, cache_creation_input_tokens:$cc, cache_read_input_tokens:$cr, output_tokens:$o}}
        + (if $win == "omit" then {} else {context_window_size:($win|tonumber)} end)
        + (if $up  == "omit" then {} else {used_percentage:($up|tonumber)} end)
        + (if $ex  == "omit" then {} else {exceeds_200k_tokens:($ex == "true")} end) ),
      session_id:"sl-selftest", transcript_path:$tp }'
}
# ctxpct: the percentage NUMBER the ctx segment displays (last "\e[<code>m[ctx:]NN%" match — these frames carry no rate
# segment, so the only percentage on the line is the ctx one). Empty when the segment is suppressed.
ctxpct() { perl -ne 'while(/\x1b\[[0-9;]*m(?:ctx:)?([0-9]+)%/g){$p=$1} END{print $p}'; }
# CTX8 aligned basis, the design's anchor frame: T=960400, window=1000000 → P=980000, R=round(100*19600/980000)=2 → 98
p8=$(run 200 "$(mkctxa 'Opus 4.8 (1M context)' 400000 60000 500000 400 1000000 omit omit)" | ctxpct)
case "$p8" in 98) echo "  CTX8 aligned basis (T=960400, win=1M) → 98% OK" ;; *) echo "  ★ FAIL CTX8 expected 98 got [$p8]"; fail=1 ;; esac
# CTX9 priority: the same frame ALSO carrying used_percentage 96 still shows 98 — the aligned value beats the upstream one
p9=$(run 200 "$(mkctxa 'Opus 4.8 (1M context)' 400000 60000 500000 400 1000000 96 omit)" | ctxpct)
case "$p9" in 98) echo "  CTX9 aligned value wins over upstream used_percentage 96 OK" ;; *) echo "  ★ FAIL CTX9 expected 98 got [$p9]"; fail=1 ;; esac
# CTX10 saturation: T=985000 exceeds P=980000 → (P-T) clamps to 0, R=0 → 100 (never a negative remaining)
p10=$(run 200 "$(mkctxa 'Opus 4.8 (1M context)' 500000 85000 400000 0 1000000 omit omit)" | ctxpct)
case "$p10" in 100) echo "  CTX10 usage past the reserve boundary clamps to 100% OK" ;; *) echo "  ★ FAIL CTX10 expected 100 got [$p10]"; fail=1 ;; esac
# CTX11 window not ABOVE the reserve (exactly 20000) → the aligned computation must not run; used_percentage 96 shows through
p11=$(run 200 "$(mkctxa 'Opus 4.8 (1M context)' 400000 60000 500000 400 20000 96 omit)" | ctxpct)
case "$p11" in 96) echo "  CTX11 window not above the reserve falls back to used_percentage 96 OK" ;; *) echo "  ★ FAIL CTX11 expected 96 got [$p11]"; fail=1 ;; esac
# CTX14 half-up boundary: T=955500 → exact remaining 100*24500/980000 = 2.5 → R rounds up to 3 → N=97. An independently
# rounded used% (97.5 → 98) would break the complement, which is why N is defined as 100 - R.
p14=$(run 200 "$(mkctxa 'Opus 4.8 (1M context)' 500000 55000 400000 500 1000000 omit omit)" | ctxpct)
case "$p14" in 97) echo "  CTX14 .5 remaining rounds half-up (R=3 → 97%) OK" ;; *) echo "  ★ FAIL CTX14 expected 97 got [$p14]"; fail=1 ;; esac
# CTX12 legacy frame (used_percentage only, no current_usage): the ctx segment must stay byte-identical to the pre-change
# output. CTX12_EXPECT was CAPTURED from the real pre-change script, not hand-written:
#   printf '{"workspace":{"current_dir":"'"$PWD"'"},"model":{"display_name":"Opus 4.8 (1M context)"},
#            "context_window":{"used_percentage":96},"session_id":"sl-selftest"}' | COLUMNS=200 bash statusline-command.sh
# (captured 2026-08-14 with the default STYLE=tokyo-night-claude; re-capture with that command if the default palette changes).
# ctxseg: the COMPLETE ctx segment, from the bar/percentage start up to the segment boundary (the " │ " separator, a
# >=2-space gap, or end of line). It deliberately does NOT stop at the % or the ⚑: anything trailing inside the segment
# (a duplicated marker, an unreset SGR, stray bytes) lands INSIDE the compared string instead of being cropped away.
ctxseg() { perl -0777 -ne 'chomp; print $1 if /(((?:\x1b\[48;2;[0-9;]+m )+\x1b\[0m )?\x1b\[[0-9;]+m(?:ctx:)?\d+%.*?)(?:\x1b\[[0-9;]+m │ \x1b\[0m|  |$)/s'; }
CTX12_EXPECT=$'\033[48;2;158;206;106m \033[48;2;158;206;106m \033[48;2;158;206;106m \033[48;2;224;175;104m \033[48;2;224;175;104m \033[48;2;224;175;104m \033[48;2;255;158;100m \033[48;2;255;158;100m \033[48;2;255;158;100m \033[48;2;247;118;142m \033[48;2;247;118;142m \033[48;2;41;46;66m \033[0m \033[38;2;247;118;142m96%\033[0m'
s12=$(run 200 "$(mkctx 'Opus 4.8 (1M context)' 96 omit)" | ctxseg)
if [ "$s12" = "$CTX12_EXPECT" ]; then echo "  CTX12 legacy used_percentage-only frame byte-identical to the pre-change capture (full segment, suffix included) OK"
else echo "  ★ FAIL CTX12 ctx segment differs from the pre-change capture: [$(printf '%s' "$s12" | cat -v)]"; fail=1; fi
# CTX13 neither source numeric → the WHOLE segment is suppressed, cliff marker included. exceeds_200k is true here on
# purpose: the ⚑ has no percentage to ride on, so it must not be emitted either.
c13out=$(run 200 "$(jq -cn --arg cwd "$SL" --arg tp "$TP" \
  '{workspace:{current_dir:$cwd, project_dir:$cwd}, model:{display_name:"Opus 4.8 (1M context)"},
    context_window:{exceeds_200k_tokens:true}, session_id:"sl-selftest", transcript_path:$tp}')")
p13=$(printf '%s' "$c13out" | ctxpct)
case "$c13out" in
  *"⚑"*) echo "  ★ FAIL CTX13 ⚑ emitted with no numeric percentage to host it"; fail=1 ;;
  *) case "$p13" in '') echo "  CTX13 neither source numeric → whole ctx segment (and ⚑) suppressed OK" ;;
       *) echo "  ★ FAIL CTX13 percentage [$p13] rendered with no numeric source"; fail=1 ;; esac ;;
esac
# CTX15-CTX17 CTX_BAR knob on the aligned percentage: one fixed frame (aligned 98%, over-200k true) rendered by both builds.
# The knob selects between the two FULL forms only — it must not touch the bare compact form or the cliff marker.
mkdir -p "$WORK/nobar/lib" && cp "$SL"/lib/*.sh "$WORK/nobar/lib/"
sed 's/^CTX_BAR=true/CTX_BAR=false/' "$SL/statusline-command.sh" > "$WORK/nobar/statusline-command.sh"
runnobar() { printf '%s' "$2" | env COLUMNS="$1" HOME="$FAKE_HOME" bash "$WORK/nobar/statusline-command.sh"; }
barcells() { perl -0777 -ne '$n=()=/\x1b\[48;2;[0-9;]+m /g; print $n'; }   # count of background-painted bar cells
KNOBF=$(mkctxa 'Opus 4.8 (1M context)' 400000 60000 500000 400 1000000 omit true)
k15=$(run 200 "$KNOBF" | ctxseg); n15=$(printf '%s' "$k15" | barcells)
case "$n15:$(printf '%s' "$k15" | ctxpct):$k15" in
  12:98:*"⚑"*) echo "  CTX15 CTX_BAR=true full form = 12-cell bar + aligned 98% + ⚑ OK" ;;
  *) echo "  ★ FAIL CTX15 expected 12 cells/98%/⚑, got cells=[$n15] pct=[$(printf '%s' "$k15" | ctxpct)]"; fail=1 ;; esac
k16=$(runnobar 200 "$KNOBF" | ctxseg); n16=$(printf '%s' "$k16" | barcells)
case "$k16" in
  *"ctx:98%"*"⚑"*) case "$n16" in 0) echo "  CTX16 CTX_BAR=false full form = ctx:98% text, no bar, ⚑ kept OK" ;;
                     *) echo "  ★ FAIL CTX16 bar cells present with CTX_BAR=false: [$n16]"; fail=1 ;; esac ;;
  *) echo "  ★ FAIL CTX16 expected ctx:98% + ⚑, got [$(printf '%s' "$k16" | cat -v)]"; fail=1 ;; esac
# CTX17 compact form: at a width that forces degrade step 4 the bare N% is byte-identical under both knob settings, ⚑ included
k17a=$(run 45 "$KNOBF" | ctxseg); k17b=$(runnobar 45 "$KNOBF" | ctxseg); n17=$(printf '%s' "$k17a" | barcells)
if [ "$k17a" = "$k17b" ]; then
  case "$k17a" in *"ctx:"*) echo "  ★ FAIL CTX17 compact form carries the ctx: label"; fail=1 ;;
    *"98%"*"⚑"*) case "$n17" in 0) echo "  CTX17 bare 98%+⚑ compact form identical under both CTX_BAR settings, no bar cells OK" ;;
                   *) echo "  ★ FAIL CTX17 compact form still paints $n17 bar cells"; fail=1 ;; esac ;;
    *) echo "  ★ FAIL CTX17 compact form is not the bare 98%+⚑: [$(printf '%s' "$k17a" | cat -v)]"; fail=1 ;; esac
else echo "  ★ FAIL CTX17 compact form differs by knob: [$(printf '%s' "$k17a" | cat -v)] vs [$(printf '%s' "$k17b" | cat -v)]"; fail=1; fi

# CTX18-CTX22 hostile counter values. jq's tostring erases the JSON type, so a STRING-typed counter reaches the
# arithmetic verbatim — these frames send exactly that shape. Every case must exit 0 and keep stderr empty, because the
# statusline's output IS the screen: an arithmetic error message there is itself the bug.
mkctxh() {  # $1..$4 = the four current_usage counters, $5 = context_window_size (all JSON strings), $6 = used% ("omit")
  jq -cn --arg cwd "$SL" --arg i "$1" --arg cc "$2" --arg cr "$3" --arg o "$4" --arg win "$5" --arg up "$6" --arg tp "$TP" '
    { workspace:{current_dir:$cwd, project_dir:$cwd}, model:{display_name:"Opus 4.8 (1M context)"},
      context_window: ( {current_usage:{input_tokens:$i, cache_creation_input_tokens:$cc, cache_read_input_tokens:$cr, output_tokens:$o},
                         context_window_size:$win}
        + (if $up == "omit" then {} else {used_percentage:($up|tonumber)} end) ),
      session_id:"sl-selftest", transcript_path:$tp }'
}
runh() {   # $1=COLUMNS $2=json → stdout in $WORK/h.out, stderr in $WORK/h.err, exit code in HRC
  printf '%s' "$2" | env COLUMNS="$1" HOME="$FAKE_HOME" bash "$SL/statusline-command.sh" >"$WORK/h.out" 2>"$WORK/h.err"; HRC=$?
}
chkh() {   # $1=label $2=expected displayed % → assert exit 0 + empty stderr + that percentage
  local got errb; got=$(ctxpct < "$WORK/h.out"); errb=$(wc -c < "$WORK/h.err" | tr -d ' ')
  if   [ "$HRC" -ne 0 ];    then echo "  ★ FAIL $1 exited $HRC (expected 0)"; fail=1
  elif [ "$errb" != "0" ];  then echo "  ★ FAIL $1 wrote $errb bytes to stderr: [$(cat "$WORK/h.err")]"; fail=1
  elif [ "$got" != "$2" ];  then echo "  ★ FAIL $1 expected $2% got [$got]"; fail=1
  else echo "  $1 OK"; fi
}
# CTX18 leading zero "08": bash reads a leading zero as octal, and "08" is not even a legal octal literal — unguarded it
# aborts the expression and spills "value too great for base" onto the statusline. It must count as decimal 8:
# T = 8+60000+500000+400 = 560408, P = 980000 → R = round(100*419592/980000) = 43 → 57.
runh 200 "$(mkctxh 08 60000 500000 400 1000000 omit)"; chkh CTX18 57
# CTX19 leading zero "040000": a legal octal literal, so an unguarded read is SILENT — 16384 instead of 40000 (which
# would show 53% instead of 55%). T = 40000+0+500000+0 = 540000 → R = round(100*440000/980000) = 45 → 55.
runh 200 "$(mkctxh 040000 0 500000 0 1000000 omit)"; chkh CTX19 55
# CTX20 negative counter → ineligible → the used_percentage fallback (96), not a nonsense percentage
runh 200 "$(mkctxh -5 60000 500000 400 1000000 96)"; chkh CTX20 96
# CTX21 16-digit counter (past the 15-digit cap that keeps 200*(P-T) inside 64-bit) → fallback, no wrap-around
runh 200 "$(mkctxh 1234567890123456 0 0 0 1000000 96)"; chkh CTX21 96
# CTX22 mixed alphanumeric "12a" → fallback
runh 200 "$(mkctxh 12a 60000 500000 400 1000000 96)"; chkh CTX22 96
# CTX23-CTX26 walk the leading zero across the REMAINING four operands, one per case, so that dropping the decimal
# prefix on any single one of the five is caught: CTX18/19 cover input_tokens, these cover the other three counters and
# the window. The counter cases use "08" (illegal as octal → the expression aborts and stderr is no longer empty); the
# window uses "01000000", a legal octal literal that would silently read as 262144 and show 100% instead of 98%.
runh 200 "$(mkctxh 400000 08 500000 400 1000000 omit)"; chkh CTX23 92   # cache_creation: T=900408 → R=8
runh 200 "$(mkctxh 400000 60000 08 400 1000000 omit)"; chkh CTX24 47    # cache_read:     T=460408 → R=53
runh 200 "$(mkctxh 400000 60000 500000 08 1000000 omit)"; chkh CTX25 98 # output_tokens:  T=960008 → R=2
runh 200 "$(mkctxh 400000 60000 500000 400 01000000 omit)"; chkh CTX26 98 # window: P=980000 as decimal, 242144 as octal

echo "── X. _sum_inout dedups by message.id (CC logs one row per content block, each repeating the same message usage)"
# m1 appears 3× with the same usage (10+5), m2 once (100+20); a naive per-row sum = 165, the correct dedup = 135.
# A user row (no .message.usage) must be ignored. _sum_inout reads stdin only, so HOME is irrelevant here.
xdedup=$(printf '%s\n' \
  '{"message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":5}}}' \
  '{"message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":5}}}' \
  '{"message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":5}}}' \
  '{"message":{"id":"m2","usage":{"input_tokens":100,"output_tokens":20}}}' \
  '{"type":"user","message":{"role":"user"}}' \
  | ( . "$SL/lib/collect.sh"; _sum_inout ))
case "$xdedup" in 135) echo "  X dedup by message.id → 135 (not 165) OK" ;; *) echo "  ★ FAIL X expected 135 got [$xdedup]"; fail=1 ;; esac

echo "── X2. tokens_update prunes T-lines whose main_mtime is older than RL_REG_TTL, exact-matches sid (no regex over-delete)"
# HOME=FAKE_HOME so TOKENS_CACHE resolves into the sandbox, NOT the real ~/.claude cache. 'ancient' mtime=1 → pruned;
# 'fresh' mtime=now → kept; 'xupd' has no seeded line → gate misses → the rewrite path (the code under test) runs.
NOWX=$(date +%s)
printf 'T ancient 100 0 10 1 0 0\nT fresh 200 0 10 %s 0 0\n' "$NOWX" > "$TKC"
( export HOME="$FAKE_HOME"; . "$SL/lib/collect.sh"; tokens_update "$TP" xupd "$NOWX" )
xp=$(cat "$TKC" 2>/dev/null); xok=1
case "$xp" in *"T ancient"*) echo "  ★ FAIL X2 stale 'ancient' line not pruned: [$xp]"; fail=1; xok=0 ;; esac
case "$xp" in *"T fresh "*) ;; *) echo "  ★ FAIL X2 'fresh' line wrongly dropped: [$xp]"; fail=1; xok=0 ;; esac
case "$xp" in *"T xupd "*) ;; *) echo "  ★ FAIL X2 own line not written: [$xp]"; fail=1; xok=0 ;; esac
[ "$xok" = 1 ] && echo "  X2 prune stale + keep fresh + write own line OK"
rm -f "$TKC" "$TKC".* 2>/dev/null; rm -rf "$TKC".lock 2>/dev/null

echo "── Y. BURN: rate-limit burn-projection alarm — two-point slope from persisted P samples, ↘<ttl>, yellow>30m/red≤30m, sensitivity, gates, retention"
SLC="$FAKE_HOME/.claude/sl-ratelimit-cache"
NOWB=$(jq -n 'now|floor')
# brun: seed exactly ONE old sample, then report cur_used → render (raw, colours kept). rsj pins ctx=5% + five_hour-only.
brun() {  # $1=reset_epoch $2=old_ts $3=old_used $4=cur_used $5=sid → rendered line
  printf 'P %s %s %s\n' "$1" "$2" "$3" > "$SLC"
  run 200 "$(rsj "$4" "$1" "${5:-sBurn}")"
}
brunV() { # $1=variant-dir $2=reset $3=old_ts $4=old_used $5=cur_used $6=sid → render under a BURN_SENS-overridden copy
  local vd=$1; shift
  printf 'P %s %s %s\n' "$1" "$2" "$3" > "$SLC"
  printf '%s' "$(rsj "$4" "$1" "${5:-sBurnV}")" | env COLUMNS=200 HOME="$FAKE_HOME" bash "$WORK/$vd/statusline-command.sh"
}
hasarrow() { python3 -c 'import sys; print("yes" if "↘" in sys.stdin.buffer.read().decode("utf-8","replace") else "no")'; }
bcode() { python3 -c 'import sys,re
m=re.search("\x1b\\[([0-9;]*)m↘", sys.stdin.buffer.read().decode("utf-8","replace")); print(m.group(1) if m else "")'; }
rcode() { python3 -c 'import sys,re
ms=re.findall("\x1b\\[([0-9;]*)m[0-9]+%", sys.stdin.buffer.read().decode("utf-8","replace")); print(ms[-1] if ms else "")'; }
# BURN_SENS variant scripts (mirror the F/T6 copy-and-sed pattern)
mkdir -p "$WORK/bcons/lib" && cp "$SL"/lib/*.sh "$WORK/bcons/lib/"
sed 's/^BURN_SENS="balanced"/BURN_SENS="conservative"/' "$SL/statusline-command.sh" > "$WORK/bcons/statusline-command.sh"
mkdir -p "$WORK/bsens/lib" && cp "$SL"/lib/*.sh "$WORK/bsens/lib/"
sed 's/^BURN_SENS="balanced"/BURN_SENS="sensitive"/' "$SL/statusline-command.sh" > "$WORK/bsens/statusline-command.sh"

# Y1 two-point slope → seconds-to-exhaust: used 33→58 over 1h ⇒ slope 25%/h, remaining 42% ⇒ tte=42·3600/25=6048s=1H40m (task 3.2)
y1=$(brun $((NOWB+9000)) $((NOWB-3600)) 33 58 sTTE | strip)
case "$y1" in *"↘1H40m"*|*"↘1H39m"*|*"↘1H41m"*) echo "  Y1 two-point slope → ↘1H40m (tte = remaining·Δt/Δused) OK" ;;
  *) echo "  ★ FAIL Y1 expected ↘1H40m: [$y1]"; fail=1 ;; esac

# Y2 colour thresholds + capture YREF/RREF: align the rate colour to the burn colour so we pin yellow/red without theme constants (task 3.4)
yref=$(brun $((NOWB+9000)) $((NOWB-600)) 30 40 sYel)   # cur40→rate remaining60=YELLOW; tte=60·600/10=3600s=60m (>30m)=YELLOW
rref=$(brun $((NOWB+9000)) $((NOWB-600)) 70 80 sRed)   # cur80→rate remaining20=RED;    tte=20·600/10=1200s=20m (≤30m)=RED
YREF=$(printf '%s' "$yref" | bcode); RATEY=$(printf '%s' "$yref" | rcode)
RREF=$(printf '%s' "$rref" | bcode); RATER=$(printf '%s' "$rref" | rcode)
ybad=0
[ "$(printf '%s' "$yref" | hasarrow)" = yes ] || { echo "  ★ FAIL Y2 >30m scenario hid the alarm"; ybad=1; }
[ "$(printf '%s' "$rref" | hasarrow)" = yes ] || { echo "  ★ FAIL Y2 ≤30m scenario hid the alarm"; ybad=1; }
{ [ -n "$YREF" ] && [ "$YREF" = "$RATEY" ]; } || { echo "  ★ FAIL Y2 >30m burn not yellow (burn=$YREF rate=$RATEY)"; ybad=1; }
{ [ -n "$RREF" ] && [ "$RREF" = "$RATER" ]; } || { echo "  ★ FAIL Y2 ≤30m burn not red (burn=$RREF rate=$RATER)"; ybad=1; }
[ "$YREF" != "$RREF" ] || { echo "  ★ FAIL Y2 yellow/red colour identical ($YREF)"; ybad=1; }
[ "$ybad" -eq 0 ] && echo "  Y2 >30m yellow / ≤30m red (burn colour = same-tier rate colour) OK" || fail=1

# Y3 exact 30m/31m boundary (spec example): dp large + Δt large so %d truncation absorbs ≤2s clock skew (task 3.4)
y3a=$(brun $((NOWB+9000)) $((NOWB-4200)) 0 70 s30)    # rem30, tte=30·4200/70=1800s=30m → red, text ↘30m
y3b=$(brun $((NOWB+9000)) $((NOWB-4140)) 0 69 s31)    # rem31, tte=31·4140/69=1860s=31m → yellow, text ↘31m
y3bad=0
case "$(printf '%s' "$y3a" | strip)" in *"↘30m"*) ;; *) echo "  ★ FAIL Y3 expected ↘30m: [$(printf '%s' "$y3a" | strip)]"; y3bad=1 ;; esac
case "$(printf '%s' "$y3b" | strip)" in *"↘31m"*) ;; *) echo "  ★ FAIL Y3 expected ↘31m: [$(printf '%s' "$y3b" | strip)]"; y3bad=1 ;; esac
[ "$(printf '%s' "$y3a" | bcode)" = "$RREF" ] || { echo "  ★ FAIL Y3 30m not red"; y3bad=1; }
[ "$(printf '%s' "$y3b" | bcode)" = "$YREF" ] || { echo "  ★ FAIL Y3 31m not yellow"; y3bad=1; }
[ "$y3bad" -eq 0 ] && echo "  Y3 boundary ↘30m red / ↘31m yellow OK" || fail=1

# Y4 end-to-end result matrix (balanced default), 6 rows → hidden / yellow / red (task 3.7)
mbad=0
mrow() { # $1=label $2=reset $3=old_ts $4=old_u $5=cur_u $6=want(hidden|yellow|red)
  local o a; o=$(brun "$2" "$3" "$4" "$5" "mx$1"); a=$(printf '%s' "$o" | hasarrow)
  if [ "$6" = hidden ]; then
    [ "$a" = no ] || { echo "  ★ FAIL Y4[$1] expected hidden, got [$(printf '%s' "$o" | strip)]"; mbad=1; }
  else
    [ "$a" = yes ] || { echo "  ★ FAIL Y4[$1] expected $6 shown, got hidden"; mbad=1; return; }
    local c; c=$(printf '%s' "$o" | bcode)
    if [ "$6" = yellow ]; then [ "$c" = "$YREF" ] || { echo "  ★ FAIL Y4[$1] not yellow (code=$c)"; mbad=1; }
    else [ "$c" = "$RREF" ] || { echo "  ★ FAIL Y4[$1] not red (code=$c)"; mbad=1; }; fi
  fi
}
mrow 1 $((NOWB+7800)) $((NOWB-3600))  8 10 hidden   # 90% rem, slow burn, exhaust ~45h ≫ 2H10m reset → before-reset gate fails
mrow 2 $((NOWB+1800)) $((NOWB-3600)) 40 50 hidden   # 50% rem, tte 5h ≫ 30m reset → hidden
mrow 3 $((NOWB+7200)) $((NOWB-3600)) 70 70 hidden   # flat (slope 0) → slope gate fails
mrow 4 $((NOWB+7800)) $((NOWB-3600)) 33 58 yellow   # 42% rem, tte 1H40m < reset, within balanced ceiling, >30m → yellow
mrow 5 $((NOWB+7200)) $((NOWB-600))  70 80 red      # 20% rem, tte 20m ≤30m → red
mrow 6 $((NOWB+7200)) $((NOWB-60))    6 10 red      # 90% rem but bursting, tte ~22m ≤30m → red
[ "$mbad" -eq 0 ] && echo "  Y4 end-to-end matrix (hidden×3 / yellow / red×2) OK" || fail=1

# Y5 configurable sensitivity knob: same projection, three levels differ (task 3.6)
sbad=0
c60=$(brunV bcons $((NOWB+9000))  $((NOWB-600))  30 40 | hasarrow)   # 60m: conservative (≤30m) → hidden
b60=$(brun        $((NOWB+9000))  $((NOWB-600))  30 40 | hasarrow)   # 60m: balanced default → shown
s60=$(brunV bsens $((NOWB+9000))  $((NOWB-600))  30 40 | hasarrow)   # 60m: sensitive → shown
b120=$(brun        $((NOWB+14400)) $((NOWB-1200)) 30 40 | hasarrow)  # 120m: balanced (>~90m+) → hidden
s120=$(brunV bsens $((NOWB+14400)) $((NOWB-1200)) 30 40 | hasarrow)  # 120m: sensitive (before reset) → shown
c25=$(brunV bcons $((NOWB+9000))  $((NOWB-750))  70 80 | hasarrow)   # 25m: conservative (≤30m) → shown
[ "$c60" = no ]  || { echo "  ★ FAIL Y5 conservative 60m should hide"; sbad=1; }
[ "$b60" = yes ] || { echo "  ★ FAIL Y5 balanced 60m should show"; sbad=1; }
[ "$s60" = yes ] || { echo "  ★ FAIL Y5 sensitive 60m should show"; sbad=1; }
[ "$b120" = no ] || { echo "  ★ FAIL Y5 balanced 120m should hide"; sbad=1; }
[ "$s120" = yes ] || { echo "  ★ FAIL Y5 sensitive 120m should show"; sbad=1; }
[ "$c25" = yes ] || { echo "  ★ FAIL Y5 conservative 25m should show"; sbad=1; }
[ "$sbad" -eq 0 ] && echo "  Y5 conservative/balanced/sensitive gate the same projection differently OK" || fail=1

# Y6 depletion-only direction: a rising remaining budget (slope<0) emits no glyph at all (task 3.5)
case "$(brun $((NOWB+9000)) $((NOWB-1800)) 50 40 sDep | strip)" in
  *↘*|*↗*) echo "  ★ FAIL Y6 falling/rising emitted an indicator"; fail=1 ;;
  *) echo "  Y6 rising remaining (slope<0) → no ↘/↗ glyph OK" ;;
esac

# Y7 insufficient samples: only the current frame's own sample (no seed) → <2 in-horizon → no slope, no alarm (task 3.2)
rm -f "$SLC"
case "$(run 200 "$(rsj 58 "$((NOWB+9000))" sOne)" | strip)" in
  *↘*) echo "  ★ FAIL Y7 single sample produced an alarm"; fail=1 ;;
  *) echo "  Y7 <2 in-horizon samples → no alarm OK" ;; esac

# Y8 bounded retention: 9 frames each append one sample → window capped at 5 P-lines (task 3.1)
rm -f "$SLC"; RB=$((NOWB+9000))
for i in 1 2 3 4 5 6 7 8 9; do run 200 "$(rsj $((10+i)) "$RB" sRet)" >/dev/null; done
pc=$(grep -c "^P $RB " "$SLC" 2>/dev/null); pc=${pc:-0}
[ "$pc" -eq 5 ] && echo "  Y8 9 frames → series bounded to 5 samples/window OK" || { echo "  ★ FAIL Y8 expected 5 P-lines, got $pc"; fail=1; }

# Y9 expired-window pruning: a sample whose resets_at ≤ now is dropped on rewrite; the live window's sample survives (task 3.1)
PASTR=$((NOWB-100)); RL=$((NOWB+9000))
printf 'P %s %s 50\nP %s %s 60\n' "$PASTR" "$((NOWB-200))" "$RL" "$((NOWB-50))" > "$SLC"
run 200 "$(rsj 30 "$RL" sPrune)" >/dev/null
c9=$(cat "$SLC" 2>/dev/null); y9bad=0
case "$c9" in *"P $PASTR "*) echo "  ★ FAIL Y9 expired-window sample not pruned: [$c9]"; y9bad=1 ;; esac
case "$c9" in *"P $RL "*) ;; *) echo "  ★ FAIL Y9 live-window sample wrongly dropped: [$c9]"; y9bad=1 ;; esac
[ "$y9bad" -eq 0 ] && echo "  Y9 expired-window samples pruned, live kept OK" || fail=1

# Y10 sampled quantity is the freshest-observation authority, not the stale session report (task 3.1)
RA=$((NOWB+9000)); OLDA=$((NOWB-5000)); RECA=$((NOWB-100))
printf "S sRec %s %s 75 %s - - -\nS $(sidof sOldF) %s %s 40 %s - - -\nW5 %s 75 %s\n" "$RECA" "$RA" "$RECA" "$OLDA" "$RA" "$OLDA" "$RA" "$RECA" > "$SLC"
run 200 "$(rsj 40 "$RA" sOldF)" >/dev/null   # a stale carried observation reports 40 but adopts 75, so the sample records 75
case "$(grep "^P $RA " "$SLC")" in
  *" 75") echo "  Y10 sample records reconciled authority (75), not frozen report (40) OK" ;;
  *" 40") echo "  ★ FAIL Y10 sample recorded the stale report 40"; fail=1 ;;
  *) echo "  ★ FAIL Y10 no/odd P sample: [$(grep "^P $RA " "$SLC")]"; fail=1 ;; esac

# Y11 the alarm is width-bounded like every other left segment — burn-active frame stays single-line, never overflows (task 3.3)
printf 'P %s %s 33\n' "$((NOWB+9000))" "$((NOWB-3600))" > "$SLC"
JBW=$(rsj 58 "$((NOWB+9000))" sBW); wbad=0
for cols in 60 90 120 160; do
  o=$(printf '%s' "$JBW" | env COLUMNS="$cols" HOME="$FAKE_HOME" bash "$SL/statusline-command.sh")
  nl=$(printf '%s' "$o" | grep -c ''); w=$(printf '%s' "$o" | vw)
  [ "$nl" -eq 1 ]                 || { echo "  ★ FAIL Y11 C=$cols not single line: $nl"; wbad=1; }
  [ "$w" -le $((cols-EDGE_PAD)) ] || { echo "  ★ FAIL Y11 C=$cols overflow width=$w > $((cols-EDGE_PAD))"; wbad=1; }
done
[ "$wbad" -eq 0 ] && echo "  Y11 burn-active frame single-line + width-bounded 60..160 OK" || fail=1

# Y12 minimum-Δt gate (dt>=60, inclusive): a sub-minute render burst with a used% jump must NOT project a false alarm; a genuine
# 60s interval still alarms. brun's appended sample is at ~now, so dt = now - old_ts. (Y4 row 6's dt≈60 red alarm pins the inclusive boundary.)
y12bad=0
y12a=$(brun $((NOWB+9000)) $((NOWB-2))  40 70 sBurst | hasarrow)   # dt≈2s burst, used 40→70 — without the gate this falsely projects ↘
[ "$y12a" = no ]  || { echo "  ★ FAIL Y12 sub-minute burst (dt<60) emitted a false alarm"; y12bad=1; }
y12b=$(brun $((NOWB+9000)) $((NOWB-60)) 50 80 sEx60 | hasarrow)    # dt≈60s genuine interval, exhaust before reset → still shown (inclusive 60)
[ "$y12b" = yes ] || { echo "  ★ FAIL Y12 dt=60 genuine interval wrongly suppressed"; y12bad=1; }
[ "$y12bad" -eq 0 ] && echo "  Y12 dt>=60 gate: sub-minute burst hidden, genuine 60s shown OK" || fail=1
rm -f "$SLC" "$TKC" "$TKC".* 2>/dev/null; rm -rf "$TKC".lock 2>/dev/null

echo "── Z. ADAPTIVE-LAYOUT: fixed 14-step sacrifice order — width invariant, segment forms/priority, monotonic drop order, shrink-before-drop, core always remains"
# Full-set fixture on the hermetic GREPO (deterministic git segment: branch "grepo"/basename, no dirty/diffstat) so the degrade widths
# don't flake on this checkout's working tree. ctx=42% (bar present), worktree, both quotas, last-msg, long session name all populated.
JZ=$(jq -cn --arg cwd "$GREPO" --arg proj "$GREPO" --arg tp "$TP" '
  { workspace:{current_dir:$cwd, project_dir:$proj}, model:{display_name:"Opus 4.8 (1M context)"},
    context_window:{used_percentage:42}, worktree:{name:"wt1"},
    rate_limits:{ five_hour:{used_percentage:40, resets_at:(now+9000|floor)},
                  seven_day:{used_percentage:86, resets_at:(now+108000|floor)} },
    effort:{level:"high"}, session_id:"sl-selftest", transcript_path:$tp,
    session_name:"Consolidate statusline from two rows to one" }')
barcells() { python3 -c 'import sys; print(sys.stdin.buffer.read().decode("utf-8","replace").count("48;2"))'; }   # ctx bar = 12 bg cells

# Z1 (task 4.1) Drawable-width invariant + width-tiered: sweep many COLUMNS (incl. 1-2 col pathological) → always single line, width ≤ edge.
echo "── Z1. drawable-width invariant: every width emits ONE line ≤ term_cols-EDGE_PAD, no wrap (J/P/M method over the full degrade range)"
# Sweep down to cols=EDGE_PAD+1 (drawable width 1), the smallest POSITIVE drawable width — the strict width≤edge invariant. The
# pathological cols≤EDGE_PAD case (drawable width ≤0, where any glyph overflows) is the degraded "as far as drawable allows" fallback,
# asserted no-crash/single-line in Z5 and test R, not against an impossible ≤0 width bound.
z1bad=0
for cols in 200 160 140 130 120 110 100 90 80 70 60 50 40 30 24 20 17 10 5 $((EDGE_PAD+1)); do
  o=$(run "$cols" "$JZ"); nl=$(printf '%s' "$o" | grep -c ''); w=$(printf '%s' "$o" | vw)
  [ "$nl" -eq 1 ]                 || { echo "  ★ FAIL Z1 C=$cols not single line: $nl"; z1bad=1; }
  [ "$w" -le $((cols-EDGE_PAD)) ] || { echo "  ★ FAIL Z1 C=$cols overflow width=$w > $((cols-EDGE_PAD))"; z1bad=1; }
done
[ "$z1bad" -eq 0 ] && echo "  Z1 200..$((EDGE_PAD+1)) cols: single line, never exceeds drawable width OK" || fail=1

# Z2 (task 4.2) Per-segment forms: model compacts "Opus 4.8(1M)"→"Opus", ctx bar collapses to plain N%, 5h collapses to remaining% only.
echo "── Z2. per-segment compact forms: model→Opus, ctx bar→plain N%, 5h→remaining% (compact preferred over drop)"
z2bad=0
z2full=$(run 200 "$JZ"); z2fp=$(printf '%s' "$z2full" | nocol)
[ "$(printf '%s' "$z2full" | barcells)" -eq 12 ] || { echo "  ★ FAIL Z2 wide: ctx bar (12 cells) absent"; z2bad=1; }
case "$z2fp" in *"Opus 4.8(1M)"*) ;; *) echo "  ★ FAIL Z2 wide: full model name absent"; z2bad=1 ;; esac
z2c=$(run 130 "$JZ"); z2cp=$(printf '%s' "$z2c" | nocol)
[ "$(printf '%s' "$z2c" | barcells)" -eq 0 ] || { echo "  ★ FAIL Z2 mid: ctx bar not collapsed to plain N%"; z2bad=1; }
case "$z2cp" in *"42%"*) ;; *) echo "  ★ FAIL Z2 mid: ctx % lost"; z2bad=1 ;; esac
z2m=$(run 90 "$JZ" | nocol)
case "$z2m" in *"grepo │ Opus │"*) ;; *) echo "  ★ FAIL Z2 model not compacted to 'Opus': [$z2m]"; z2bad=1 ;; esac
case "$z2m" in *"Opus 4.8"*) echo "  ★ FAIL Z2 model still in full form at C=90: [$z2m]"; z2bad=1 ;; esac
z2q=$(run 30 "$JZ" | nocol)   # 5h collapsed to remaining% only (countdown "2H..m" dropped), session gone
case "$z2q" in *"2H"*m*) echo "  ★ FAIL Z2 5h countdown not dropped at C=30: [$z2q]"; z2bad=1 ;; esac
case "$z2q" in *"60%"*) ;; *) echo "  ★ FAIL Z2 5h remaining% lost at C=30: [$z2q]"; z2bad=1 ;; esac
[ "$z2bad" -eq 0 ] && echo "  Z2 model/ctx/5h compact forms render at their tiers OK" || fail=1

# Z3 (task 4.3) Fixed sacrifice order: as width decreases, segments disappear/compact in the exact 14-step order; the visible set is monotonic.
echo "── Z3. fixed sacrifice order: diffstat→worktree→ctx→git→last-msg→7d→model→session-trunc→session-drop→5h-compact, monotonic"
z3bad=0
has() { case "$1" in *"$2"*) echo y ;; *) echo n ;; esac; }   # $1=plain line $2=needle → y/n
p200=$(run 200 "$JZ" | nocol); p130=$(run 130 "$JZ" | nocol); p120=$(run 120 "$JZ" | nocol)
p110=$(run 110 "$JZ" | nocol); p95=$(run 95 "$JZ" | nocol);  p80=$(run 80 "$JZ" | nocol)
# step 2/3: diffstat present full, gone by 130; worktree present full, gone by 130
[ "$(has "$p200" "[wt:wt1]")" = y ] || { echo "  ★ FAIL Z3 worktree absent at full width"; z3bad=1; }
[ "$(has "$p130" "[wt:wt1]")" = n ] || { echo "  ★ FAIL Z3 worktree not dropped by C=130 (step 3)"; z3bad=1; }
# step 4: ctx bar present full, collapsed by 130 (checked in Z2); step 5: git "grepo │"-as-right gone by 120 but last-msg still there
[ "$(has "$p130" " main")" = y ] || { echo "  ★ FAIL Z3 git not present at C=130"; z3bad=1; }
[ "$(has "$p120" " main")" = n ] || { echo "  ★ FAIL Z3 git not dropped by C=120 (step 5)"; z3bad=1; }
[ "$(has "$p120" "19:38")" = y ] || { echo "  ★ FAIL Z3 last-msg dropped too early (before git): order violated at C=120"; z3bad=1; }
# step 6: last-msg gone by 110; step 7: 7d "1D" gone by 95
[ "$(has "$p110" "19:38")" = n ] || { echo "  ★ FAIL Z3 last-msg not dropped by C=110 (step 6)"; z3bad=1; }
[ "$(has "$p110" "1D")" = y ]    || { echo "  ★ FAIL Z3 7d dropped before last-msg: order violated at C=110"; z3bad=1; }
[ "$(has "$p95"  "1D")" = n ]    || { echo "  ★ FAIL Z3 7d quota not dropped by C=95 (step 7)"; z3bad=1; }
# step 10: model fully gone by 80 (compact step 9 verified in Z2)
[ "$(has "$p80" "Opus")" = n ]   || { echo "  ★ FAIL Z3 model not dropped by C=80 (step 10)"; z3bad=1; }
[ "$z3bad" -eq 0 ] && echo "  Z3 segments vanish/compact in the fixed 14-step order, monotonically OK" || fail=1

# Z4 (task 4.4) Shrink-before-drop: at a mid width the session is head-truncated with … (not dropped); JXLONG forces the right-truncation tier.
echo "── Z4. shrink before drop: mid-width session is … -truncated (not vanished), junction │ retained"
z4=$(run 120 "$JXLONG" | nocol); z4bad=0
case "$z4" in *"a very"*) ;; *) echo "  ★ FAIL Z4 session vanished instead of truncating: [$z4]"; z4bad=1 ;; esac
case "$z4" in *"…"*) ;; *) echo "  ★ FAIL Z4 no … truncation marker on the session: [$z4]"; z4bad=1 ;; esac
case "$z4" in *"truncation"*) echo "  ★ FAIL Z4 session shown whole (not truncated) at C=120: [$z4]"; z4bad=1 ;; esac
[ "$z4bad" -eq 0 ] && echo "  Z4 session truncates with … before being dropped OK" || fail=1

# Z5 (task 4.5) Core always remains: at the narrowest widths (incl. 1-2 col, perl present and absent) path basename + ctx% survive, single line.
echo "── Z5. core always remains: path basename + ctx% kept at the narrowest widths (1-2 col pathological), single line, no crash"
z5bad=0
for cols in 20 17 10; do   # core "grepo 42%" tier: both the path (head-truncated as needed) and the ctx% must be present
  o=$(run "$cols" "$JZ"); pl=$(printf '%s' "$o" | nocol); nl=$(printf '%s' "$o" | grep -c ''); w=$(printf '%s' "$o" | vw)
  [ "$nl" -eq 1 ]                 || { echo "  ★ FAIL Z5 C=$cols not single line"; z5bad=1; }
  [ "$w" -le $((cols-EDGE_PAD)) ] || { echo "  ★ FAIL Z5 C=$cols overflow width=$w"; z5bad=1; }
  case "$pl" in *"42%"*) ;; *) echo "  ★ FAIL Z5 C=$cols ctx% removed from core: [$pl]"; z5bad=1 ;; esac
  case "$pl" in g*) ;; *) echo "  ★ FAIL Z5 C=$cols path basename head not retained: [$pl]"; z5bad=1 ;; esac   # path basename head ("g…")
done
# 1-2 col pathological + perl absent (reuse the failing perl stub at $WORK/bin/perl planted by test M): no crash, single line, clean stderr
for cols in 1 2; do
  err=$(printf '%s' "$JZ" | env PATH="$WORK/bin:$PATH" COLUMNS="$cols" HOME="$FAKE_HOME" bash "$SL/statusline-command.sh" 2>&1 >/dev/null)
  o=$(printf '%s' "$JZ" | env PATH="$WORK/bin:$PATH" COLUMNS="$cols" HOME="$FAKE_HOME" bash "$SL/statusline-command.sh" 2>/dev/null)
  [ -z "$err" ]                              || { echo "  ★ FAIL Z5 C=$cols (perl absent) stderr noise: [$err]"; z5bad=1; }
  [ "$(printf '%s' "$o" | grep -c '')" -eq 1 ] || { echo "  ★ FAIL Z5 C=$cols (perl absent) not single line"; z5bad=1; }
done
[ "$z5bad" -eq 0 ] && echo "  Z5 core (path basename + ctx%) survives 20..1 cols, perl present/absent, single line OK" || fail=1

# CLK (PATH_CLICK) The statusline cannot make its own path clickable — CC re-renders the line through its own style model
# and drops OSC 8 hyperlinks (measured: zero OSC 8 bytes reach the terminal, FORCE_HYPERLINK included). So the terminal
# does the opening and the statusline only publishes what the terminal cannot see: this pane's working directory, keyed by
# the claude pid (CC's children have no controlling terminal, so the tty is unknowable on this side; $PPID is claude).
echo "── CLK. PATH_CLICK: publish claude-pid → cwd for the terminal-side opener, reap dead panes, opener guards"
cbad=0
CWDMAP="$FAKE_HOME/.claude/sl-cwd"
OPENER="$SL/scripts/open-pane-dir.sh"
rm -rf "$CWDMAP"
run 140 "$J" >/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -d "$CWDMAP" ] && [ -n "$(ls -A "$CWDMAP" 2>/dev/null)" ] && break; sleep 0.2; done   # detached job
pub=$(ls -A "$CWDMAP" 2>/dev/null | head -1)
if [ -z "$pub" ]; then echo "  ★ FAIL CLK nothing published"; cbad=1; else
  case $pub in ''|*[!0-9]*) echo "  ★ FAIL CLK record not keyed by pid: [$pub]"; cbad=1 ;; esac
  [ "$(cat "$CWDMAP/$pub" 2>/dev/null)" = "$SL" ] || { echo "  ★ FAIL CLK published dir [$(cat "$CWDMAP/$pub" 2>/dev/null)] != [$SL]"; cbad=1; }
  # the map leaks directory paths of every open pane → must not be world-readable
  perm=$(stat -f '%Lp' "$CWDMAP" 2>/dev/null); [ "$perm" = "700" ] || { echo "  ★ FAIL CLK dir mode $perm != 700"; cbad=1; }
  perm=$(stat -f '%Lp' "$CWDMAP/$pub" 2>/dev/null); [ "$perm" = "600" ] || { echo "  ★ FAIL CLK file mode $perm != 600"; cbad=1; }
fi
# a pane that is gone must not leave its directory behind forever (pid 1 is alive and must survive; a free high pid must not)
deadpid=$(( 99000 + RANDOM % 900 )); while kill -0 "$deadpid" 2>/dev/null; do deadpid=$((deadpid+1)); done
echo /tmp > "$CWDMAP/$deadpid"; echo /tmp > "$CWDMAP/1"; echo /tmp > "$CWDMAP/not-a-pid"
run 140 "$J" >/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$CWDMAP/$deadpid" ] || break; sleep 0.2; done
[ -f "$CWDMAP/$deadpid" ] && { echo "  ★ FAIL CLK dead pane record not reaped"; cbad=1; }
[ -f "$CWDMAP/1" ]       || { echo "  ★ FAIL CLK live pid record wrongly reaped"; cbad=1; }
[ -f "$CWDMAP/not-a-pid" ] || { echo "  ★ FAIL CLK non-pid file wrongly removed"; cbad=1; }
# PATH_CLICK=false publishes nothing at all
mkdir -p "$WORK/noclick/lib" && cp "$SL"/lib/*.sh "$WORK/noclick/lib/"
sed 's/^PATH_CLICK=true/PATH_CLICK=false/' "$SL/statusline-command.sh" > "$WORK/noclick/statusline-command.sh"
rm -rf "$CWDMAP"
printf '%s' "$J" | env COLUMNS=140 HOME="$FAKE_HOME" bash "$WORK/noclick/statusline-command.sh" >/dev/null
sleep 0.6
[ -d "$CWDMAP" ] && { echo "  ★ FAIL CLK PATH_CLICK=false still published"; cbad=1; }
# opener guards: a tty string that is not a plain device name must be rejected before it reaches ps, and an unknown
# pane must fail cleanly rather than open something arbitrary. SL_OPEN_NOTIFY=0 keeps these paths silent.
out=$(SL_OPEN_NOTIFY=0 HOME="$FAKE_HOME" bash "$OPENER" '/dev/../etc/passwd' 2>&1); rc=$?
[ "$rc" -eq 1 ] && case "$out" in *"unexpected tty"*) ;; *) echo "  ★ FAIL CLK traversal tty not rejected: [$out]"; cbad=1 ;; esac
[ "$rc" -eq 1 ] || { echo "  ★ FAIL CLK traversal tty exit=$rc"; cbad=1; }
out=$(SL_OPEN_NOTIFY=0 HOME="$FAKE_HOME" bash "$OPENER" /dev/ttys999 2>&1); rc=$?
[ "$rc" -eq 1 ] || { echo "  ★ FAIL CLK unknown pane should fail, exit=$rc"; cbad=1; }
[ "$cbad" -eq 0 ] && echo "  CLK publish + reap + private perms + disable + opener guards OK" || fail=1

echo "── Q. alternate-billing quota field"
# A session billing somewhere other than the personal subscription must not show
# the personal rate limits: those percentages belong to an account it is not
# spending, which is worse than showing nothing.
qbad=0
qdir="$WORK/quota"
mkdir -p "$qdir"
qrun() {  # $1=cols $2=json ; same as run() plus a configured gateway
  printf '%s' "$2" | env COLUMNS="$1" HOME="$FAKE_HOME" \
    ANTHROPIC_BASE_URL="https://gw.example.invalid/v1" \
    SL_QUOTA_MATCH="gw.example.invalid" SL_QUOTA_LABEL="TEAM" SL_QUOTA_DIR="$qdir" \
    bash "$SL/statusline-command.sh"
}
qrun_stale() {  # $1=stale seconds $2=cols $3=json
  printf '%s' "$3" | env COLUMNS="$2" HOME="$FAKE_HOME" SL_QUOTA_STALE="$1" \
    ANTHROPIC_BASE_URL="https://gw.example.invalid/v1" \
    SL_QUOTA_MATCH="gw.example.invalid" SL_QUOTA_LABEL="TEAM" SL_QUOTA_DIR="$qdir" \
    bash "$SL/statusline-command.sh"
}
# Extract the SGR code immediately before the quota value or label. References
# are derived from the live palette in one frame, so no colour triple is fixed.
qvaluecode() { perl -ne 'while(/\x1b\[([0-9;]*)m63%\*/g){$c=$1} END{print $c}'; }
qlabelcode() { perl -ne 'while(/\x1b\[([0-9;]*)mTEAM/g){$c=$1} END{print $c}'; }

# QS0: derive distinct severity and DM role codes from the current palette.
printf '63%%* red\n' > "$qdir/claude-opus-4-8"
qsref=$(qrun 200 "$J"); qs_sev=$(printf '%s' "$qsref" | qvaluecode); qs_dm=$(printf '%s' "$qsref" | qlabelcode)
if [ -n "$qs_sev" ] && [ -n "$qs_dm" ] && [ "$qs_sev" != "$qs_dm" ]; then
  echo "  QS0 quota severity/DM colours derived OK"
else
  echo "  ★ FAIL QS0 could not derive distinct quota colours (severity=[$qs_sev] DM=[$qs_dm])"; qbad=1
fi

qnow=$(date +%s)
# QS1: a timestamp 60 seconds ago remains in its severity role.
printf '63%%* red %s\n' "$((qnow-60))" > "$qdir/claude-opus-4-8"
qs1=$(qrun 200 "$J"); qs1code=$(printf '%s' "$qs1" | qvaluecode); qs1plain=$(printf '%s' "$qs1" | nocol)
[ "$qs1code" = "$qs_sev" ] || { echo "  ★ FAIL QS1 fresh value not in severity role (got=[$qs1code] want=[$qs_sev])"; qbad=1; }
case "$qs1plain" in *"63%*"*) ;; *) echo "  ★ FAIL QS1 value text changed: [$qs1plain]"; qbad=1 ;; esac
case "$qs1plain" in *"$((qnow-60))"*) echo "  ★ FAIL QS1 timestamp reached screen: [$qs1plain]"; qbad=1 ;; esac

# QS2: 901 seconds is strictly outside the default window, so only the value
# role changes to DM; the stripped frame stays byte-identical to QS1.
printf '63%%* red %s\n' "$((qnow-901))" > "$qdir/claude-opus-4-8"
qs2=$(qrun 200 "$J"); qs2code=$(printf '%s' "$qs2" | qvaluecode); qs2dm=$(printf '%s' "$qs2" | qlabelcode); qs2plain=$(printf '%s' "$qs2" | nocol)
[ "$qs2code" = "$qs2dm" ] || { echo "  ★ FAIL QS2 stale value not in DM role (value=[$qs2code] DM=[$qs2dm])"; qbad=1; }
[ "$qs2code" != "$qs_sev" ] || { echo "  ★ FAIL QS2 stale value retained severity role"; qbad=1; }
[ "$qs2plain" = "$qs1plain" ] || { echo "  ★ FAIL QS2 dimming changed stripped frame"; qbad=1; }

# QS3/QS4: old two-field files and unusable third fields keep severity colour;
# neither the timestamp nor any trailing content may reach the screen.
for qline in '63%* red' '63%* red abc' '63%* red 1756300000 extra'; do
  printf '%s\n' "$qline" > "$qdir/claude-opus-4-8"
  qso=$(qrun 200 "$J"); qscode=$(printf '%s' "$qso" | qvaluecode); qsplain=$(printf '%s' "$qso" | nocol)
  [ "$qscode" = "$qs_sev" ] || { echo "  ★ FAIL QS3/QS4 unusable timestamp changed severity for [$qline]"; qbad=1; }
  case "$qsplain" in *abc*|*1756300000*|*extra*) echo "  ★ FAIL QS3/QS4 third field reached screen: [$qsplain]"; qbad=1 ;; esac
done

# QS5: an environment override of 60 seconds dims age 61, while the same file
# remains fresh under the default 900-second window.
printf '63%%* red %s\n' "$((qnow-61))" > "$qdir/claude-opus-4-8"
qs5=$(qrun_stale 60 200 "$J"); qs5code=$(printf '%s' "$qs5" | qvaluecode); qs5dm=$(printf '%s' "$qs5" | qlabelcode)
[ "$qs5code" = "$qs5dm" ] || { echo "  ★ FAIL QS5 override did not dim age 61 (value=[$qs5code] DM=[$qs5dm])"; qbad=1; }
qs5default=$(qrun 200 "$J" | qvaluecode)
[ "$qs5default" = "$qs_sev" ] || { echo "  ★ FAIL QS5 default window dimmed age 61"; qbad=1; }

# QS6: unusable windows fall back to 900, and a leading zero is decimal. Ages
# 61 and 600 bind the fresh side (including against a bogus fallback of 100),
# while age 1200 binds the stale side of the same default.
for qwindow in '' sixty 1234567890123456789012345678901234567890 00900; do
  printf '63%%* red %s\n' "$((qnow-61))" > "$qdir/claude-opus-4-8"
  qscode=$(qrun_stale "$qwindow" 200 "$J" | qvaluecode)
  [ "$qscode" = "$qs_sev" ] || { echo "  ★ FAIL QS6 window [$qwindow] dimmed age 61"; qbad=1; }
  printf '63%%* red %s\n' "$((qnow-600))" > "$qdir/claude-opus-4-8"
  qscode=$(qrun_stale "$qwindow" 200 "$J" | qvaluecode)
  [ "$qscode" = "$qs_sev" ] || { echo "  ★ FAIL QS6 window [$qwindow] did not retain default/decimal 900"; qbad=1; }
  printf '63%%* red %s\n' "$((qnow-1200))" > "$qdir/claude-opus-4-8"
  qso=$(qrun_stale "$qwindow" 200 "$J"); qscode=$(printf '%s' "$qso" | qvaluecode); qsdm=$(printf '%s' "$qso" | qlabelcode)
  [ "$qscode" = "$qsdm" ] || { echo "  ★ FAIL QS6 window [$qwindow] did not use decimal/default 900"; qbad=1; }
done

# QS7: future/millisecond/oversized timestamps are never stale; a usable
# leading-zero timestamp is read in base 10 and remains fresh here.
for qat in "$((qnow+3600))" 1756300000000 1234567890123456789012345678901234567890 "0$((qnow-60))"; do
  printf '63%%* red %s\n' "$qat" > "$qdir/claude-opus-4-8"
  qscode=$(qrun 200 "$J" | qvaluecode)
  [ "$qscode" = "$qs_sev" ] || { echo "  ★ FAIL QS7 timestamp [$qat] was incorrectly dimmed"; qbad=1; }
done

# A colon is not a digit. It must fail closed to severity without entering
# arithmetic, printing diagnostics, or terminating the frame.
printf '63%%* red 123:456\n' > "$qdir/claude-opus-4-8"
qs7err="$WORK/qs7-colon.err"
qs7colon=$(qrun 200 "$J" 2>"$qs7err"); qs7rc=$?
qs7code=$(printf '%s' "$qs7colon" | qvaluecode); qs7lines=$(printf '%s' "$qs7colon" | grep -c '')
[ "$qs7rc" -eq 0 ] || { echo "  ★ FAIL QS7 colon timestamp terminated frame (exit=$qs7rc)"; qbad=1; }
[ ! -s "$qs7err" ] || { echo "  ★ FAIL QS7 colon timestamp wrote stderr"; qbad=1; }
[ "$qs7lines" -eq 1 ] || { echo "  ★ FAIL QS7 colon timestamp output lines=$qs7lines"; qbad=1; }
[ "$qs7code" = "$qs_sev" ] || { echo "  ★ FAIL QS7 colon timestamp changed severity"; qbad=1; }

# QS8: guarantee the writer timestamp and jq's render time are in the same
# wall-clock second, then bind the strict default boundary: age 900 is fresh.
qs8=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  qs8now=$(date +%s)
  printf '63%%* red %s\n' "$((qs8now-900))" > "$qdir/claude-opus-4-8"
  qs8try=$(qrun 200 "$J")
  [ "$(date +%s)" = "$qs8now" ] || continue
  qs8=$qs8try
  break
done
if [ -n "$qs8" ]; then
  qs8code=$(printf '%s' "$qs8" | qvaluecode)
  [ "$qs8code" = "$qs_sev" ] || { echo "  ★ FAIL QS8 age exactly 900 was dimmed"; qbad=1; }
else
  echo "  ★ FAIL QS8 could not capture a same-second boundary frame"; qbad=1
fi
[ "$qbad" -ne 0 ] || echo "  QS1-QS8 freshness, strict boundary, guards, fallback, and override cases OK"

# QJ: the writer joins two figures into this one slot with its own separator --
# U+00A0 │ U+00A0. The no-break spaces are deliberate: read_quota_field splits
# the file with IFS=' ', so only a space that is not an ASCII space keeps the
# joined text together as field one. That │ is punctuation, not data, so it must
# be drawn in the same neutral SP role as every other │ on the line instead of
# pulsing orange/red/DM with the numbers it divides.
qsep=$(printf '\302\240\342\224\202\302\240')
# SGR immediately before the value's own │, identified by the no-break space in
# front of it -- no other separator on the line is preceded by one.
qsepcode() { perl -ne 'while(/\x1b\[([0-9;]*)m\xc2\xa0\xe2\x94\x82/g){$c=$1} END{print $c}'; }
# SGR of the structural SP role, read off an ordinary " │ " join in the same frame.
qspcode()  { perl -ne 'while(/\x1b\[([0-9;]*)m \xe2\x94\x82/g){$c=$1} END{print $c}'; }
# SGR immediately before an arbitrary literal word.
qjcode()   { QW="$1" perl -ne 'while(/\x1b\[([0-9;]*)m\Q$ENV{QW}\E/g){$c=$1} END{print $c}'; }

qjnow=$(date +%s)
printf '36.9M%s26%% orange %s\n' "$qsep" "$((qjnow-60))" > "$qdir/claude-opus-4-8"
qj1=$(qrun 200 "$J")
qj1sp=$(printf '%s' "$qj1" | qspcode)
qj1sep=$(printf '%s' "$qj1" | qsepcode)
qj1l=$(printf '%s' "$qj1" | qjcode '36.9M')
qj1r=$(printf '%s' "$qj1" | qjcode '26%')
# Preconditions: without a live SP that differs from the severity role, the
# assertions below would pass no matter how the separator were coloured.
if [ -z "$qj1sp" ] || [ -z "$qj1l" ] || [ "$qj1sp" = "$qj1l" ]; then
  echo "  ★ FAIL QJ1 preconditions (SP=[$qj1sp] severity=[$qj1l]) -- assertions would be vacuous"; qbad=1
fi
[ "$qj1l" = "$qj1r" ] || { echo "  ★ FAIL QJ1 figures differ in colour (left=[$qj1l] right=[$qj1r])"; qbad=1; }
[ "$qj1sep" = "$qj1sp" ] || { echo "  ★ FAIL QJ1 separator not in SP role (sep=[$qj1sep] SP=[$qj1sp])"; qbad=1; }
[ "$qj1sep" != "$qj1l" ] || { echo "  ★ FAIL QJ1 separator took the severity colour [$qj1sep]"; qbad=1; }

# QJ4: recolouring must not disturb one character of the display text.
qj1plain=$(printf '%s' "$qj1" | nocol)
case "$qj1plain" in *"36.9M${qsep}26%"*) ;; *) echo "  ★ FAIL QJ4 display text altered: [$qj1plain]"; qbad=1 ;; esac
case "$qj1plain" in *"$((qjnow-60))"*) echo "  ★ FAIL QJ4 timestamp reached screen"; qbad=1 ;; esac

# QJ3: staleness dims the figures; the separator stays structural in both frames.
printf '36.9M%s26%% orange %s\n' "$qsep" "$((qjnow-901))" > "$qdir/claude-opus-4-8"
qj3=$(qrun 200 "$J")
qj3sp=$(printf '%s' "$qj3" | qspcode)
qj3sep=$(printf '%s' "$qj3" | qsepcode)
qj3l=$(printf '%s' "$qj3" | qjcode '36.9M')
qj3r=$(printf '%s' "$qj3" | qjcode '26%')
qj3dm=$(printf '%s' "$qj3" | qlabelcode)
if [ -z "$qj3sp" ] || [ -z "$qj3dm" ] || [ "$qj3sp" = "$qj3dm" ]; then
  echo "  ★ FAIL QJ3 preconditions (SP=[$qj3sp] DM=[$qj3dm]) -- assertions would be vacuous"; qbad=1
fi
[ "$qj3l" = "$qj3dm" ] || { echo "  ★ FAIL QJ3 stale left figure not DM (got=[$qj3l] DM=[$qj3dm])"; qbad=1; }
[ "$qj3r" = "$qj3dm" ] || { echo "  ★ FAIL QJ3 stale right figure not DM (got=[$qj3r] DM=[$qj3dm])"; qbad=1; }
[ "$qj3sep" = "$qj3sp" ] || { echo "  ★ FAIL QJ3 stale separator not in SP role (sep=[$qj3sep] SP=[$qj3sp])"; qbad=1; }
[ "$qj3sep" != "$qj3dm" ] || { echo "  ★ FAIL QJ3 separator was dimmed along with the figures"; qbad=1; }

# QJ2: a value carrying no separator keeps today's shape exactly -- one SGR, the
# whole string, one reset, with none of the splitting machinery in between.
printf 'no-cookie yellow %s\n' "$((qjnow-60))" > "$qdir/claude-opus-4-8"
qj2=$(qrun 200 "$J")
qj2one=$(printf '%s' "$qj2" | perl -ne 'print "y" if /\x1b\[[0-9;]*mno-cookie\x1b\[0m/')
[ "$qj2one" = "y" ] || { echo "  ★ FAIL QJ2 separatorless value no longer one contiguous coloured run"; qbad=1; }
[ -z "$(printf '%s' "$qj2" | qsepcode)" ] || { echo "  ★ FAIL QJ2 separator role appeared inside a value with no separator"; qbad=1; }

# QJ5: the separator sitting at the value's leading or trailing EDGE — the one arrangement QJ1-QJ4 never feed, since they all
# put text on both sides of it. build_quota_value splits the text on the separator and colours each run, so an edge separator
# leaves one run EMPTY: the loop emits a bare "<severity SGR><reset>" pair with no character between them. That pair is
# invisible by construction (vis_width consumes every ESC before it measures) and this case pins that claim down.
# The control fixture "2<sep>6%" is picked to carry exactly the SAME bytes as the two edge fixtures — three ASCII characters,
# two no-break spaces, one │ — so the renderer's width arithmetic sees an identical byte profile and the ONLY difference left
# is where the separator sits. Equal rendered width therefore means the empty run cost zero cells; an unequal one would mean
# it was measured. Roles are read against QJ1's own frame, so the severity and SP references come from the live palette.
qj5frame() {  # $1=quota value text → the raw frame that value renders at COLUMNS=200
  printf '%s orange %s\n' "$1" "$((qjnow-60))" > "$qdir/claude-opus-4-8"
  qrun 200 "$J"
}
qj5vw() {  # stdin=frame → visible width of the quota value alone: the text between the TEAM label and the next structural " │ ".
           # The value's own separator is no-break-space-delimited, so a non-greedy match cannot mistake it for that structural join.
  nocol | python3 -c '
import sys, re, unicodedata
line = sys.stdin.read().rstrip("\n")
m = re.search(u"TEAM \u2502 (.*?) \u2502 ", line)
print(sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in m.group(1)) if m else -1)'
}
qj5ctl=$(qj5frame "2${qsep}6%")            # interior separator, same bytes as both edge fixtures
qj5ctlw=$(printf '%s' "$qj5ctl" | vw); qj5ctlvw=$(printf '%s' "$qj5ctl" | qj5vw)
qj5lead=$(qj5frame "${qsep}26%")
qj5trail=$(qj5frame "26%${qsep}")
[ "$qj5ctlvw" -gt 0 ] || { echo "  ★ FAIL QJ5 control value not locatable in the frame — the asserts below would be vacuous"; qbad=1; }
for qj5n in lead trail; do
  case "$qj5n" in
    lead)  qj5v="${qsep}26%";  qj5f=$qj5lead  ;;
    trail) qj5v="26%${qsep}";  qj5f=$qj5trail ;;
  esac
  qj5plain=$(printf '%s' "$qj5f" | nocol)
  # Visible text, bounded on BOTH sides by the structural join, so a stray blank emitted for the empty run cannot hide in a
  # trailing wildcard: the value must be the writer's string exactly, no character more.
  case "$qj5plain" in *"TEAM │ ${qj5v} │ "*) ;; *) echo "  ★ FAIL QJ5/$qj5n visible text is not the value verbatim: [$qj5plain]"; qbad=1 ;; esac
  # Width, two independent ways. The value's own visible width catches a character leaking out of the empty run; the whole
  # frame's width catches the opposite error, the renderer MEASURING the empty run and under-filling the line to pay for it.
  qj5vwn=$(printf '%s' "$qj5f" | qj5vw)
  [ "$qj5vwn" = "$qj5ctlvw" ] || { echo "  ★ FAIL QJ5/$qj5n quota value width $qj5vwn != interior-control $qj5ctlvw — the empty colour run is not empty"; qbad=1; }
  qj5w=$(printf '%s' "$qj5f" | vw)
  [ "$qj5w" = "$qj5ctlw" ] || { echo "  ★ FAIL QJ5/$qj5n frame width $qj5w != interior-control $qj5ctlw — the empty colour run is being measured"; qbad=1; }
  qj5sep=$(printf '%s' "$qj5f" | qsepcode)
  qj5fig=$(printf '%s' "$qj5f" | qjcode '26%')
  [ "$qj5sep" = "$qj1sp" ] || { echo "  ★ FAIL QJ5/$qj5n edge separator left the neutral SP role (sep=[$qj5sep] SP=[$qj1sp])"; qbad=1; }
  [ "$qj5fig" = "$qj1l" ]  || { echo "  ★ FAIL QJ5/$qj5n figure lost the severity role (got=[$qj5fig] want=[$qj1l])"; qbad=1; }
done
rm -f "$qdir/claude-opus-4-8"

[ "$qbad" -ne 0 ] || echo "  QJ1-QJ5 inline separator neutral, figures coloured, stale dims figures only, text intact, edge separator costs no width OK"

# mkjson reports "Opus 4.8 (1M context)", which maps to claude-opus-4-8.
printf '3.3%% green\n' > "$qdir/claude-opus-4-8"
out=$(qrun 200 "$J" | nocol)
case "$out" in *"TEAM"*"3.3%"*) ;; *) echo "  ★ FAIL label+value missing: [$out]"; qbad=1 ;; esac
# 23 and 84 used render as 77% and 16% remaining; neither may survive here.
case "$out" in *"77%"*|*"16%"*) echo "  ★ FAIL personal rate limits leaked: [$out]"; qbad=1 ;; esac

# Unconfigured sessions keep the old behaviour exactly.
out=$(run 200 "$J" | nocol)
case "$out" in *TEAM*) echo "  ★ FAIL quota field shown while unconfigured: [$out]"; qbad=1 ;; esac
case "$out" in *"77%"*) ;; *) echo "  ★ FAIL personal rate limit vanished while unconfigured: [$out]"; qbad=1 ;; esac

# Configured label but a base URL that does not match: still the old behaviour.
out=$(printf '%s' "$J" | env COLUMNS=200 HOME="$FAKE_HOME" \
      ANTHROPIC_BASE_URL="https://api.anthropic.com" \
      SL_QUOTA_MATCH="gw.example.invalid" SL_QUOTA_LABEL="TEAM" SL_QUOTA_DIR="$qdir" \
      bash "$SL/statusline-command.sh" | nocol)
case "$out" in *TEAM*) echo "  ★ FAIL quota field shown for a non-matching base URL: [$out]"; qbad=1 ;; esac

# A marker the writer appends (an unenforced limit, say) must reach the screen
# untouched: without it a comfortable number looks like a line that would stop you.
printf '1.4%%* green\n' > "$qdir/claude-opus-4-8"
out=$(qrun 200 "$J" | nocol)
case "$out" in *"1.4%*"*) ;; *) echo "  ★ FAIL trailing marker dropped: [$out]"; qbad=1 ;; esac

# Nothing cached yet: still say which account this is, just without a number.
rm -f "$qdir/claude-opus-4-8"
out=$(qrun 200 "$J" | nocol)
case "$out" in *TEAM*) ;; *) echo "  ★ FAIL label needs no cached value: [$out]"; qbad=1 ;; esac
case "$out" in *"77%"*|*"16%"*) echo "  ★ FAIL personal limits reappeared with no cache: [$out]"; qbad=1 ;; esac

# An unrecognised model family falls through to the same safe state rather than
# reading some other model's file.
JQ2=$(printf '%s' "$J" | jq -c '.model.display_name="Nimbus 9 (1M context)"')
printf '99.9%% red\n' > "$qdir/claude-opus-4-8"
out=$(qrun 200 "$JQ2" | nocol)
case "$out" in *"99.9%"*) echo "  ★ FAIL unknown family read another model's value: [$out]"; qbad=1 ;; esac
case "$out" in *TEAM*) ;; *) echo "  ★ FAIL label missing for unknown family: [$out]"; qbad=1 ;; esac
rm -f "$qdir/claude-opus-4-8"

# Narrowing drops the value before the label. A percentage with nothing naming
# the account it belongs to is worse than no percentage: the label is the part
# that answers "whose allowance is this".
printf '42%% green\n' > "$qdir/claude-opus-4-8"
wide=$(qrun 200 "$J" | nocol)
case "$wide" in *"TEAM"*"42%"*) ;; *) echo "  ★ FAIL wide line lost label or value: [$wide]"; qbad=1 ;; esac
narrow=$(qrun 70 "$J" | nocol)
case "$narrow" in *"42%"*) echo "  ★ FAIL value survived a width that must drop it: [$narrow]"; qbad=1 ;; esac
case "$narrow" in *TEAM*) ;; *) echo "  ★ FAIL label dropped before the value: [$narrow]"; qbad=1 ;; esac
rm -f "$qdir/claude-opus-4-8"

[ "$qbad" -eq 0 ] && echo "  quota label + value + marker + no-cache + unknown-model + off-by-default + ladder OK" || fail=1

# ── SUBAGENT STATUS LINE (SA1-SA9) ──────────────────────────────────────────────────────────────────
# Second entry point. subagent-status-line.sh reads the subagent status JSON on stdin and prints JSON Lines
# ({"id":…,"content":…}), one record per task row it takes over. A task id it does NOT print keeps Claude
# Code's own default row, and that guaranteed fallback is this script's ONLY error path — so "emitted nothing
# for this id" is a PASS condition in several cases below, never an accident to be papered over.
# HOME is pinned to $FAKE_HOME like every other invocation in this file: the script resolves the user's theme
# from ~/.claude.json, and the real one would make the palette (hence the emitted SGR bytes) machine-dependent.
SASCRIPT="$SL/subagent-status-line.sh"

sarun() {   # $1=payload JSON → JSON Lines on stdout
  printf '%s' "$1" | env HOME="$FAKE_HOME" bash "$SASCRIPT"
}

saraw() {   # stdin=JSON Lines, $1=task id → that record's content verbatim (empty when the id was not emitted)
  # Must run via -c, NOT heredoc: a heredoc steals stdin so the data side would read nothing (harness-wide rule).
  python3 -c '
import sys, json
want = sys.argv[1]; out = ""
for line in sys.stdin.read().splitlines():
    if not line.strip(): continue
    o = json.loads(line)
    if o.get("id") == want: out = o.get("content", "")
sys.stdout.write(out)' "$1"
}

sasegs() {  # stdin=visible (SGR-stripped) content → how many " │ "-separated segments it has
  python3 -c '
import sys
print(len(sys.stdin.read().rstrip("\n").split(" │ ")))'
}

sajsonl() {  # stdin=JSON Lines → "OK <n>" when every line is an object with exactly id+content, else the reason
  python3 -c '
import sys, json
n = 0
for line in sys.stdin.read().splitlines():
    if not line.strip(): continue
    try: o = json.loads(line)
    except Exception as e: print("bad JSON line: %s" % e); sys.exit(0)
    if not isinstance(o, dict): print("line is not an object"); sys.exit(0)
    if set(o) != {"id", "content"}: print("unexpected keys: %r" % sorted(o)); sys.exit(0)
    n += 1
print("OK %d" % n)'
}

sacolat() {  # stdin=raw content, $1=text to locate, $2=expected SGR prefix → "OK" or the mismatch
  python3 -c '
import sys, re
s = sys.stdin.read(); needle = sys.argv[1]; want = sys.argv[2]
m = re.search(r"(\x1b\[[0-9;]*m)" + re.escape(needle), s)
if not m: print("not found: %r" % needle)
elif m.group(1) != want: print("colour %r, wanted %r" % (m.group(1), want))
else: print("OK")' "$1" "$2"
}

samk() {  # $1=model $2=contextWindowSize $3=description $4=label $5=columns $6=tokenCount $7=status $8=startTime (epoch ms)
          # $9=tokenSamples (JSON array text) — "" or an absent trailing argument omits the field. The status data fields are
          # appended after tokenCount, so a call with the first six arguments only builds the same payload byte for byte.
  jq -cn --arg m "$1" --arg w "$2" --arg d "$3" --arg l "$4" --arg c "$5" --arg t "${6-}" \
         --arg s "${7-}" --arg st "${8-}" --arg ts "${9-}" '
    { tasks: [ {id:"tid"}
        + (if $m == "" then {} else {model:$m} end)
        + (if $w == "" then {} else {contextWindowSize:($w|tonumber)} end)
        + (if $d == "" then {} else {description:$d} end)
        + (if $l == "" then {} else {label:$l} end)
        + (if $t == "" then {} else {tokenCount:($t|tonumber)} end)
        + (if $s == "" then {} else {status:$s} end)
        + (if $st == "" then {} else {startTime:($st|tonumber)} end)
        + (if $ts == "" then {} else {tokenSamples:($ts|fromjson)} end) ] }
    + (if $c == "" then {} else {columns:($c|tonumber)} end)'
}

# startTime for a task that started $1 seconds ago (negative = in the future), in epoch ms from jq's sub-second clock.
# Whole-second `date +%s` would put the start up to 1 s early and turn a 59 s case into 60 s; with milliseconds the
# measured age is $1 plus the few tens of milliseconds the script takes to start, which floors back to $1.
sastart() { jq -n --argjson n "$1" '(now * 1000 | floor) - ($n * 1000)'; }

sarep() {  # $1=JSON value $2=count → a JSON array holding $2 copies of $1
  local a="" i=0
  while [ "$i" -lt "$2" ]; do a="$a${a:+,}$1"; i=$((i + 1)); done
  printf '[%s]' "$a"
}

sacell() {  # stdin=visible content, $1=0-based cell index → that cell verbatim, padding included ("<none>" past the end)
  python3 -c '
import sys
c = sys.stdin.read().rstrip("\n").split(" │ ")
i = int(sys.argv[1])
sys.stdout.write(c[i] if i < len(c) else "<none>")' "$1"
}

sacellsgr() {  # stdin=raw content, $1=0-based cell index → the SGR in effect at that cell's first non-space character
  # Located by cell, not by text, so a "-" placeholder in one cell can never be mistaken for one in another, and it
  # holds whether the padding is drawn inside or outside the cell's colour.
  python3 -c '
import sys, re
s = sys.stdin.read(); idx = int(sys.argv[1])
vis = []; cur = ""; i = 0
while i < len(s):
    m = re.match(r"\x1b\[[0-9;]*m", s[i:])
    if m: cur = m.group(0); i += m.end(); continue
    vis.append((s[i], cur)); i += 1
text = "".join(c for c, _ in vis)
starts = [0]; j = 0
while True:
    k = text.find(" │ ", j)
    if k < 0: break
    starts.append(k + 3); j = k + 3
if idx >= len(starts): print("<no cell %d>" % idx); sys.exit(0)
p = starts[idx]
while p < len(text) and text[p] == " ": p += 1
sys.stdout.write(vis[p][1] if p < len(text) else "<empty cell>")' "$1"
}

sarole() {  # $1=raw content $2=cell index $3=expected SGR $4=what → rc 0 when that cell is drawn in $3, else prints the FAIL
  local got
  got=$(printf '%s' "$1" | sacellsgr "$2")
  [ "$got" = "$3" ] && return 0
  echo "  ★ FAIL $4 colour: cell $2 drawn in $(printf '%q' "$got"), wanted $(printf '%q' "$3")"
  return 1
}

# A complete task row that MUST be emitted, dropped into any payload whose real assertion is negative
# ("this id must NOT appear"). Without it such an assertion cannot tell "the guard rejected that row"
# from "the script emitted nothing at all" — a blanket blackout satisfies every negative assertion in
# the file. The check compares the control row's RENDERED TEXT, not just the presence of its id: one
# failure mode keeps the id and blanks the content, and an id-only check sails straight through it.
SACTL='{"id":"controlRow","status":"running","model":"claude-sonnet-5","contextWindowSize":1000000,"tokenCount":50000,"description":"CTLDESC","label":"CTLLABEL"}'
sactl_check() {  # $1=the whole JSON Lines output → rc 0 when the control row is present AND rendered right
  local got
  got=$(printf '%s' "$1" | saraw controlRow | nocol)
  [ "$got" = "RUN  │     - │  5% │  50K │ Sonnet 5 │ CTLDESC │ CTLLABEL" ] && return 0
  echo "  ★ FAIL control row missing or mis-rendered — cannot tell a guard hit from a blackout: [$got]"
  return 1
}

# The palette the script itself will load: same STYLE source (statusline-command.sh's knob, pulled the way
# EDGE_PAD/JGAP are above) and same empty-theme = dark path. Asserting against the ROLE (MD / YL) rather than
# a hardcoded RGB keeps these checks true under any STYLE. Caveat: rose-pine defines MD and YL as the same
# bytes, so under that style the two colour asserts stop being able to tell the roles apart (they still pass).
SASTYLE=$(sed -n 's/^STYLE="\([^"]*\)".*/\1/p' "$SL/statusline-command.sh")
SAMD=$( . "$SL/lib/render.sh"; _theme=""; STYLE="$SASTYLE"; load_palette; printf '%s' "$MD" )
SAYL=$( . "$SL/lib/render.sh"; _theme=""; STYLE="$SASTYLE"; load_palette; printf '%s' "$YL" )
SAWH=$( . "$SL/lib/render.sh"; _theme=""; STYLE="$SASTYLE"; load_palette; printf '%s' "$WH" )
SADM=$( . "$SL/lib/render.sh"; _theme=""; STYLE="$SASTYLE"; load_palette; printf '%s' "$DM" )
SASP=$( . "$SL/lib/render.sh"; _theme=""; STYLE="$SASTYLE"; load_palette; printf '%s' "$SP" )
SAGR=$( . "$SL/lib/render.sh"; _theme=""; STYLE="$SASTYLE"; load_palette; printf '%s' "$GR" )
SAOG=$( . "$SL/lib/render.sh"; _theme=""; STYLE="$SASTYLE"; load_palette; printf '%s' "$OG" )
SARD=$( . "$SL/lib/render.sh"; _theme=""; STYLE="$SASTYLE"; load_palette; printf '%s' "$RD" )
# The cells every SA1-SA4 row shares when its fixture carries status running, a 1M window, 50000 tokens and no startTime:
# marker, elapsed placeholder, context percentage and token usage, each with its separator.
SAPFX='RUN  │     - │  5% │  50K │ '

echo "── SA1. SUBAGENT: Model display name derived by rule, never by lookup table (seven derivation cases)"
sa1bad=0
sacase() {  # $1=model identifier $2=expected display name (the model cell carries no window marker)
  local got
  got=$(sarun "$(samk "$1" 1000000 d l 120 50000 running)" | saraw tid | nocol)
  if [ "$got" = "${SAPFX}$2 │ d │ l" ]; then :; else
    echo "  ★ FAIL model [$1] → wanted [${SAPFX}$2 │ d │ l], got [$got]"; sa1bad=1
  fi
}
sacase 'claude-sonnet-5'   'Sonnet 5'
sacase 'claude-opus-5[1m]' 'Opus 5'
sacase 'claude-haiku-4-5'  'Haiku 4.5'
sacase 'claude-opus-4-8'   'Opus 4.8'
sacase 'claude-mystery'    'mystery'     # no numeric segment: printed verbatim after prefix strip, never guessed
sacase 'claude-opus-4x'    'opus-4x'     # version segment is not purely numeric → whole remainder verbatim
sacase 'claude-sonnet4-5'  'sonnet4-5'   # family is not a plain lowercase word → whole remainder verbatim
# The harness's `bash` is whatever PATH resolves first (homebrew bash 5 on this machine), so nothing above
# can prove the project's "target bash 3.2" rule. macOS's system bash IS 3.2.57: render the same frame
# through it and demand byte-identical output, so a bash-4-only construct fails here and not on a user's
# machine. A missing /bin/bash is reported as a skip, never counted as a pass.
if [ -x /bin/bash ]; then
  sa1p=$(samk claude-haiku-4-5 200000 DESCR LABEL 120 50000 running)
  sa1a=$(printf '%s' "$sa1p" | env HOME="$FAKE_HOME" bash "$SASCRIPT")
  sa1b=$(printf '%s' "$sa1p" | env HOME="$FAKE_HOME" /bin/bash "$SASCRIPT")
  if [ -n "$sa1b" ] && [ "$sa1a" = "$sa1b" ]; then :; else
    echo "  ★ FAIL system bash 3.2 renders differently from PATH bash"; echo "    PATH bash: [$sa1a]"; echo "    bash 3.2 : [$sa1b]"; sa1bad=1
  fi
else
  echo "  NOTE /bin/bash absent — the bash 3.2 cross-check did NOT run and is NOT a pass"
fi
[ "$sa1bad" -eq 0 ] && echo "  sonnet-5 / opus-5[1m] / haiku-4-5 / opus-4-8 / 3 verbatim-fallback shapes + bash 3.2 parity OK" || fail=1

echo "── SA2. SUBAGENT: Absent fields fall back to Claude Code's default row (each guard isolated)"
sa2bad=0
# (a) the smoke-test row captured alongside the real frames: id + name only. NOTE it is missing model AND
#     description AND label at once, so on its own it proves nothing about WHICH guard rejected it — (e)
#     and (f) below isolate the two that this row cannot. Keep it anyway: it is the real captured shape.
sa2out=$(sarun '{"columns":120,"tasks":[{"id":"t1","name":"demo"},'"$SACTL"']}'); sa2rc=$?
[ "$sa2rc" -eq 0 ] || { echo "  ★ FAIL exit $sa2rc on a row carrying no model"; sa2bad=1; }
case "$sa2out" in *t1*) echo "  ★ FAIL a row with no model was emitted: [$sa2out]"; sa2bad=1 ;; esac
sactl_check "$sa2out" || sa2bad=1
# (b) description absent, label present → label is promoted to the first segment and NOT repeated as the third
sa2b=$(sarun "$(samk claude-sonnet-5 1000000 '' PROMOTED 120 50000 running)" | saraw tid | nocol)
[ "$sa2b" = "${SAPFX}Sonnet 5 │ PROMOTED" ] || { echo "  ★ FAIL promoted label: wanted [${SAPFX}Sonnet 5 │ PROMOTED], got [$sa2b]"; sa2bad=1; }
# (c) label absent → the third segment and the separator before it are both gone
sa2c=$(sarun "$(samk claude-sonnet-5 1000000 DESCR '' 120 50000 running)" | saraw tid | nocol)
[ "$sa2c" = "${SAPFX}Sonnet 5 │ DESCR" ] || { echo "  ★ FAIL missing label: wanted [${SAPFX}Sonnet 5 │ DESCR], got [$sa2c]"; sa2bad=1; }
# (d) neither description nor label → the row cannot be attributed to any task, so it keeps its default row
sa2d=$(sarun '{"columns":120,"tasks":[{"id":"noTextRow","status":"running","model":"claude-sonnet-5","contextWindowSize":1000000},'"$SACTL"']}')
case "$sa2d" in *noTextRow*) echo "  ★ FAIL row with no description and no label was emitted: [$sa2d]"; sa2bad=1 ;; esac
sactl_check "$sa2d" || sa2bad=1
# (e) model absent but description AND label both present — the case (a) cannot see. Without this fixture,
#     deleting the model check leaves the whole suite green while a row renders with an EMPTY model segment,
#     which is precisely the "never show a wrong model" rule inverted.
sa2e=$(sarun '{"columns":120,"tasks":[{"id":"noModelRow","status":"running","description":"DESCR","label":"LABEL"},'"$SACTL"']}'); sa2erc=$?
[ "$sa2erc" -eq 0 ] || { echo "  ★ FAIL exit $sa2erc on a row with no model but a full description and label"; sa2bad=1; }
case "$sa2e" in *noModelRow*) echo "  ★ FAIL model-less row emitted despite having description+label: [$sa2e]"; sa2bad=1 ;; esac
sactl_check "$sa2e" || sa2bad=1
# (f) id absent, everything else present. An emitted record keyed on an empty id addresses no row at all, and
#     Claude Code would be handed {"id":"",…}. Nothing else in the suite feeds an id-less task.
sa2f=$(sarun '{"columns":120,"tasks":[{"status":"running","model":"claude-sonnet-5","contextWindowSize":1000000,"description":"IDLESS","label":"IDLESS"},'"$SACTL"']}')
case "$sa2f" in *IDLESS*) echo "  ★ FAIL row with no id was emitted: [$sa2f]"; sa2bad=1 ;; esac
sactl_check "$sa2f" || sa2bad=1
[ "$sa2bad" -eq 0 ] && echo "  no-model(x2) / no-id / promoted-label / dropped-label / unattributable all fall back OK" || fail=1

echo "── SA2B. SUBAGENT: An activity label that only repeats the description is dropped"
# Claude Code fills `label` with the description while a subagent is starting and has no concrete action
# yet, so 45 of the 316 rows in the captured sample (14%) print the same sentence twice. Equal after
# trimming → drop the label cell and the separator before it. Trimming is the ONLY normalisation:
# no case folding, no width folding, no squeezing of inner whitespace — those would silently merge two
# genuinely different strings, and showing the real activity matters more than saving one segment.
sa2bbad=0
# (a) identical → the label cell is gone (six cells), and it is the LABEL that went, not the description
sa2ba=$(sarun "$(samk claude-sonnet-5 1000000 SAMETEXT SAMETEXT 120 50000 running)" | saraw tid | nocol)
[ "$sa2ba" = "${SAPFX}Sonnet 5 │ SAMETEXT" ] || { echo "  ★ FAIL identical label not dropped: wanted [${SAPFX}Sonnet 5 │ SAMETEXT], got [$sa2ba]"; sa2bbad=1; }
# (b) identical only after trimming → still dropped; the description keeps its own spacing verbatim
# The exact string matters, not just the segment count: the two candidates differ ONLY in their
# surrounding spaces, so comparing text is the one way to prove the DESCRIPTION was kept and the label
# dropped rather than the other way round. A segment count cannot tell those two apart.
sa2bb=$(sarun "$(samk claude-sonnet-5 1000000 '  SAMETEXT  ' SAMETEXT 120 50000 running)" | saraw tid | nocol)
sa2bbn=$(printf '%s' "$sa2bb" | sasegs)
[ "$sa2bbn" -eq 6 ] || { echo "  ★ FAIL label differing only by surrounding spaces was kept ($sa2bbn segments): [$sa2bb]"; sa2bbad=1; }
[ "$sa2bb" = "${SAPFX}Sonnet 5 │   SAMETEXT  " ] || { echo "  ★ FAIL kept the label instead of the description (spacing differs): got [$sa2bb]"; sa2bbad=1; }
# (c) CONTROL: genuinely different → all seven cells survive. Guards against fixing (a) by always
#     dropping the label.
sa2bc=$(sarun "$(samk claude-sonnet-5 1000000 DESCR LABEL 120 50000 running)" | saraw tid | nocol)
[ "$sa2bc" = "${SAPFX}Sonnet 5 │ DESCR │ LABEL" ] || { echo "  ★ FAIL different label was not kept: wanted [${SAPFX}Sonnet 5 │ DESCR │ LABEL], got [$sa2bc]"; sa2bbad=1; }
# (d) CONTROL: differing only in case is NOT the same string — no case folding
sa2bd=$(sarun "$(samk claude-sonnet-5 1000000 'Run Tests' 'run tests' 120 50000 running)" | saraw tid | nocol)
sa2bdn=$(printf '%s' "$sa2bd" | sasegs)
[ "$sa2bdn" -eq 7 ] || { echo "  ★ FAIL case-folded comparison dropped a different label ($sa2bdn segments): [$sa2bd]"; sa2bbad=1; }
# (e) CONTROL: differing only in inner whitespace is NOT the same string — no whitespace squeezing
sa2be=$(sarun "$(samk claude-sonnet-5 1000000 'a  b' 'a b' 120 50000 running)" | saraw tid | nocol)
sa2ben=$(printf '%s' "$sa2be" | sasegs)
[ "$sa2ben" -eq 7 ] || { echo "  ★ FAIL inner whitespace was squeezed before comparing ($sa2ben segments): [$sa2be]"; sa2bbad=1; }
# (f) the real captured shape this rule exists for
sa2bf=$(sarun '{"columns":160,"tasks":[{"id":"tid","type":"local_agent","status":"running","description":"Codex: review relay guard design","label":"Codex: review relay guard design","model":"claude-sonnet-5","contextWindowSize":1000000}]}' | saraw tid | nocol)
[ "$sa2bf" = "RUN  │     - │   - │    - │ Sonnet 5 │ Codex: review relay guard design" ] || { echo "  ★ FAIL real duplicated frame: [$sa2bf]"; sa2bbad=1; }
[ "$sa2bbad" -eq 0 ] && echo "  identical / trim-identical dropped; different, case-differing, spacing-differing all kept OK" || fail=1

echo "── SA2T. SUBAGENT: Token usage cell — position, colour, placeholders, and dropped whole, never cut"
# The user asked to see how many tokens each subagent has burned. The cell sits AFTER the context percentage and
# BEFORE the model cell, with the thousands unit as an uppercase K.
# Colour is WH, deliberately NOT YL: the single status line uses YL for its own subagent-token total, and a warning
# colour on a plain count would read as an alarm that is not there.
sa2tbad=0
# (a) position and format together — one exact string covers order, separator count and the K form
sa2ta=$(sarun "$(samk claude-sonnet-5 1000000 DESCR LABEL 120 262414 running)" | saraw tid | nocol)
[ "$sa2ta" = "RUN  │     - │ 26% │ 262K │ Sonnet 5 │ DESCR │ LABEL" ] || { echo "  ★ FAIL token cell position/format: wanted [RUN  │     - │ 26% │ 262K │ Sonnet 5 │ DESCR │ LABEL], got [$sa2ta]"; sa2tbad=1; }
# (b) colour ROLE is the plain-text one, not the warning one
sa2tb=$(sarun "$(samk claude-sonnet-5 1000000 DESCR LABEL 120 262414 running)" | saraw tid)
sarole "$sa2tb" 3 "$SAWH" "token cell (must be WH, never YL)" || sa2tbad=1
# (c) absent → a "-" placeholder in the cell's own column; nothing else moves
sa2tc=$(sarun "$(samk claude-sonnet-5 1000000 DESCR LABEL 120 '' running)" | saraw tid | nocol)
[ "$sa2tc" = "RUN  │     - │   - │    - │ Sonnet 5 │ DESCR │ LABEL" ] || { echo "  ★ FAIL absent tokenCount: wanted [RUN  │     - │   - │    - │ Sonnet 5 │ DESCR │ LABEL], got [$sa2tc]"; sa2tbad=1; }
# (d) non-numeric → the same placeholder, and the rest of the payload still renders
sa2td=$(sarun '{"columns":120,"tasks":[{"id":"tid","status":"running","model":"claude-sonnet-5","contextWindowSize":1000000,"description":"DESCR","label":"LABEL","tokenCount":"abc"},'"$SACTL"']}')
sa2tdc=$(printf '%s' "$sa2td" | saraw tid | nocol)
[ "$sa2tdc" = "RUN  │     - │   - │    - │ Sonnet 5 │ DESCR │ LABEL" ] || { echo "  ★ FAIL non-numeric tokenCount: wanted [RUN  │     - │   - │    - │ Sonnet 5 │ DESCR │ LABEL], got [$sa2tdc]"; sa2tbad=1; }
sactl_check "$sa2td" || sa2tbad=1
# (e) zero is a real count and prints 0 (and 0%), never a placeholder and never omitted
sa2te=$(sarun "$(samk claude-sonnet-5 1000000 DESCR LABEL 120 0 running)" | saraw tid | nocol)
[ "$sa2te" = "RUN  │     - │  0% │    0 │ Sonnet 5 │ DESCR │ LABEL" ] || { echo "  ★ FAIL zero tokenCount should print 0, got [$sa2te]"; sa2tbad=1; }
# (f) string-typed with a leading zero: jq's tostring erases the JSON type, and bash reads a leading zero
#     as OCTAL. 0262414 as octal is 91916, i.e. a confidently wrong 91K (and a wrong 9%).
sa2tf=$(sarun '{"columns":120,"tasks":[{"id":"tid","status":"running","model":"claude-sonnet-5","contextWindowSize":1000000,"description":"DESCR","label":"LABEL","tokenCount":"0262414"}]}' | saraw tid | nocol)
[ "$sa2tf" = "RUN  │     - │ 26% │ 262K │ Sonnet 5 │ DESCR │ LABEL" ] || { echo "  ★ FAIL leading-zero tokenCount read as octal: wanted [… │ 26% │ 262K │ …], got [$sa2tf]"; sa2tbad=1; }
# (g) narrow: the label is sacrificed first; the token and model cells both survive whole
sa2tg=$(sarun "$(samk claude-sonnet-5 1000000 DESCRIPTION 'a very long activity label that will not fit' 60 262414 running)" | saraw tid | nocol)
sa2tgw=$(printf '%s' "$sa2tg" | vw)
[ "$sa2tgw" -le 60 ] || { echo "  ★ FAIL width $sa2tgw > 60: [$sa2tg]"; sa2tbad=1; }
case "$sa2tg" in *' 262K │ Sonnet 5 │ DESCRIPTION │ a very'*…) ;; *) echo "  ★ FAIL label not the first to shrink at width 60: [$sa2tg]"; sa2tbad=1 ;; esac
# (h) narrower: the label is gone, token and model still whole
sa2th=$(sarun "$(samk claude-sonnet-5 1000000 DESCRIPTION 'a very long activity label that will not fit' 52 262414 running)" | saraw tid | nocol)
[ "$sa2th" = "RUN  │     - │ 26% │ 262K │ Sonnet 5 │ DESCRIPTION" ] || { echo "  ★ FAIL label-dropped tier: wanted [RUN  │     - │ 26% │ 262K │ Sonnet 5 │ DESCRIPTION], got [$sa2th]"; sa2tbad=1; }
# (i) narrower still: the token cell is the next to go, and it goes WHOLE — no cut-down "262" is ever left behind
sa2ti=$(sarun "$(samk claude-sonnet-5 1000000 DESCRIPTION 'a very long activity label' 48 262414 running)" | saraw tid | nocol)
[ "$sa2ti" = "RUN  │     - │ 26% │ Sonnet 5 │ DESCRIPTION" ] || { echo "  ★ FAIL token-dropped tier: wanted [RUN  │     - │ 26% │ Sonnet 5 │ DESCRIPTION], got [$sa2ti]"; sa2tbad=1; }
case "$sa2ti" in *262*) echo "  ★ FAIL a partial token cell survived: [$sa2ti]"; sa2tbad=1 ;; esac
[ "$sa2tbad" -eq 0 ] && echo "  position/format/colour, absent+non-numeric '-', zero '0', octal guard, dropped whole OK" || fail=1
echo "── SA3. SUBAGENT: Per-task subagent line content on real frames + no context-window marker is ever printed"
sa3bad=0
# Real captured frames, embedded verbatim so this section stays hermetic if scratchpad is ever cleared.
SAREAL1='{"session_id":"ceffb128-b1cd-4561-b8a7-0b522a1f582c","cwd":"/Users/will/Downloads/macOS","agent_type":"commander","columns":160,"tasks":[{"id":"ab4c560a44129c990","type":"local_agent","status":"running","description":"實作 wrap-up 感知的 ctx guard","label":"Extracting command-args from wrap-up envelopes","startTime":1788426930573,"model":"claude-opus-5[1m]","contextWindowSize":1000000,"tokenCount":254074,"tokenSamples":[254074],"cwd":"/Users/will/Downloads/macOS"}]}'
SAREAL2='{"columns":160,"tasks":[{"id":"aa0603d3a354ff732","type":"local_agent","status":"running","description":"Remove library-divergence-watch","label":"Reading threshold-watch.sh","startTime":1788427330881,"model":"claude-sonnet-5","contextWindowSize":1000000,"tokenCount":66562},{"id":"acee8f6f3483fcf1f","type":"local_agent","status":"running","description":"Codex: review relay guard design","label":"Codex: review relay guard design","startTime":1788427376910,"model":"claude-sonnet-5","contextWindowSize":1000000,"tokenCount":0}]}'
# The captured startTimes lie weeks in the past, so the elapsed cell keeps growing with the wall clock. It is checked
# for its day form on its own and masked as <E> in the exact-row comparisons, which pin every other cell.
saemask() {  # stdin=visible content → the same with an elapsed cell of the "<n>D<n>H" form replaced by <E>
  python3 -c '
import sys, re
c = sys.stdin.read().rstrip("\n").split(" │ ")
if len(c) > 1 and re.fullmatch(r" *[0-9]+D[0-9]+H", c[1]): c[1] = "<E>"
sys.stdout.write(" │ ".join(c))'
}
sa3j=$(sarun "$SAREAL1" | sajsonl)
case "$sa3j" in "OK 1") ;; *) echo "  ★ FAIL real 1-task frame is not clean JSON Lines: [$sa3j]"; sa3bad=1 ;; esac
sa3a=$(sarun "$SAREAL1" | saraw ab4c560a44129c990 | nocol | saemask)
# tokenCount 254074 of a 1000000 window: 25% and 254K; one token sample is too few for IDLE, so the marker is RUN.
[ "$sa3a" = "RUN  │ <E> │ 25% │ 254K │ Opus 5 │ 實作 wrap-up 感知的 ctx guard │ Extracting command-args from wrap-up envelopes" ] \
  || { echo "  ★ FAIL real frame content: [$sa3a]"; sa3bad=1; }
sa3j2=$(sarun "$SAREAL2" | sajsonl)
case "$sa3j2" in "OK 2") ;; *) echo "  ★ FAIL real 2-task frame did not yield 2 clean records: [$sa3j2]"; sa3bad=1 ;; esac
sa3a2=$(sarun "$SAREAL2" | saraw aa0603d3a354ff732 | nocol | saemask)
[ "$sa3a2" = "RUN  │ <E> │  7% │  66K │ Sonnet 5 │ Remove library-divergence-watch │ Reading threshold-watch.sh" ] \
  || { echo "  ★ FAIL first task of the real 2-task frame: [$sa3a2]"; sa3bad=1; }
# The second task of this captured frame carries label == description (the starting-up shape), so its
# label cell is dropped by the duplicate-label rule in SA2B, and its zero token count prints 0 and 0%.
# Both tasks of the frame must still be emitted — that is what this assertion is here for.
sa3b=$(sarun "$SAREAL2" | saraw acee8f6f3483fcf1f | nocol | saemask)
[ "$sa3b" = "RUN  │ <E> │  0% │    0 │ Sonnet 5 │ Codex: review relay guard design" ] \
  || { echo "  ★ FAIL second task of the real 2-task frame: [$sa3b]"; sa3bad=1; }
# No context-window marker on any window size: the model cell is the name alone, and the window is expressed by the
# context percentage and its window-dependent red threshold instead (REMOVED requirement).
for sa3w in 1000000 200000 ''; do
  sa3d=$(sarun "$(samk claude-sonnet-5 "$sa3w" d l 120 50000 running)" | saraw tid | nocol)
  case "$sa3d" in *'(1M)'*|*'(200K)'*|*'Sonnet 5('*) echo "  ★ FAIL window marker printed for window [$sa3w]: [$sa3d]"; sa3bad=1 ;; esac
  case "$(printf '%s' "$sa3d" | sacell 4)" in 'Sonnet 5') ;; *) echo "  ★ FAIL model cell for window [$sa3w] is not the bare name: [$sa3d]"; sa3bad=1 ;; esac
done
# a STRING-typed window size with a leading zero. jq's tostring erases the JSON type, so the value reaches
# the shell verbatim, and bash reads a leading zero as OCTAL: without the 10# prefix "0200000" evaluates to
# 65536 and 100000 tokens would confidently read as 153%. Same hazard lib/render.sh guards in ctx_aligned_pct.
sa3oct=$(sarun '{"columns":120,"tasks":[{"id":"tid","status":"running","model":"claude-sonnet-5","contextWindowSize":"0200000","tokenCount":100000,"description":"d","label":"l"}]}' | saraw tid | nocol)
[ "$sa3oct" = "RUN  │     - │ 50% │ 100K │ Sonnet 5 │ d │ l" ] || { echo "  ★ FAIL leading-zero window read as octal: wanted [RUN  │     - │ 50% │ 100K │ Sonnet 5 │ d │ l], got [$sa3oct]"; sa3bad=1; }
# window size absent → the percentage cannot be computed and prints "-"; no guessed default window
sa3f=$(sarun "$(samk claude-sonnet-5 '' d l 120 50000 running)" | saraw tid | nocol)
[ "$sa3f" = "RUN  │     - │   - │  50K │ Sonnet 5 │ d │ l" ] || { echo "  ★ FAIL absent window size: wanted [RUN  │     - │   - │  50K │ Sonnet 5 │ d │ l], got [$sa3f]"; sa3bad=1; }
# Every colour role of the text cells on one row, each was unguarded until a mutation run showed that swapping
# the role changed the output with the suite green.
sa3g=$(sarun "$(samk claude-sonnet-5 1000000 DTEXT LTEXT 120 50000 running)" | saraw tid)
for sa3pair in "DTEXT:$SAWH:description" "Sonnet 5:$SAMD:model name" "LTEXT:$SADM:label" " │ :$SASP:separator"; do
  sa3needle=${sa3pair%%:*}; sa3rest=${sa3pair#*:}; sa3want=${sa3rest%:*}; sa3role=${sa3rest##*:}
  sa3r=$(printf '%s' "$sa3g" | sacolat "$sa3needle" "$sa3want")
  [ "$sa3r" = OK ] || { echo "  ★ FAIL $sa3role colour role: $sa3r"; sa3bad=1; }
done
[ "$sa3bad" -eq 0 ] && echo "  real 1-task + 2-task frames, JSON Lines shape, no window marker, octal window, 4 colour roles OK" || fail=1

echo "── SA4. SUBAGENT: Untrusted input is sanitised + Width is bounded by the reported column count"
sa4bad=0
# (a) a raw ESC in a field never reaches the terminal, and the REST of the field survives (a regex-based
#     control-char filter would strip the lot — jq's Oniguruma does not honour \u escapes in a class)
sa4esc=$(sarun "$(samk claude-sonnet-5 1000000 "$(printf 'A\033[1ZmB')" l 120 50000 running)" | saraw tid)
case "$sa4esc" in *$'\033''[1Z'*) echo "  ★ FAIL raw ESC survived into content"; sa4bad=1 ;; esac
case "$(printf '%s' "$sa4esc" | nocol)" in *'A[1ZmB'*) ;; *) echo "  ★ FAIL field was gutted instead of stripped: [$(printf '%s' "$sa4esc" | nocol)]"; sa4bad=1 ;; esac
# (b) the 8-bit C1 CSI (U+009B) is the same injection class as a raw ESC and is stripped too
sa4c1=$(sarun '{"columns":120,"tasks":[{"id":"tid","status":"running","model":"claude-sonnet-5","description":"A\u009b[1ZmB","label":"l"}]}' | saraw tid | nocol)
case "$sa4c1" in *'A[1ZmB'*) ;; *) echo "  ★ FAIL C1 CSI case: [$sa4c1]"; sa4bad=1 ;; esac
case "$sa4c1" in *$'\302\233'*) echo "  ★ FAIL U+009B survived into content"; sa4bad=1 ;; esac
# (c1) a non-object task sitting next to a good one: jq aborts the WHOLE program (rc 5) on a type-mismatched
#      index, which would drop every row rather than the offending one. The control row is the assertion.
sa4mix=$(sarun '{"columns":120,"tasks":["not-an-object",'"$SACTL"',12345]}')
sactl_check "$sa4mix" || sa4bad=1
case "$sa4mix" in *not-an-object*) echo "  ★ FAIL a non-object task produced a record: [$sa4mix]"; sa4bad=1 ;; esac
# (c2) whole-document surprises yield zero records and a clean exit. These assertions are necessarily
#      negative-only — a document with no usable tasks has no room for a control row — so they lean on
#      the positive assertions elsewhere in SA1-SA8 to catch a blanket blackout.
for sa4in in '{"tasks":"not-an-array","columns":120}' '["not","an","object"]' '{"tasks":["not-an-object"],"columns":120}' '' 'not json at all'; do
  sa4o=$(sarun "$sa4in"); sa4rc=$?
  [ "$sa4rc" -eq 0 ] || { echo "  ★ FAIL exit $sa4rc on structurally invalid input [$sa4in]"; sa4bad=1; }
  [ -z "$sa4o" ]     || { echo "  ★ FAIL output on structurally invalid input [$sa4in]: [$sa4o]"; sa4bad=1; }
done
# (d) an 8KB description is capped, so vis_width's quadratic ASCII strip cannot stall the frame
SABIG=$(printf 'x%.0s' $(seq 1 8000))
SECONDS=0
sa4big=$(sarun "$(samk claude-sonnet-5 1000000 "$SABIG" l '' 50000 running)" | saraw tid | vw)
# Exact, so an empty output (script gone, script broken) cannot sail through as "nicely bounded":
# 39 columns of marker, elapsed, ctx%, tokens and model with their separators + 256 capped description + " │ " + "l" = 299.
if [ "$SECONDS" -lt 3 ] && [ "$sa4big" -eq 299 ]; then echo "  8KB description → width $sa4big in ${SECONDS}s OK"
else echo "  ★ FAIL 8KB description: width $sa4big in ${SECONDS}s (want 299 — the 256-codepoint cap plus the other cells)"; sa4bad=1; fi
# (e) too narrow → the activity label is sacrificed FIRST (truncated); description, model and token cells stay whole
sa4n=$(sarun "$(samk claude-sonnet-5 1000000 DESCRIPTION 'a very long activity label that cannot possibly fit' 60 50000 running)" | saraw tid | nocol)
sa4w=$(printf '%s' "$sa4n" | vw)
[ "$sa4w" -le 60 ]      || { echo "  ★ FAIL narrow width $sa4w > 60: [$sa4n]"; sa4bad=1; }
case "$sa4n" in "${SAPFX}Sonnet 5 │ DESCRIPTION │ a"*) ;; *) echo "  ★ FAIL a cell other than the label shrank at width 60: [$sa4n]"; sa4bad=1 ;; esac
case "$sa4n" in *…)                ;; *) echo "  ★ FAIL label dropped instead of truncated: [$sa4n]"; sa4bad=1 ;; esac
# (f) narrower still → label, tokens, model and elapsed are gone and the description is truncated; marker and
#     context percentage SURVIVE INTACT
sa4t=$(sarun "$(samk claude-sonnet-5 1000000 DESCRIPTION 'a very long activity label that cannot possibly fit' 20 50000 running)" | saraw tid | nocol)
sa4tw=$(printf '%s' "$sa4t" | vw)
[ "$sa4tw" -le 20 ]     || { echo "  ★ FAIL narrowest width $sa4tw > 20: [$sa4t]"; sa4bad=1; }
[ "$sa4t" = "RUN  │  5% │ DESCRI…" ] || { echo "  ★ FAIL description-truncated tier at width 20: wanted [RUN  │  5% │ DESCRI…], got [$sa4t]"; sa4bad=1; }
# (f2) narrower than marker + ctx% + one description character + the ellipsis: the description is gone too and
#      marker and ctx% are all that is left. They must still be there — they are never dropped at any width.
sa4core=$(sarun "$(samk claude-sonnet-5 1000000 DESCRIPTION 'a very long activity label' 14 50000 running)" | saraw tid | nocol)
[ "$sa4core" = "RUN  │  5%" ] || { echo "  ★ FAIL narrowest tier lost the marker or the ctx%: wanted [RUN  │  5%], got [$sa4core]"; sa4bad=1; }
# (g) no usable column count → no bounding at all, every cell intact
sa4u=$(sarun "$(samk claude-sonnet-5 1000000 DESCRIPTION 'a very long activity label that cannot possibly fit' '' 50000 running)" | saraw tid | nocol)
[ "$sa4u" = "${SAPFX}Sonnet 5 │ DESCRIPTION │ a very long activity label that cannot possibly fit" ] \
  || { echo "  ★ FAIL unbounded render: [$sa4u]"; sa4bad=1; }
[ "$sa4bad" -eq 0 ] && echo "  ESC/C1 stripped, structural surprises inert, 256-cap, settled narrowing order OK" || fail=1

echo "── SA5. SUBAGENT: seven-cell row — cell order, separators, padding, model padding, colour roles, shared palette"
sa5bad=0
# (a) the 1M Opus example of the spec: every cell, the separator after the marker, every padding width
SA5ROW='RUN  │   12m │ 13% │ 128K │ Opus 5 │ Fold 682173 into 681727 │ Confirming mirror refs unchanged after cleanup'
sa5raw=$(sarun "$(samk 'claude-opus-5[1m]' 1000000 'Fold 682173 into 681727' 'Confirming mirror refs unchanged after cleanup' '' 128000 running "$(sastart 720)")" | saraw tid)
sa5a=$(printf '%s' "$sa5raw" | nocol)
[ "$sa5a" = "$SA5ROW" ] || { echo "  ★ FAIL 1M Opus example row: wanted [$SA5ROW], got [$sa5a]"; sa5bad=1; }
# (b) colour role per cell: marker by class (RUN green), elapsed grey, ctx% and tokens primary text, model, description
#     primary text, label grey; and every separator in the structural grey role
sarole "$sa5raw" 0 "$SAGR" "RUN marker" || sa5bad=1
sarole "$sa5raw" 1 "$SADM" "elapsed cell" || sa5bad=1
sarole "$sa5raw" 2 "$SAWH" "context percentage cell" || sa5bad=1
sarole "$sa5raw" 3 "$SAWH" "token cell" || sa5bad=1
sarole "$sa5raw" 4 "$SAMD" "model cell" || sa5bad=1
sarole "$sa5raw" 5 "$SAWH" "description cell" || sa5bad=1
sarole "$sa5raw" 6 "$SADM" "label cell" || sa5bad=1
sa5sep=$(printf '%s' "$sa5raw" | python3 -c '
import sys, re
s = sys.stdin.read(); n = 0; bad = 0
for m in re.finditer("│", s):
    codes = re.findall(r"\x1b\[[0-9;]*m", s[:m.start()]); n += 1
    if not codes or codes[-1] != sys.argv[1]: bad += 1
print("%d/%d" % (n - bad, n))' "$SASP")
[ "$sa5sep" = "6/6" ] || { echo "  ★ FAIL separators in the structural grey role: $sa5sep (want 6/6)"; sa5bad=1; }
# (c) model names are padded to the widest name among the rows of the same invocation, so description cells align
sa5out=$(sarun '{"columns":200,"tasks":[{"id":"a1","status":"running","model":"claude-opus-5[1m]","contextWindowSize":1000000,"tokenCount":1000,"description":"D","label":"L"},{"id":"b2","status":"running","model":"claude-sonnet-5","contextWindowSize":1000000,"tokenCount":1000,"description":"D","label":"L"}]}')
sa5o1=$(printf '%s' "$sa5out" | saraw a1 | nocol); sa5o2=$(printf '%s' "$sa5out" | saraw b2 | nocol)
[ "$sa5o1" = "RUN  │     - │  0% │   1K │ Opus 5   │ D │ L" ] || { echo "  ★ FAIL Opus row not padded to the widest model name: [$sa5o1]"; sa5bad=1; }
[ "$sa5o2" = "RUN  │     - │  0% │   1K │ Sonnet 5 │ D │ L" ] || { echo "  ★ FAIL Sonnet row: [$sa5o2]"; sa5bad=1; }
# (d) machine-readable line by line: two classified tasks give two JSON objects, in input order, with exactly id+content
sa5j=$(printf '%s\n' "$sa5out" | sajsonl)
[ "$sa5j" = "OK 2" ] || { echo "  ★ FAIL two tasks did not give two clean JSON Lines records: [$sa5j]"; sa5bad=1; }
sa5ids=$(printf '%s\n' "$sa5out" | python3 -c 'import sys, json; print(" ".join(json.loads(l)["id"] for l in sys.stdin if l.strip()))')
[ "$sa5ids" = "a1 b2" ] || { echo "  ★ FAIL record order: [$sa5ids], want [a1 b2]"; sa5bad=1; }
# (e) a missing label drops the trailing cell and its separator: the row ends with the description, five separators
sa5e=$(sarun "$(samk claude-sonnet-5 1000000 DESCR '' '' 5000 running)" | saraw tid | nocol)
[ "$sa5e" = "RUN  │     - │  1% │   5K │ Sonnet 5 │ DESCR" ] || { echo "  ★ FAIL missing label: [$sa5e]"; sa5bad=1; }
[ "$(printf '%s' "$sa5e" | sasegs)" = 6 ] || { echo "  ★ FAIL missing label: not exactly five separators: [$sa5e]"; sa5bad=1; }
# (f) the palette comes from the shared loader: under a light theme a FAIL marker carries the light RD bytes, and the
#     script defines no colour of its own. The light HOME is a separate fake HOME so no other section sees the theme.
SALIGHT="$WORK/sa-light-home"; mkdir -p "$SALIGHT/.claude"; printf '{"theme":"light"}\n' > "$SALIGHT/.claude.json"
SARDL=$( . "$SL/lib/render.sh"; _theme="light"; STYLE="$SASTYLE"; load_palette; printf '%s' "$RD" )
[ "$SARDL" != "$SARD" ] || { echo "  ★ FAIL light and dark RD are the same bytes, so the light-theme case proves nothing"; sa5bad=1; }
sa5l=$(printf '%s' "$(samk claude-sonnet-5 1000000 DESCR LABEL 120 5000 failed)" | env HOME="$SALIGHT" bash "$SASCRIPT" | saraw tid)
sarole "$sa5l" 0 "$SARDL" "light-theme FAIL marker" || sa5bad=1
sa5lit=$(grep -c '38;2;' "$SASCRIPT")
[ "$sa5lit" -eq 0 ] || { echo "  ★ FAIL subagent-status-line.sh carries $sa5lit colour literal line(s) of its own"; sa5bad=1; }
[ "$sa5bad" -eq 0 ] && echo "  1M Opus example row, 7 cell colours + 6 separators, model padding, JSON Lines order, missing label, light palette OK" || fail=1

echo "── SA6. SUBAGENT: Task status marker — classification table, the 15-pair IDLE rule, marker colours, unclassified status"
sa6bad=0
SA16=$(sarep 100 16)
sa6case() {  # $1=status ("" omits) $2=tokenSamples JSON ("" omits) $3=expected marker cell (padded) $4=what
  local got
  got=$(sarun "$(samk claude-sonnet-5 1000000 DESCR LABEL 120 5000 "$1" '' "$2")" | saraw tid | nocol | sacell 0)
  [ "$got" = "$3" ] || { echo "  ★ FAIL $4: wanted marker [$3], got [$got]"; sa6bad=1; }
}
sa6case running "$SA16" "IDLE" "16 equal samples"
sa6case running "[100,100,100,100,100,100,100,100,90,90,90,90,90,90,90,90]" "IDLE" "16 samples, one decrease, no increase"
sa6case running "[100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,101]" "RUN " "16 samples, the last one greater"
sa6case running "[100,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101]" "RUN " "16 samples, only the second greater than the first"
sa6case running "$(sarep 100 15)" "RUN " "15 equal samples (not enough evidence)"
sa6case running '[100,100,100,100,100,100,100,"100",100,100,100,100,100,100,100,100]' "RUN " "16 samples with one string"
sa6case running "" "RUN " "tokenSamples absent"
sa6case running "[1,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100]" "IDLE" "17 samples, only the last 16 compared"
sa6case pending "" "PEND" "pending"
sa6case paused "$SA16" "PAUS" "paused with 16 equal samples"
sa6case failed "$SA16" "FAIL" "failed"
sa6case killed "[1,2,3]" "KILL" "killed"
sa6case completed "$SA16" "DONE" "completed with 16 equal samples"
sa6case completed "" "DONE" "completed without samples"
# The status string is compared exactly and is never rendered.
sa6raw=$(sarun "$(samk claude-sonnet-5 1000000 DESCR LABEL 120 5000 running)" | saraw tid | nocol)
case "$sa6raw" in *running*) echo "  ★ FAIL the payload status string was rendered: [$sa6raw]"; sa6bad=1 ;; esac
# Unclassified (absent, unknown, or a different case) → no record, so Claude Code keeps its default row; the control row
# next to it proves the guard, not a blackout.
for sa6st in mystery Running ABSENT; do
  if [ "$sa6st" = ABSENT ]; then sa6t='{"id":"tid","model":"claude-sonnet-5","contextWindowSize":1000000,"tokenCount":5000,"description":"DESCR","label":"LABEL"}'
  else sa6t='{"id":"tid","status":"'"$sa6st"'","model":"claude-sonnet-5","contextWindowSize":1000000,"tokenCount":5000,"description":"DESCR","label":"LABEL"}'; fi
  sa6o=$(sarun '{"columns":120,"tasks":['"$sa6t"','"$SACTL"']}')
  case "$sa6o" in *'"tid"'*) echo "  ★ FAIL a task with status [$sa6st] was emitted: [$sa6o]"; sa6bad=1 ;; esac
  sactl_check "$sa6o" || sa6bad=1
done
# Marker colours follow the class.
for sa6pair in "running|$SA16|IDLE|$SADM" "running||RUN|$SAGR" "completed||DONE|$SAGR" "pending||PEND|$SADM" \
               "paused||PAUS|$SAOG" "failed||FAIL|$SARD" "killed||KILL|$SARD"; do
  sa6s=${sa6pair%%|*}; sa6r=${sa6pair#*|}; sa6smp=${sa6r%%|*}; sa6r=${sa6r#*|}; sa6m=${sa6r%%|*}; sa6want=${sa6r#*|}
  sa6c=$(sarun "$(samk claude-sonnet-5 1000000 DESCR LABEL 120 5000 "$sa6s" '' "$sa6smp")" | saraw tid)
  sarole "$sa6c" 0 "$sa6want" "$sa6m marker" || sa6bad=1
done
[ "$sa6bad" -eq 0 ] && echo "  14 classification cases, status never rendered, 3 unclassified shapes keep the default row, 7 marker colours OK" || fail=1

echo "── SA7. SUBAGENT: elapsed, context percentage and token cells — formats, thresholds, pending values, placeholders"
sa7bad=0
sa7cell() {  # $1=payload $2=cell index $3=expected cell (padded) $4=what [$5=expected SGR of the cell]
  local raw got
  raw=$(sarun "$1" | saraw tid)
  got=$(printf '%s' "$raw" | nocol | sacell "$2")
  [ "$got" = "$3" ] || { echo "  ★ FAIL $4: wanted [$3], got [$got]"; sa7bad=1; return; }
  [ -z "${5-}" ] || sarole "$raw" "$2" "$5" "$4" || sa7bad=1
}
# elapsed: now - startTime, whole seconds, clamped at 0; under 60 s in seconds, from 60 s in fmt_dur's forms
for sa7p in "0|   0s" "45|  45s" "59|  59s" "60|   1m" "720|  12m" "4500|1H15m" "-100|   0s"; do
  sa7n=${sa7p%%|*}; sa7w=${sa7p#*|}
  sa7cell "$(samk claude-sonnet-5 1000000 D L 120 5000 running "$(sastart "$sa7n")")" 1 "$sa7w" "elapsed ${sa7n}s" "$SADM"
done
sa7cell "$(samk claude-sonnet-5 1000000 D L 120 5000 running)" 1 "    -" "elapsed with startTime absent"
sa7cell "$(samk claude-sonnet-5 1000000 D L 120 5000 pending)" 1 "    -" "elapsed with startTime absent on a pending row"
sa7cell "$(samk claude-sonnet-5 1000000 D L 120 5000 completed "$(sastart 720)")" 1 "  12m" "elapsed keeps counting on a completed row"
sa7cell '{"columns":120,"tasks":[{"id":"tid","status":"running","model":"claude-sonnet-5","contextWindowSize":1000000,"tokenCount":5000,"description":"D","label":"L","startTime":"abc"}]}' 1 "    -" "elapsed with a non-numeric startTime"
# context percentage: round half up of 100 * tokenCount / contextWindowSize; red above 92 on a 1M window, above 80 below it
for sa7p in "128000|1000000|running|13%|$SAWH" "850000|1000000|running|85%|$SAWH" "920000|1000000|running|92%|$SAWH" \
            "930000|1000000|running|93%|$SARD" "168000|200000|paused|84%|$SARD" "160000|200000|running|80%|$SAWH" \
            "162000|200000|running|81%|$SARD" "|200000|running|  -|$SAWH" "0|200000|pending| 0%|$SADM" \
            "||pending| 0%|$SADM" "950000|1000000|pending|95%|$SADM" "5000|1000000|running| 1%|$SAWH" \
            "4999|1000000|running| 0%|$SAWH" "5000||running|  -|$SAWH" "5000|0|running|  -|$SAWH"; do
  sa7t=${sa7p%%|*}; sa7r=${sa7p#*|}; sa7win=${sa7r%%|*}; sa7r=${sa7r#*|}; sa7s=${sa7r%%|*}; sa7r=${sa7r#*|}
  sa7w=${sa7r%%|*}; sa7c=${sa7r#*|}
  sa7cell "$(samk claude-sonnet-5 "$sa7win" D L 120 "$sa7t" "$sa7s")" 2 "$sa7w" "ctx% tokens=[$sa7t] window=[$sa7win] $sa7s" "$sa7c"
done
sa7cell '{"columns":120,"tasks":[{"id":"tid","status":"running","model":"claude-sonnet-5","contextWindowSize":1000000,"tokenCount":"abc","description":"D","label":"L"}]}' 2 "  -" "ctx% with a non-numeric tokenCount"
# token usage: fmt_tok with an uppercase K; 0 prints 0; absent or unusable prints -, or 0 on a pending row
for sa7p in "9000|running|  9K|$SAWH" "1200000|running|1.2M|$SAWH" "512|running| 512|$SAWH" "0|running|   0|$SAWH" \
            "128000|running|128K|$SAWH" "|running|   -|$SAWH" "|pending|   0|$SADM" "5000|pending|  5K|$SADM"; do
  sa7t=${sa7p%%|*}; sa7r=${sa7p#*|}; sa7s=${sa7r%%|*}; sa7r=${sa7r#*|}; sa7w=${sa7r%%|*}; sa7c=${sa7r#*|}
  sa7cell "$(samk claude-sonnet-5 1000000 D L 120 "$sa7t" "$sa7s")" 3 "$sa7w" "tokens [$sa7t] $sa7s" "$sa7c"
done
sa7cell '{"columns":120,"tasks":[{"id":"tid","status":"running","model":"claude-sonnet-5","contextWindowSize":1000000,"tokenCount":"abc","description":"D","label":"L"}]}' 3 "   -" "tokens non-numeric"
sa7cell '{"columns":120,"tasks":[{"id":"tid","status":"running","model":"claude-sonnet-5","contextWindowSize":1000000,"tokenCount":"0262414","description":"D","label":"L"}]}' 3 "262K" "tokens with a leading zero (octal guard)"
[ "$sa7bad" -eq 0 ] && echo "  elapsed table + placeholders, ctx% table with 80/92 thresholds and pending rows, token table with K/0/-/octal OK" || fail=1

echo "── SA8. SUBAGENT: Width is bounded by the reported column count — the settled narrowing order, per-row independence"
sa8bad=0
SA8D='Build image and deliver OTA'; SA8L='Polling build-final-2106.log for make_release DONE'
sa8mk() { samk 'claude-opus-5[1m]' 1000000 "$SA8D" "$SA8L" "$1" 60000 running "$(sastart 4500)" "$SA16"; }
sa8row() {  # $1=columns $2=expected exact row ("" = check $3/$4 instead) $3=expected prefix $4=step name
  local got w
  got=$(sarun "$(sa8mk "$1")" | saraw tid | nocol)
  if [ -n "$2" ]; then
    [ "$got" = "$2" ] || { echo "  ★ FAIL $4 at $1 columns: wanted [$2], got [$got]"; sa8bad=1; return; }
  else
    case "$got" in "$3"*…) ;; *) echo "  ★ FAIL $4 at $1 columns: wanted [$3…], got [$got]"; sa8bad=1; return ;; esac
  fi
  w=$(printf '%s' "$got" | vw)
  [ "$w" -le "$1" ] || [ "$1" -lt 10 ] || { echo "  ★ FAIL width $w > $1: [$got]"; sa8bad=1; }
}
sa8row 117 "IDLE │ 1H15m │  6% │  60K │ Opus 5 │ $SA8D │ $SA8L" "" "full row"
sa8row 90  "" "IDLE │ 1H15m │  6% │  60K │ Opus 5 │ $SA8D │ Polling build-" "label truncated"
sa8row 66  "IDLE │ 1H15m │  6% │  60K │ Opus 5 │ $SA8D" "" "label dropped"
sa8row 63  "IDLE │ 1H15m │  6% │ Opus 5 │ $SA8D" "" "tokens dropped"
sa8row 56  "IDLE │ 1H15m │  6% │ $SA8D" "" "model dropped"
sa8row 47  "IDLE │  6% │ $SA8D" "" "elapsed dropped"
sa8row 30  "" "IDLE │  6% │ Build" "description truncated"
sa8row 12  "IDLE │  6%" "" "marker and ctx% only"
# marker + ctx% survive even when they alone exceed the column count (Claude Code truncates what is left)
sa8row 5   "IDLE │  6%" "" "marker and ctx% below their own width"
# no usable column count → no bounding
sa8u=$(sarun "$(sa8mk '')" | saraw tid | nocol)
[ "$sa8u" = "IDLE │ 1H15m │  6% │  60K │ Opus 5 │ $SA8D │ $SA8L" ] || { echo "  ★ FAIL unbounded row: [$sa8u]"; sa8bad=1; }
# every row is narrowed on its own: at 66 columns a short description keeps its token cell (label truncated) while a long
# one in the same payload has to give up tokens, model and elapsed
sa8two=$(jq -cn --argjson st "$(sastart 4500)" --argjson smp "$SA16" '{columns:66, tasks:[
  {id:"short", status:"running", model:"claude-opus-5[1m]", contextWindowSize:1000000, tokenCount:60000, startTime:$st, tokenSamples:$smp,
   description:"short", label:"Polling build-final-2106.log for make_release DONE"},
  {id:"long", status:"running", model:"claude-opus-5[1m]", contextWindowSize:1000000, tokenCount:60000, startTime:$st, tokenSamples:$smp,
   description:"Build image and deliver OTA and then verify every partition", label:"Polling build-final-2106.log for make_release DONE"}]}')
sa8o=$(sarun "$sa8two")
sa8s=$(printf '%s' "$sa8o" | saraw short | nocol); sa8l=$(printf '%s' "$sa8o" | saraw long | nocol)
case "$sa8s" in "IDLE │ 1H15m │  6% │  60K │ Opus 5 │ short │ Polling"*…) ;; *) echo "  ★ FAIL short row at 66 columns: [$sa8s]"; sa8bad=1 ;; esac
case "$sa8l" in "IDLE │  6% │ Build image"*…) ;; *) echo "  ★ FAIL long row at 66 columns: [$sa8l]"; sa8bad=1 ;; esac
for sa8x in "$sa8s" "$sa8l"; do [ "$(printf '%s' "$sa8x" | vw)" -le 66 ] || { echo "  ★ FAIL row wider than 66: [$sa8x]"; sa8bad=1; }; done
# Row count, order and folding are left to Claude Code: seven classified tasks give seven non-empty records, in input order
sa8seven=$(jq -cn --argjson smp "$SA16" '{columns:120, tasks:[
  {id:"s1", status:"running", tokenSamples:$smp}, {id:"s2", status:"running"}, {id:"s3", status:"completed"},
  {id:"s4", status:"failed"}, {id:"s5", status:"killed"}, {id:"s6", status:"paused"}, {id:"s7", status:"pending"}]
  | map(. + {model:"claude-sonnet-5", contextWindowSize:1000000, tokenCount:5000, description:("task " + .id)})}')
sa8seo=$(sarun "$sa8seven")
sa8sev=$(printf '%s\n' "$sa8seo" | python3 -c '
import sys, json, re
out = []
for l in sys.stdin:
    if not l.strip(): continue
    o = json.loads(l); c = re.sub(r"\x1b\[[0-9;]*m", "", o["content"])
    out.append("%s:%s" % (o["id"], c[:4] if c else "<empty>"))
print(" ".join(out))')
[ "$sa8sev" = "s1:IDLE s2:RUN  s3:DONE s4:FAIL s5:KILL s6:PAUS s7:PEND" ] \
  || { echo "  ★ FAIL seven classified tasks: wanted [s1:IDLE s2:RUN  s3:DONE s4:FAIL s5:KILL s6:PAUS s7:PEND], got [$sa8sev]"; sa8bad=1; }
[ "$sa8bad" -eq 0 ] && echo "  8-width IDLE table, marker+ctx% floor, unbounded, per-row independence, 7 records in order OK" || fail=1

echo "── SA9. SUBAGENT: per-session state file — content, permissions, UUID gate, refusals, counting, mtime sweep"
# subagent-status-line.sh hands its per-class counts to the session line through ~/.claude/sl-subagents/<session_id>:
# one line "V1 <epoch> <FAIL> <KILL> <PAUS> <RUN> <IDLE> <PEND> <DONE>", written atomically on every invocation whose
# session_id is a real Claude Code UUID. Every case runs in its OWN fake HOME, so no case can see another's files, and
# the payloads carry no startTime, so stdout does not depend on the clock and can be compared byte for byte.
sa9bad=0
SA9SID=0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d
sa9n=0
sa9home() {  # → a fresh fake HOME holding an empty .claude, path in _h
  sa9n=$((sa9n + 1)); _h="$WORK/sa9-home-$sa9n"; mkdir -p "$_h/.claude"
}
sa9run() { printf '%s' "$2" | env HOME="$1" bash "$SASCRIPT"; }   # $1=HOME $2=payload → JSON Lines
sa9pay() {  # $1=session id ("ABSENT" omits the key) $2=JSON array of tasks → payload
  if [ "$1" = ABSENT ]; then jq -cn --argjson t "$2" '{columns:120, tasks:$t}'
  else jq -cn --arg s "$1" --argjson t "$2" '{session_id:$s, columns:120, tasks:$t}'; fi
}
sa9tasks() {  # $@="<kind>:<count>" with kind running|idle|pending|paused|failed|killed|completed|mystery → JSON array
  local a="" kind cnt i st smp
  for p in "$@"; do
    kind=${p%%:*}; cnt=${p#*:}; i=0
    while [ "$i" -lt "$cnt" ]; do
      st=$kind; smp=""; [ "$kind" != idle ] || { st=running; smp=",\"tokenSamples\":$SA16"; }
      a="$a${a:+,}{\"id\":\"$kind$i\",\"status\":\"$st\",\"model\":\"claude-sonnet-5\",\"contextWindowSize\":1000000,\"tokenCount\":5000,\"description\":\"task $kind $i\"$smp}"
      i=$((i + 1))
    done
  done
  printf '[%s]' "$a"
}
sa9line() {  # $1=state file $2=epoch lower bound $3=epoch upper bound → the counts after the epoch, or why not
  python3 -c '
import sys, re
try: b = open(sys.argv[1], "rb").read()
except Exception as e: print("unreadable: %s" % e.__class__.__name__); sys.exit(0)
m = re.fullmatch(rb"V1 (0|[1-9][0-9]*)((?: (?:0|[1-9][0-9]*)){7})\n", b)
if not m: print("malformed: %r" % b); sys.exit(0)
ep = int(m.group(1))
if not int(sys.argv[2]) <= ep <= int(sys.argv[3]): print("epoch %d outside [%s,%s]" % (ep, sys.argv[2], sys.argv[3])); sys.exit(0)
print(m.group(2).decode().strip())' "$1" "$2" "$3"
}
sa9mode() { stat -f '%Lp' "$1" 2>/dev/null || echo missing; }
SA9REF=$(sa9pay "$SA9SID" "$(sa9tasks running:2 idle:1 completed:1)")
# (a) RUN, RUN, IDLE, DONE → "V1 <now> 0 0 0 2 1 0 1", file 600 in a 700 directory
sa9home; sa9ha=$_h
sa9t0=$(date +%s); sa9out=$(sa9run "$sa9ha" "$SA9REF"); sa9t1=$(date +%s)
sa9f="$sa9ha/.claude/sl-subagents/$SA9SID"
sa9c=$(sa9line "$sa9f" "$sa9t0" "$sa9t1")
[ "$sa9c" = "0 0 0 2 1 0 1" ] || { echo "  ★ FAIL state file for RUN RUN IDLE DONE: wanted [0 0 0 2 1 0 1], got [$sa9c]"; sa9bad=1; }
[ "$(sa9mode "$sa9f")" = 600 ] || { echo "  ★ FAIL state file mode $(sa9mode "$sa9f"), want 600"; sa9bad=1; }
[ "$(sa9mode "$sa9ha/.claude/sl-subagents")" = 700 ] || { echo "  ★ FAIL state directory mode $(sa9mode "$sa9ha/.claude/sl-subagents"), want 700"; sa9bad=1; }
[ "$(printf '%s\n' "$sa9out" | sajsonl)" = "OK 4" ] || { echo "  ★ FAIL the four rows were not emitted next to the state write: [$sa9out]"; sa9bad=1; }
# stdout is byte-identical to the same run whose directory cannot be written, and that run writes nothing
sa9home; mkdir -m 500 "$_h/.claude/sl-subagents"
sa9ro=$(sa9run "$_h" "$SA9REF")
[ "$sa9ro" = "$sa9out" ] || { echo "  ★ FAIL stdout differs when the state directory is unwritable"; sa9bad=1; }
[ -z "$(ls -A "$_h/.claude/sl-subagents")" ] || { echo "  ★ FAIL something was written into an unwritable directory"; sa9bad=1; }
chmod 700 "$_h/.claude/sl-subagents"
# (b) every class in its own field, in the order FAIL KILL PAUS RUN IDLE PEND DONE, canonical decimals (10, not 010)
sa9home
sa9t0=$(date +%s); sa9run "$_h" "$(sa9pay "$SA9SID" "$(sa9tasks failed:1 killed:2 paused:3 running:10 idle:4 pending:5 completed:6)")" >/dev/null; sa9t1=$(date +%s)
sa9c=$(sa9line "$_h/.claude/sl-subagents/$SA9SID" "$sa9t0" "$sa9t1")
[ "$sa9c" = "1 2 3 10 4 5 6" ] || { echo "  ★ FAIL field order / canonical decimals: wanted [1 2 3 10 4 5 6], got [$sa9c]"; sa9bad=1; }
# (c) a session_id that is not a real Claude Code UUID writes nothing — not even the directory — and the rows still render
for sa9sid in sl-sepdemo ../x '' ABSENT 0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D "$SA9SID-x"; do
  sa9home
  sa9o=$(sa9run "$_h" "$(sa9pay "$sa9sid" "$(sa9tasks running:1)")")
  [ ! -e "$_h/.claude/sl-subagents" ] || { echo "  ★ FAIL session id [$sa9sid] created $(ls -A "$_h/.claude/sl-subagents" | head -3)"; sa9bad=1; }
  [ "$(printf '%s\n' "$sa9o" | sajsonl)" = "OK 1" ] || { echo "  ★ FAIL session id [$sa9sid] lost its row: [$sa9o]"; sa9bad=1; }
done
# (d) refused paths: nothing written through them, nothing repaired or removed, stdout unchanged
sa9home; mkdir "$_h/elsewhere"; ln -s "$_h/elsewhere" "$_h/.claude/sl-subagents"
sa9o=$(sa9run "$_h" "$SA9REF")
[ -L "$_h/.claude/sl-subagents" ] && [ -z "$(ls -A "$_h/elsewhere")" ] || { echo "  ★ FAIL written through a linked state directory"; sa9bad=1; }
[ "$sa9o" = "$sa9out" ] || { echo "  ★ FAIL stdout changed with a linked state directory"; sa9bad=1; }
sa9home; printf 'keep\n' > "$_h/.claude/sl-subagents"
sa9o=$(sa9run "$_h" "$SA9REF")
[ -f "$_h/.claude/sl-subagents" ] && [ "$(cat "$_h/.claude/sl-subagents")" = keep ] || { echo "  ★ FAIL a plain file at the directory path was touched"; sa9bad=1; }
[ "$sa9o" = "$sa9out" ] || { echo "  ★ FAIL stdout changed with a plain file at the directory path"; sa9bad=1; }
sa9home; mkdir -m 700 "$_h/.claude/sl-subagents"; printf 'orig\n' > "$_h/target"; ln -s "$_h/target" "$_h/.claude/sl-subagents/$SA9SID"
sa9o=$(sa9run "$_h" "$SA9REF")
[ -L "$_h/.claude/sl-subagents/$SA9SID" ] && [ "$(cat "$_h/target")" = orig ] || { echo "  ★ FAIL written through a linked entry"; sa9bad=1; }
[ "$(ls -A "$_h/.claude/sl-subagents")" = "$SA9SID" ] || { echo "  ★ FAIL leftover next to a linked entry: [$(ls -A "$_h/.claude/sl-subagents")]"; sa9bad=1; }
[ "$sa9o" = "$sa9out" ] || { echo "  ★ FAIL stdout changed with a linked entry"; sa9bad=1; }
sa9home; mkdir -p -m 700 "$_h/.claude/sl-subagents/$SA9SID"
sa9o=$(sa9run "$_h" "$SA9REF")
[ -d "$_h/.claude/sl-subagents/$SA9SID" ] && [ -z "$(ls -A "$_h/.claude/sl-subagents/$SA9SID")" ] || { echo "  ★ FAIL a directory at the entry path was written into"; sa9bad=1; }
[ "$(ls -A "$_h/.claude/sl-subagents")" = "$SA9SID" ] || { echo "  ★ FAIL leftover next to a directory entry: [$(ls -A "$_h/.claude/sl-subagents")]"; sa9bad=1; }
[ "$sa9o" = "$sa9out" ] || { echo "  ★ FAIL stdout changed with a directory at the entry path"; sa9bad=1; }
# An existing temp path: the temp name carries the writer's $$, and `exec` keeps the pid, so the wrapper below plants
# ".<sid>.<its own pid>" and then becomes the script under that same pid.
sa9home; mkdir -m 700 "$_h/.claude/sl-subagents"
sa9o=$(printf '%s' "$SA9REF" | env HOME="$_h" SA9SID="$SA9SID" bash -c 'printf "half" > "$HOME/.claude/sl-subagents/.$SA9SID.$$"; exec bash "$0"' "$SASCRIPT")
sa9tmp=$(ls -A "$_h/.claude/sl-subagents")
case "$sa9tmp" in ".$SA9SID."[0-9]*) [ "$(cat "$_h/.claude/sl-subagents/$sa9tmp")" = half ] || { echo "  ★ FAIL an existing temp file was overwritten"; sa9bad=1; } ;;
  *) echo "  ★ FAIL an existing temp path was not refused, the directory holds [$sa9tmp]"; sa9bad=1 ;; esac
[ "$sa9o" = "$sa9out" ] || { echo "  ★ FAIL stdout changed with an existing temp path"; sa9bad=1; }
# (e) counting depends on classification alone: a failed task without a model gets no record but is counted
sa9home
sa9o=$(sa9run "$_h" "$(sa9pay "$SA9SID" '[{"id":"ok","status":"running","model":"claude-sonnet-5","description":"has a model"},{"id":"nomodel","status":"failed","description":"no model"}]')")
sa9ids=$(printf '%s\n' "$sa9o" | python3 -c 'import sys, json; print(" ".join(json.loads(l)["id"] for l in sys.stdin if l.strip()))')
[ "$sa9ids" = ok ] || { echo "  ★ FAIL records for running + model-less failed: [$sa9ids], want [ok]"; sa9bad=1; }
sa9c=$(sa9line "$_h/.claude/sl-subagents/$SA9SID" 0 9999999999)
[ "$sa9c" = "1 0 0 1 0 0 0" ] || { echo "  ★ FAIL model-less failed task not counted: wanted [1 0 0 1 0 0 0], got [$sa9c]"; sa9bad=1; }
# eight tasks: five running, a completed background agent, a running nested subagent, and a mystery status → total 7,
# more than the five rows Claude Code draws before it folds
sa9home
sa9eight=$(jq -cn --argjson a "$(sa9tasks running:5 completed:1 mystery:1)" '$a + [{id:"nested", status:"running", model:"claude-sonnet-5", contextWindowSize:1000000, tokenCount:5000, description:"nested subagent of running0"}]')
sa9run "$_h" "$(sa9pay "$SA9SID" "$sa9eight")" >/dev/null
sa9c=$(sa9line "$_h/.claude/sl-subagents/$SA9SID" 0 9999999999)
[ "$sa9c" = "0 0 0 6 0 0 1" ] || { echo "  ★ FAIL eight tasks with one mystery: wanted [0 0 0 6 0 0 1], got [$sa9c]"; sa9bad=1; }
# (f) first write of a session sweeps files older than 86400 s by mtime alone; links, directories and young files stay
SA9OLD=$(date -v-2d +%Y%m%d%H%M.%S); SA9NEW=$(date -v-10S +%Y%m%d%H%M.%S)
sa9home; sa9d="$_h/.claude/sl-subagents"; mkdir -m 700 "$sa9d"
printf 'V1 1700000000 0 0 0 1 0 0 0\n' > "$sa9d/11111111-1111-4111-8111-111111111111"; touch -t "$SA9OLD" "$sa9d/11111111-1111-4111-8111-111111111111"
printf 'garbage\n' > "$sa9d/22222222-2222-4222-8222-222222222222"; touch -t "$SA9OLD" "$sa9d/22222222-2222-4222-8222-222222222222"
printf 'garbage\n' > "$sa9d/33333333-3333-4333-8333-333333333333"; touch -t "$SA9NEW" "$sa9d/33333333-3333-4333-8333-333333333333"
printf 'V1 17' > "$sa9d/.44444444-4444-4444-8444-444444444444.12345"; touch -t "$SA9OLD" "$sa9d/.44444444-4444-4444-8444-444444444444.12345"
printf 'V1 17' > "$sa9d/.55555555-5555-4555-8555-555555555555.12346"; touch -t "$SA9NEW" "$sa9d/.55555555-5555-4555-8555-555555555555.12346"
printf 'V1 1700000000 0 0 0 1 0 0 0\n' > "$_h/linktarget"; touch -t "$SA9OLD" "$_h/linktarget"
ln -s "$_h/linktarget" "$sa9d/66666666-6666-4666-8666-666666666666"; touch -h -t "$SA9OLD" "$sa9d/66666666-6666-4666-8666-666666666666"
mkdir "$sa9d/77777777-7777-4777-8777-777777777777"; printf 'inner\n' > "$sa9d/77777777-7777-4777-8777-777777777777/f"
touch -t "$SA9OLD" "$sa9d/77777777-7777-4777-8777-777777777777/f" "$sa9d/77777777-7777-4777-8777-777777777777"
sa9t0=$(date +%s); sa9run "$_h" "$SA9REF" >/dev/null; sa9t1=$(date +%s)
[ "$(sa9line "$sa9d/$SA9SID" "$sa9t0" "$sa9t1")" = "0 0 0 2 1 0 1" ] || { echo "  ★ FAIL this session's entry was not written on the sweeping run"; sa9bad=1; }
[ ! -e "$sa9d/11111111-1111-4111-8111-111111111111" ] || { echo "  ★ FAIL two-day-old valid entry kept"; sa9bad=1; }
[ ! -e "$sa9d/22222222-2222-4222-8222-222222222222" ] || { echo "  ★ FAIL two-day-old garbage entry kept"; sa9bad=1; }
[ -f "$sa9d/33333333-3333-4333-8333-333333333333" ] || { echo "  ★ FAIL 10-second-old garbage entry removed (content must never decide)"; sa9bad=1; }
[ ! -e "$sa9d/.44444444-4444-4444-8444-444444444444.12345" ] || { echo "  ★ FAIL two-day-old temp file kept"; sa9bad=1; }
[ -f "$sa9d/.55555555-5555-4555-8555-555555555555.12346" ] || { echo "  ★ FAIL 10-second-old temp file removed (another writer may be mid-write)"; sa9bad=1; }
[ -L "$sa9d/66666666-6666-4666-8666-666666666666" ] && [ "$(cat "$_h/linktarget")" = "V1 1700000000 0 0 0 1 0 0 0" ] \
  || { echo "  ★ FAIL two-day-old symbolic link or its target removed"; sa9bad=1; }
[ -f "$sa9d/77777777-7777-4777-8777-777777777777/f" ] || { echo "  ★ FAIL two-day-old directory or its contents removed"; sa9bad=1; }
# a steady-state write (this session's entry already present) sweeps nothing
sa9home; sa9d="$_h/.claude/sl-subagents"; mkdir -m 700 "$sa9d"
printf 'V1 1700000000 0 0 0 1 0 0 0\n' > "$sa9d/$SA9SID"
printf 'V1 1700000000 0 0 0 1 0 0 0\n' > "$sa9d/11111111-1111-4111-8111-111111111111"; touch -t "$SA9OLD" "$sa9d/11111111-1111-4111-8111-111111111111"
sa9t0=$(date +%s); sa9run "$_h" "$SA9REF" >/dev/null; sa9t1=$(date +%s)
[ "$(sa9line "$sa9d/$SA9SID" "$sa9t0" "$sa9t1")" = "0 0 0 2 1 0 1" ] || { echo "  ★ FAIL steady-state write did not refresh this session's entry"; sa9bad=1; }
[ -f "$sa9d/11111111-1111-4111-8111-111111111111" ] || { echo "  ★ FAIL a steady-state write swept another session's two-day-old entry"; sa9bad=1; }
[ "$sa9bad" -eq 0 ] && echo "  content + 600/700, unwritable dir, canonical order, 6 refused ids, 5 refused paths, counting, mtime sweep OK" || fail=1

# ── SUBAGENT SUMMARY LINE (SUB1-SUB6) ───────────────────────────────────────────────────────────────────────
# While this session's ~/.claude/sl-subagents/<session_id> holds fresh, well-formed counts with a non-zero total,
# statusline-command.sh prints one summary line ("sub 7 │ FAIL 1 │ …") next to the session line; otherwise it prints
# exactly today's single line. The state file is written by subagent-status-line.sh (SA9). Every frame below carries
# HOME="$FAKE_HOME" (or its own fake HOME), and the frames carry no clock-dependent segment unless a case says so, so
# two frames of the same input can be compared byte for byte.
SUBSID=$SA9SID
SUBDIR="$FAKE_HOME/.claude/sl-subagents"
SUBFULL='sub 7 │ FAIL 1 │ PAUS 1 │ RUN 3 │ IDLE 1 │ PEND 1'
subjson() {  # $1=session id → a session-line frame without rate limits, transcript or cost (no clock-dependent text)
  jq -cn --arg cwd "$GREPO" --arg s "$1" '{workspace:{current_dir:$cwd, project_dir:$cwd},
    model:{display_name:"Opus 4.8 (1M context)"}, context_window:{used_percentage:6.2},
    session_id:$s, session_name:"summary line fixture"}'
}
SUBJ=$(subjson "$SUBSID")
subseed() {  # $1=the seven counts "FAIL KILL PAUS RUN IDLE PEND DONE" $2=epoch offset from now in s (negative = past) [$3=session id]
  mkdir -p "$SUBDIR" && chmod 700 "$SUBDIR"
  printf 'V1 %s %s\n' "$(( $(date +%s) + $2 ))" "$1" > "$SUBDIR/${3:-$SUBSID}"
}
subraw() {  # $1=exact entry content, printf %b escapes honoured → this session's entry
  mkdir -p "$SUBDIR" && chmod 700 "$SUBDIR"
  printf '%b' "$1" > "$SUBDIR/$SUBSID"
}
subclear() { rm -rf "$SUBDIR"; }
subsync() { local s; s=$(date +%s); while [ "$(date +%s)" = "$s" ]; do sleep 0.02; done; }   # start of a fresh second
subframe() {  # $1=COLUMNS [$2=payload, default $SUBJ] → stdout in $WORK/sub.out, stderr in $WORK/sub.err
  printf '%s' "${2:-$SUBJ}" | env COLUMNS="$1" HOME="$FAKE_HOME" bash "$SL/statusline-command.sh" >"$WORK/sub.out" 2>"$WORK/sub.err"
}
subpick() {  # $1=summary|session [$2=output file, default $WORK/sub.out] → that line, raw, no newline ("" when there is none)
  # Which line is which comes from SUB_LINE_POS (SUBPOS, read from the script at the top of this file), never from position.
  python3 -c '
import sys
want, path, pos = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path, "rb").read().decode("utf-8", "replace").split("\n")
if lines and lines[-1] == "": lines.pop()
if len(lines) == 1: summ, sess = "", lines[0]
elif len(lines) == 2: summ, sess = (lines[1], lines[0]) if pos == "below" else (lines[0], lines[1])
else: summ = sess = "<%d lines>" % len(lines)
sys.stdout.write(summ if want == "summary" else sess)' "$1" "${2:-$WORK/sub.out}" "$SUBPOS"
}
subnl() { grep -c '' "${1:-$WORK/sub.out}"; }   # number of output lines
subsepok() {  # stdin=raw summary line → "OK" when every " │ " separator is drawn in the structural grey role
  python3 -c '
import sys, re
s = sys.stdin.read(); sp = sys.argv[1]
n = re.sub(r"\x1b\[[0-9;]*m", "", s).count(" │ "); m = len(re.findall(re.escape(sp) + " │ ", s))
print("OK" if n > 0 and n == m else "%d separators, %d of them in SP" % (n, m))' "$SASP"
}

echo "── SUB1. SUMMARY LINE: content in the settled class order, only non-zero classes, colour roles, trailing reset, line order"
sub1bad=0
subclear; subframe 140; cp "$WORK/sub.out" "$WORK/sub1.base"
subseed "1 0 1 3 1 1 0" 0; subframe 140
sub1s=$(subpick summary)
[ "$(subnl)" = 2 ] || { echo "  ★ FAIL SUB1 FAIL 1 PAUS 1 RUN 3 IDLE 1 PEND 1 gave $(subnl) line(s), want 2: [$(nocol < "$WORK/sub.out")]"; sub1bad=1; }
[ "$(printf '%s' "$sub1s" | nocol)" = "$SUBFULL" ] || { echo "  ★ FAIL SUB1 full distribution: [$(printf '%s' "$sub1s" | nocol)], want [$SUBFULL]"; sub1bad=1; }
[ "$(subpick session)" = "$(subpick session "$WORK/sub1.base")" ] || { echo "  ★ FAIL SUB1 the session line changed next to the summary line"; sub1bad=1; }
case "$sub1s" in *$'\033[0m') ;; *) echo "  ★ FAIL SUB1 the summary line does not end with ESC [ 0 m: $(printf '%q' "${sub1s: -12}")"; sub1bad=1 ;; esac
for sub1c in "sub 7:$SAWH" "FAIL 1:$SARD" "PAUS 1:$SAOG" "RUN 3:$SAGR" "IDLE 1:$SADM" "PEND 1:$SADM"; do
  sub1r=$(printf '%s' "$sub1s" | sacolat "${sub1c%%:*}" "${sub1c#*:}")
  [ "$sub1r" = OK ] || { echo "  ★ FAIL SUB1 colour of [${sub1c%%:*}]: $sub1r"; sub1bad=1; }
done
sub1r=$(printf '%s' "$sub1s" | subsepok); [ "$sub1r" = OK ] || { echo "  ★ FAIL SUB1 separator role: $sub1r"; sub1bad=1; }
# the shipped order: SUB_LINE_POS=above, so the summary line is the FIRST of the two lines
[ "$SUBPOS" = above ] && [ "$(sed -n 1p "$WORK/sub.out")" = "$sub1s" ] && [ -n "$sub1s" ] \
  || { echo "  ★ FAIL SUB1 shipped SUB_LINE_POS is [$SUBPOS] / the summary line is not the first line, want above"; sub1bad=1; }
subseed "0 0 0 3 0 0 0" 0; subframe 140
[ "$(subpick summary | nocol)" = "sub 3 │ RUN 3" ] || { echo "  ★ FAIL SUB1 only non-zero classes: [$(subpick summary | nocol)], want [sub 3 │ RUN 3]"; sub1bad=1; }
subseed "0 1 0 0 0 0 2" 0; subframe 140
sub1s=$(subpick summary)
[ "$(printf '%s' "$sub1s" | nocol)" = "sub 3 │ KILL 1 │ DONE 2" ] || { echo "  ★ FAIL SUB1 KILL and DONE: [$(printf '%s' "$sub1s" | nocol)], want [sub 3 │ KILL 1 │ DONE 2]"; sub1bad=1; }
for sub1c in "KILL 1:$SARD" "DONE 2:$SAGR" "sub 3:$SAWH"; do
  sub1r=$(printf '%s' "$sub1s" | sacolat "${sub1c%%:*}" "${sub1c#*:}")
  [ "$sub1r" = OK ] || { echo "  ★ FAIL SUB1 colour of [${sub1c%%:*}]: $sub1r"; sub1bad=1; }
done
[ ! -s "$WORK/sub.err" ] || { echo "  ★ FAIL SUB1 stderr: [$(head -c 200 "$WORK/sub.err")]"; sub1bad=1; }
[ "$sub1bad" -eq 0 ] && echo "  SUB1 full distribution, non-zero classes only, seven colour roles + SP separators, trailing reset, shipped order above OK" || fail=1

echo "── SUB2. SUMMARY LINE ABSENT: no file, total zero, stale, future, malformed, leading zeros, hostile bytes, links, wrong shapes"
# Every case must leave the output byte-identical to the same frame rendered with no state file: one line, empty stderr.
sub2bad=0
subclear; subframe 140; cp "$WORK/sub.out" "$WORK/sub2.base"
[ "$(subnl "$WORK/sub2.base")" = 1 ] && [ ! -s "$WORK/sub.err" ] || { echo "  ★ FAIL SUB2 baseline frame is not one clean line"; sub2bad=1; }
sub2chk() {  # $1=case label [$2=baseline output file] → assert on the frame just rendered
  cmp -s "$WORK/sub.out" "${2:-$WORK/sub2.base}" \
    || { echo "  ★ FAIL SUB2 $1: output differs from the frame without a state file: [$(head -c 300 "$WORK/sub.out" | nocol)]"; sub2bad=1; }
  [ "$(subnl)" = 1 ] || { echo "  ★ FAIL SUB2 $1: $(subnl) output lines, want 1"; sub2bad=1; }
  [ ! -s "$WORK/sub.err" ] || { echo "  ★ FAIL SUB2 $1: stderr [$(head -c 200 "$WORK/sub.err")]"; sub2bad=1; }
}
subclear; subframe 140; sub2chk "no file"
subseed "0 0 0 0 0 0 0" 0; subframe 140; sub2chk "total zero"
subseed "0 0 0 3 0 0 0" -21; subframe 140; sub2chk "written 21 s ago"
subsync; subseed "0 0 0 3 0 0 0" 6; subframe 140; sub2chk "written 6 s in the future"
subraw "V1 $(date +%s) 0 0 0 3\n"; subframe 140; sub2chk "wrong field count"
subraw "V1 $(date +%s) 0 0 0 3 x 0 0\n"; subframe 140; sub2chk "non-digit field"
subraw "V1 $(date +%s) 0 0 0 08 0 0 0\n"; subframe 140; sub2chk "leading zero 08"
subraw "V1 $(date +%s) 0 0 0 010 0 0 0\n"; subframe 140; sub2chk "leading zero 010"
subraw "V1 $(date +%s)  0 0 0 3 0 0 0\n"; subframe 140; sub2chk "double space"
subraw "V1 $(date +%s) 0 0 0 \033[31m3 0 0 0\n"; subframe 140; sub2chk "escape sequence"
subraw "V1 $(date +%s) 0 0 0 \302\2333 0 0 0\n"; subframe 140; sub2chk "C1 byte"
subraw "V1 $(date +%s) 0 0 0 $(head -c 4096 /dev/zero | tr '\0' '1') 0 0 0\n"; subframe 140; sub2chk "4 KB line"
subclear; mkdir -p "$WORK/sub2t"; printf 'V1 %s 0 0 0 3 0 0 0\n' "$(date +%s)" > "$WORK/sub2t/target"
mkdir -m 700 "$SUBDIR"; ln -s "$WORK/sub2t/target" "$SUBDIR/$SUBSID"; subframe 140; sub2chk "linked entry"
subclear; mkdir -p "$WORK/sub2d"; printf 'V1 %s 0 0 0 3 0 0 0\n' "$(date +%s)" > "$WORK/sub2d/$SUBSID"
ln -s "$WORK/sub2d" "$SUBDIR"; subframe 140; sub2chk "linked directory"
rm -f "$SUBDIR"; printf 'V1 %s 0 0 0 3 0 0 0\n' "$(date +%s)" > "$SUBDIR"; subframe 140; sub2chk "plain file at the directory path"
rm -f "$SUBDIR"; mkdir -p -m 700 "$SUBDIR/$SUBSID"; subframe 140; sub2chk "directory at the entry path"
subclear; subseed "0 0 0 3 0 0 0" 0 11111111-1111-4111-8111-111111111111; subframe 140; sub2chk "another session's file"
subclear; subframe 140 "$(subjson sl-sepdemo)"; cp "$WORK/sub.out" "$WORK/sub2.base2"
subseed "0 0 0 3 0 0 0" 0 sl-sepdemo; subframe 140 "$(subjson sl-sepdemo)"; sub2chk "non-UUID session id" "$WORK/sub2.base2"
subclear
[ "$sub2bad" -eq 0 ] && echo "  SUB2 18 unusable states: output byte-identical to no state file, one line, empty stderr OK" || fail=1

echo "── SUB3. SUMMARY LINE NARROWING: full form, total + FAIL/KILL/PAUS, total alone, nothing — by drawable width"
sub3bad=0
for sub3c in "49:$SUBFULL" "48:sub 7 │ FAIL 1 │ PAUS 1" "23:sub 7 │ FAIL 1 │ PAUS 1" "22:sub 7" "5:sub 7" "4:"; do
  sub3d=${sub3c%%:*}; sub3w=${sub3c#*:}
  subseed "1 0 1 3 1 1 0" 0; subframe $(( sub3d + EDGE_PAD ))
  sub3g=$(subpick summary | nocol)
  [ "$sub3g" = "$sub3w" ] || { echo "  ★ FAIL SUB3 drawable width $sub3d: [$sub3g], want [$sub3w]"; sub3bad=1; }
done
subseed "1 0 1 3 1 1 0" 0; subframe 0
[ "$(subpick summary | nocol)" = "$SUBFULL" ] || { echo "  ★ FAIL SUB3 unavailable width: [$(subpick summary | nocol)], want the full form unbounded"; sub3bad=1; }
subclear
[ "$sub3bad" -eq 0 ] && echo "  SUB3 widths 49/48/23/22/5/4 + unavailable → full / FAIL-KILL-PAUS / total / none / full OK" || fail=1

echo "── SUB4. SUMMARY LINE vs THE 14-STEP ORDER: the session line is byte-identical with and without state at every width"
# A fixture that walks the sacrifice order: git, effort, a long session name, the 7d window (1D6H30m out, so its countdown
# reads 1D6H for half an hour either way and two frames a second apart cannot differ).
sub4bad=0
SUB4J=$(jq -cn --arg cwd "$GREPO" --arg s "$SUBSID" '{workspace:{current_dir:$cwd, project_dir:$cwd},
  model:{display_name:"Opus 4.8 (1M context)"}, context_window:{used_percentage:3}, effort:{level:"high"},
  rate_limits:{seven_day:{used_percentage:86, resets_at:(now+109800|floor)}}, session_id:$s,
  session_name:"a long session name so the right half degrades across the whole sweep"}')
for sub4c in 200 160 140 130 120 110 100 90 80 70 60 53 50 40 30 27 24 20 17 10 9 8 5 4 3 2; do
  subclear; subframe "$sub4c" "$SUB4J"; cp "$WORK/sub.out" "$WORK/sub4.a"
  subseed "1 0 1 3 1 1 0" 0; subframe "$sub4c" "$SUB4J"
  [ "$(subnl "$WORK/sub4.a")" = 1 ] || { echo "  ★ FAIL SUB4 C=$sub4c no-state frame has $(subnl "$WORK/sub4.a") lines"; sub4bad=1; }
  [ "$(subpick session)" = "$(cat "$WORK/sub4.a")" ] || { echo "  ★ FAIL SUB4 C=$sub4c session line differs with state present"; sub4bad=1; }
  sub4s=$(subpick summary)
  if [ $(( sub4c - EDGE_PAD )) -ge 5 ]; then
    [ -n "$sub4s" ] || { echo "  ★ FAIL SUB4 C=$sub4c no summary line although 'sub 7' fits"; sub4bad=1; }
    [ "$(printf '%s' "$sub4s" | vw)" -le $(( sub4c - EDGE_PAD )) ] || { echo "  ★ FAIL SUB4 C=$sub4c summary line wider than $(( sub4c - EDGE_PAD )): [$(printf '%s' "$sub4s" | nocol)]"; sub4bad=1; }
  else
    [ -z "$sub4s" ] || { echo "  ★ FAIL SUB4 C=$sub4c summary line printed although 'sub 7' cannot fit: [$(printf '%s' "$sub4s" | nocol)]"; sub4bad=1; }
  fi
done
subclear
[ "$sub4bad" -eq 0 ] && echo "  SUB4 200..2 cols: session line unchanged by the summary line, summary within the drawable width OK" || fail=1

echo "── SUB5. END TO END: subagent-status-line.sh writes the counts, the next session-line frame shows them; stale after 20 s"
sub5bad=0
SUB5SID=$(printf '%s' "$SAREAL1" | jq -r .session_id)
SUB5J=$(subjson "$SUB5SID")
sub5shift() {  # $1=seconds → move the entry's written epoch that far into the past
  local v ep rest; IFS=' ' read -r v ep rest < "$SUBDIR/$SUB5SID"
  printf '%s %s %s\n' "$v" "$(( ep - $1 ))" "$rest" > "$SUBDIR/$SUB5SID"
}
subclear; sarun "$SAREAL1" >/dev/null
subframe 140 "$SUB5J"
[ "$(subpick summary | nocol)" = "sub 1 │ RUN 1" ] || { echo "  ★ FAIL SUB5 captured payload → summary [$(subpick summary | nocol)], want [sub 1 │ RUN 1]"; sub5bad=1; }
sub5shift 19; subframe 140 "$SUB5J"
[ "$(subpick summary | nocol)" = "sub 1 │ RUN 1" ] || { echo "  ★ FAIL SUB5 a write 19 s old is dropped: [$(subpick summary | nocol)]"; sub5bad=1; }
sarun "$SAREAL1" >/dev/null; sub5shift 30; subframe 140 "$SUB5J"
[ "$(subnl)" = 1 ] && [ -z "$(subpick summary)" ] || { echo "  ★ FAIL SUB5 a write 30 s old still shows: [$(nocol < "$WORK/sub.out")]"; sub5bad=1; }
subclear
[ "$sub5bad" -eq 0 ] && echo "  SUB5 captured payload → state file → summary line, kept at 19 s, gone at 30 s OK" || fail=1

echo "── SUB6. SUMMARY LINE COST: no added process on the session line, exactly one (mv) on the subagent command"
# (a) PATH shims log every external command a run starts. Each run has its own fake HOME so the detached jobs of other
#     sections cannot leave records behind, and every run waits for its own detached jobs before the next one starts.
sub6bad=0
SUB6H="$WORK/sub6home"; mkdir -p "$SUB6H/.claude"
SUB6SHIM="$WORK/sub6shim"; mkdir -p "$SUB6SHIM"
for sub6c in awk basename cat chmod cksum cut date dirname find git grep head jq ln md5 mkdir mv od openssl perl pgrep ps \
             python3 rm sed shasum sleep sort stat stty tail touch tr uniq wc; do
  sub6p=$(command -v "$sub6c" 2>/dev/null); case "$sub6p" in /*) ;; *) continue ;; esac
  printf '#!/bin/bash\nprintf "%%s\\n" %s >> "$SUB6LOG"\nexec %s "$@"\n' "$sub6c" "$sub6p" > "$SUB6SHIM/$sub6c"; chmod +x "$SUB6SHIM/$sub6c"
done
sub6settle() { local n=0; while [ "$n" -lt 30 ] && pgrep -f "$SL/(statusline-command|subagent-status-line)\.sh" >/dev/null 2>&1; do sleep 0.1; n=$((n+1)); done; }
sub6frame() {  # $1=log file → one session-line frame of $SUBJ in $SUB6H, every external command logged
  : > "$1"
  printf '%s' "$SUBJ" | env PATH="$SUB6SHIM:$PATH" SUB6LOG="$1" COLUMNS=140 HOME="$SUB6H" bash "$SL/statusline-command.sh" >/dev/null 2>&1
  sub6settle
}
sub6sa() {  # $1=log file $2=payload → one subagent-command run in $SUB6H, every external command logged
  : > "$1"
  printf '%s' "$2" | env PATH="$SUB6SHIM:$PATH" SUB6LOG="$1" HOME="$SUB6H" bash "$SASCRIPT" >/dev/null 2>&1
  sub6settle
}
sub6diff() {  # $1=log $2=log → "<cmd> +n" / "<cmd> -n" for every command started a different number of times, "same" if none
  python3 -c '
import sys, collections
a = collections.Counter(open(sys.argv[1]).read().split()); b = collections.Counter(open(sys.argv[2]).read().split())
d = ["%s %+d" % (k, b[k] - a[k]) for k in sorted(set(a) | set(b)) if a[k] != b[k]]
print(" ".join(d) if d else "same")' "$1" "$2"
}
sub6settle
sub6frame "$WORK/sub6.warm"
sub6frame "$WORK/sub6.a"
mkdir -p -m 700 "$SUB6H/.claude/sl-subagents"
printf 'V1 %s 1 0 1 3 1 1 0\n' "$(date +%s)" > "$SUB6H/.claude/sl-subagents/$SUBSID"
sub6frame "$WORK/sub6.b"
[ -s "$WORK/sub6.a" ] || { echo "  ★ FAIL SUB6 the shims logged nothing — the trace is not running"; sub6bad=1; }
sub6r=$(sub6diff "$WORK/sub6.a" "$WORK/sub6.b")
[ "$sub6r" = same ] || { echo "  ★ FAIL SUB6 a fresh state file changes the session line's external commands: $sub6r"; sub6bad=1; }
SUB6SA=$(printf '%s' "$SAREAL1" | jq -c '.session_id="'"$SUBSID"'"')
sub6sa "$WORK/sub6.sa0" "$SUB6SA"        # first write of the run: creates the entry
[ -f "$SUB6H/.claude/sl-subagents/$SUBSID" ] || { echo "  ★ FAIL SUB6 the subagent command wrote no state entry"; sub6bad=1; }
sub6sa "$WORK/sub6.sau" "$SUB6SA"        # steady state: the entry is present
sub6sa "$WORK/sub6.san" "$(printf '%s' "$SAREAL1" | jq -c '.session_id="sl-sepdemo"')"   # no write at all
sub6r=$(sub6diff "$WORK/sub6.san" "$WORK/sub6.sau")
[ "$sub6r" = "mv +1" ] || { echo "  ★ FAIL SUB6 subagent command with its entry present vs no write: [$sub6r], want [mv +1]"; sub6bad=1; }
# (b) Median timings, measured and printed, not asserted: a fraction of a millisecond of budget is far inside the jitter of
#     a ~30 ms frame on a shared machine. The spec bounds (session line +0.3 ms, subagent command +5 ms against the build
#     before this capability) are checked against the base build outside the suite; this line makes a regression visible.
python3 - "$SL" "$SUB6H" "$SUBSID" "$SUBJ" "$SUB6SA" "$(printf '%s' "$SAREAL1" | jq -c '.session_id="sl-sepdemo"')" <<'PYTIME'
import sys, os, subprocess, time, statistics
sl, home, sid, frame, sa_uuid, sa_none = sys.argv[1:7]
env = dict(os.environ, HOME=home, COLUMNS="140")
entry = os.path.join(home, ".claude", "sl-subagents", sid)
def med(script, payload, seed):
    ts = []
    for _ in range(11):
        if seed is True:
            with open(entry, "w") as f: f.write("V1 %d 1 0 1 3 1 1 0\n" % int(time.time()))
        elif seed is False and os.path.exists(entry): os.remove(entry)
        t = time.perf_counter()
        subprocess.run(["bash", script], input=payload.encode(), env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        ts.append((time.perf_counter() - t) * 1000)
    return statistics.median(ts)
s0 = med(os.path.join(sl, "statusline-command.sh"), frame, False)
s1 = med(os.path.join(sl, "statusline-command.sh"), frame, True)
a0 = med(os.path.join(sl, "subagent-status-line.sh"), sa_none, None)
a1 = med(os.path.join(sl, "subagent-status-line.sh"), sa_uuid, None)
print("  NOTE SUB6(b) medians of 11 (measured, not asserted): session line %.1f ms without state, %.1f ms with (%+.1f); "
      "subagent command %.1f ms without a write, %.1f ms with (%+.1f)" % (s0, s1, s1 - s0, a0, a1, a1 - a0))
PYTIME
sub6settle
[ "$sub6bad" -eq 0 ] && echo "  SUB6 session line starts the same commands with a fresh state file; subagent command starts exactly one more (mv) OK" || fail=1

# PEER (change statusline-session-peer-id) The six-hex reference Claude Code's own agent listing shows in brackets after a session.
# It is derived from the per-session registry record ~/.claude/sessions/<claude pid>.json — a file written by ANOTHER program, so it
# is treated as hostile input: one field, string type only, and the only thing that can reach the line is a digest matching
# ^[0-9a-f]{6}$. Every frame here goes through peerwrap.sh because the statusline's $PPID must be a KNOWN pid: a piped child's
# parent IS the wrapper shell (probed), but wrapping that pipeline in $( ) inserts one more shell and shifts the pid by one — so the
# wrapper plants the record under its own $$ and redirects each frame to a file instead of capturing it.
echo "── PEER. SESSION-PEER-ID: [7921c3] ahead of the session name, derived from the session registry, silent on every failure"
pbad=0
PEERSESS="$FAKE_HOME/.claude/sessions"
PEERCACHE="$FAKE_HOME/.claude/sl-peer-ref"
PEERREF=7921c3
# Fixed derivation vector: sha256("session:/tmp/cc-socks/88429.sock") starts with 7921c3 — the anchor every assert below leans on.
# Recomputed here so the suite says so out loud if this machine's shasum ever disagrees with the constant.
pvec=$(printf 'session:/tmp/cc-socks/88429.sock' | shasum -a 256 | cut -c1-6)
[ "$pvec" = "$PEERREF" ] || { echo "  ★ FAIL PEER fixed vector: shasum gives [$pvec], want [$PEERREF]"; pbad=1; }

cat > "$WORK/peerwrap.sh" <<'PW'
#!/bin/bash
# Render frames whose claude pid is THIS script's $$, so the test controls which registry record the statusline will look for.
# $1=SL root $2=fake HOME $3=registry payload file ("-" plants no record) $4=space-separated COLUMNS list $5=statusline JSON
# $6=warm (1 = render one cold frame first and wait for the cache to catch up with the record, 0 = go straight to the sweep)
# $7=output prefix $8=optional second payload: swap it in with a strictly newer mtime, then render two more frames
# $9=symlink fixture ("-" none / "entry" = the cache ENTRY is a symlink / "dir" = the whole cache DIRECTORY is a symlink)
# ${10}=what that symlink points at
sl=$1; home=$2; payload=$3; colslist=$4; json=$5; warm=$6; out=$7; payload2=${8:-}; sym=${9:--}; symbase=${10:-}
reg="$home/.claude/sessions/$$.json"
cache="$home/.claude/sl-peer-ref/$$"
rm -rf "$home/.claude/sessions" "$home/.claude/sl-peer-ref"
mkdir -p "$home/.claude/sessions"
[ "$payload" = "-" ] || cp "$payload" "$reg"
case "$sym" in
    entry)     mkdir -p "$home/.claude/sl-peer-ref"; printf 'deadbe\n' > "$symbase"; ln -s "$symbase" "$cache" ;;
    dir)       mkdir -p "$symbase"; printf 'deadbe\n' > "$symbase/$$"; ln -s "$symbase" "$home/.claude/sl-peer-ref" ;;
    plainfile) printf 'not-a-directory\n' > "$home/.claude/sl-peer-ref" ;;
    entrydir)  mkdir -p "$cache"; printf 'sentinel\n' > "$cache/keep" ;;
esac
peersnap() {   # every path the cache lives on, with inode/mtime/size/mode: one cmp then answers "did ANY frame touch it"
    if [ -n "$symbase" ]; then find "$home/.claude/sl-peer-ref" "$symbase" 2>/dev/null
    else                        find "$home/.claude/sl-peer-ref" 2>/dev/null; fi \
    | sort | while IFS= read -r f; do stat -f '%N %i %m %z %p' "$f" 2>/dev/null; done
}
printf '%s\n' "$$" > "$out.pid"
frame() {   # $1=COLUMNS $2=output file
    printf '%s' "$json" | env COLUMNS="$1" HOME="$home" bash "$sl/statusline-command.sh" > "$2" 2> "$2.err"
    printf '%s\n' "$?" > "$2.rc"
}
settle() {  # wait out the detached job: the entry must exist AND no longer be older than the record it comes from. Waiting only
            # for existence would let the re-derivation case read the PREVIOUS value and pass for the wrong reason.
    local n=0
    while [ "$n" -lt 20 ]; do
        [ -s "$cache" ] && [ ! "$reg" -nt "$cache" ] && return 0
        sleep 0.1; n=$((n+1))
    done
}
set -- $colslist
if [ "$warm" != 0 ]; then frame "$1" "$out.f1"; settle; fi
stat -f '%i' "$cache" > "$out.ino1" 2>/dev/null
peersnap > "$out.snap1"
for c in $colslist; do frame "$c" "$out.c$c"; done
sleep 0.3                          # a job wrongly forked by the sweep would land in this window and show up below
stat -f '%i' "$cache" > "$out.ino2" 2>/dev/null
peersnap > "$out.snap2"
ls -A "$home/.claude/sl-peer-ref" > "$out.entries" 2>/dev/null
if [ -n "$payload2" ]; then
    sleep 1.1                      # the entry is judged stale by mtime, and bash's -nt on this platform compares whole seconds
    cp "$payload2" "$reg"
    frame 200 "$out.r1"            # the frame that notices the record is newer than the entry: no reference, derivation restarted
    settle
    frame 200 "$out.r2"            # the next frame: the re-derived reference
fi
PW

peerrun() {  # $1=payload|"-" $2=COLUMNS list $3=json $4=warm $5=second payload|"" $6=symlink mode|"-" $7=symlink target|""
  bash "$WORK/peerwrap.sh" "$SL" "$FAKE_HOME" "$1" "$2" "$3" "$4" "$WORK/peer" "${5:-}" "${6:--}" "${7:-}"
  PEERPID=$(cat "$WORK/peer.pid" 2>/dev/null)
}
peerplain() { nocol < "$WORK/peer.c$1"; }   # $1=COLUMNS → that frame's line with SGR stripped

# Registry payloads. good/good2 are well-formed records; the rest are the failure modes the degradation requirement enumerates.
mkdir -p "$WORK/peerreg" "$WORK/peerfake"
printf '%s\n' '{"sessionId":"5e6f","pid":4242,"cwd":"/x","name":"macos-54","messagingSocketPath":"/tmp/cc-socks/88429.sock","status":"idle"}' > "$WORK/peerreg/good.json"
printf '%s\n' '{"messagingSocketPath":"/tmp/cc-socks/99999.sock"}' > "$WORK/peerreg/good2.json"
printf '%s\n' '{ this is not json at all' > "$WORK/peerreg/badjson.json"
printf '%s\n' '{"messagingSocketPath":88429}' > "$WORK/peerreg/number.json"
printf '%s\n' '{"sessionId":"5e6f","name":"macos-54"}' > "$WORK/peerreg/nofield.json"
printf '%s\n' '{"messagingSocketPath":""}' > "$WORK/peerreg/emptystr.json"
# Hostile socket paths, both carrying a raw ESC and a raw U+009B (8-bit CSI) — the exact bytes the SGR invariant exists to keep out.
# One is short enough to be used whole, so the WHITELIST (not the length cap) is what keeps the line clean; the other is 4 KB, past
# the 256-character cap every external string gets, with its control bytes deliberately beyond the cap so the expected digest below
# can be computed with plain byte slicing.
phost='/tmp/cc-socks/'$'\033''[1mAAAAAAAA'$'\302\233''AAAAAAAA.sock'
jq -cn --arg p "$phost" '{messagingSocketPath:$p}' > "$WORK/peerreg/hostile.json"
phost4k="/tmp/cc-socks/$(awk 'BEGIN{s="";while(length(s)<4000)s=s "A";print substr(s,1,4000)}')"$'\033'"[1m"$'\302\233'".sock"
jq -cn --arg p "$phost4k" '{messagingSocketPath:$p}' > "$WORK/peerreg/hostile4k.json"
phostref=$(printf '%s' "session:$phost" | shasum -a 256 | cut -c1-6)
phost4kref=$(printf '%s' "session:$(printf '%s' "$phost4k" | head -c 256)" | shasum -a 256 | cut -c1-6)
# Counting shim for the ONE jq call this capability makes: the derivation job's read of the registry record. parse_input's jq runs
# on every frame and would drown the signal, so only a program mentioning the field name is counted. This is how "the frame did not
# start a job" is asserted for shapes that leave no trace on disk when the job fails.
JQREAL=$(command -v jq)
mkdir -p "$WORK/countbin"
{ printf '#!/bin/sh\n'
  printf 'case "$*" in *messagingSocketPath*) printf x >> "%s" ;; esac\n' "$WORK/jqcount"
  printf 'exec %s "$@"\n' "$JQREAL"
} > "$WORK/countbin/jq"
chmod +x "$WORK/countbin/jq"
jqcount() { [ -f "$WORK/jqcount" ] && wc -c < "$WORK/jqcount" | tr -d ' ' || printf 0; }

# No SHA-256 tool reachable from the frame (its own dir, so test M's failing perl stub does not ride along and change truncation).
mkdir -p "$WORK/nosha"
printf '#!/bin/sh\nexit 127\n' > "$WORK/nosha/shasum";  chmod +x "$WORK/nosha/shasum"
printf '#!/bin/sh\nexit 127\n' > "$WORK/nosha/openssl"; chmod +x "$WORK/nosha/openssl"

# Time-invariant fixtures: no rate_limits, no transcript, no last-msg record for this session id, so the whole line is a pure
# function of the width and the registry — which is what makes the byte-identical comparisons below meaningful rather than flaky.
JPEER=$(jq -cn --arg cwd "$GREPO" --arg proj "$GREPO" '
  { workspace:{current_dir:$cwd, project_dir:$proj}, model:{display_name:"Opus 4.8 (1M context)"},
    context_window:{used_percentage:6}, session_id:"peer-selftest", session_name:"my-session" }')
JPEERNONAME=$(jq -cn --arg cwd "$GREPO" --arg proj "$GREPO" '
  { workspace:{current_dir:$cwd, project_dir:$proj}, model:{display_name:"Opus 4.8 (1M context)"},
    context_window:{used_percentage:6}, session_id:"peer-selftest", session_name:"" }')
JPEERLONG=$(jq -cn --arg cwd "$GREPO" --arg proj "$GREPO" '
  { workspace:{current_dir:$cwd, project_dir:$proj}, model:{display_name:"Opus 4.8 (1M context)"},
    context_window:{used_percentage:6}, session_id:"peer-selftest",
    session_name:"a very very very very very very long session name that forces right truncation" }')

# PEER-1 harness self-check: the record must land on the path the statusline actually looks at. Asserting the file exists is not
# enough — that only proves the WRAPPER wrote it. The cache entry keyed by the same pid is written by the statusline's own detached
# job, so its presence is what proves both sides agree on the pid; without it this section could go green for the wrong reason.
peerrun "$WORK/peerreg/good.json" "200" "$JPEER" 1
if [ -z "${PEERPID:-}" ] || [ ! -f "$PEERSESS/$PEERPID.json" ]; then
  echo "  ★ FAIL PEER-1 registry record was not planted at \$HOME/.claude/sessions/<pid>.json"; pbad=1
fi
[ -f "$PEERCACHE/$PEERPID" ] || { echo "  ★ FAIL PEER-1 statusline never resolved pid $PEERPID (no cache entry) — pid plumbing, not display"; pbad=1; }

# PEER-2 the fixed vector on the line, ahead of the name and still the rightmost segment; and the session's FIRST frame does not
# carry it, because derivation is detached — that cold frame renders exactly like a build without the capability.
p2=$(peerplain 200)
case "$p2" in *"[$PEERREF] my-session") ;; *) echo "  ★ FAIL PEER-2 line does not end with [$PEERREF] my-session: [$p2]"; pbad=1 ;; esac
case "$p2" in *" │ [$PEERREF] my-session") ;; *) echo "  ★ FAIL PEER-2 reference is not at the head of the rightmost segment: [$p2]"; pbad=1 ;; esac
pf1=$(nocol < "$WORK/peer.f1")
case "$pf1" in *"[$PEERREF]"*) echo "  ★ FAIL PEER-2 the first frame of a session already showed a reference: [$pf1]"; pbad=1 ;; esac
case "$pf1" in *"my-session") ;; *) echo "  ★ FAIL PEER-2 the first frame lost the session name: [$pf1]"; pbad=1 ;; esac

# PEER-3 an empty session name now renders the bracketed reference alone, where the same input previously produced no segment at all.
peerrun "$WORK/peerreg/good.json" "200" "$JPEERNONAME" 1
p3=$(peerplain 200)
case "$p3" in *" │ [$PEERREF]") ;; *) echo "  ★ FAIL PEER-3 empty name did not render [$PEERREF] as its own segment: [$p3]"; pbad=1 ;; esac
case "$p3" in *"my-session"*) echo "  ★ FAIL PEER-3 a name appeared in the empty-name frame: [$p3]"; pbad=1 ;; esac

# PEER-4 every failure mode degrades to TODAY's line, byte for byte, with a clean stderr and exit 0. The no-registry frame is the
# reference: a build without this capability can only produce that line, so byte-equality with it IS the degradation requirement.
peerrun "-" "200" "$JPEER" 0
cp "$WORK/peer.c200" "$WORK/peer.baseline"
[ -d "$PEERCACHE" ] && { echo "  ★ FAIL PEER-4 no registry record, yet a cache directory was created"; pbad=1; }
for pcase in badjson number nofield emptystr; do
  peerrun "$WORK/peerreg/$pcase.json" "200" "$JPEER" 1
  cmp -s "$WORK/peer.baseline" "$WORK/peer.c200" \
    || { echo "  ★ FAIL PEER-4 [$pcase] frame differs from the no-registry frame: [$(peerplain 200)]"; pbad=1; }
  [ -s "$WORK/peer.c200.err" ] && { echo "  ★ FAIL PEER-4 [$pcase] wrote to stderr: [$(cat "$WORK/peer.c200.err")]"; pbad=1; }
  [ "$(cat "$WORK/peer.c200.rc")" = 0 ] || { echo "  ★ FAIL PEER-4 [$pcase] exit code $(cat "$WORK/peer.c200.rc")"; pbad=1; }
done
( PATH="$WORK/nosha:$PATH"; peerrun "$WORK/peerreg/good.json" "200" "$JPEER" 1 )   # subshell: the shim must not outlive this case
cmp -s "$WORK/peer.baseline" "$WORK/peer.c200" \
  || { echo "  ★ FAIL PEER-4 [no sha256 tool] frame differs from the no-registry frame: [$(peerplain 200)]"; pbad=1; }
[ -s "$WORK/peer.c200.err" ] && { echo "  ★ FAIL PEER-4 [no sha256 tool] wrote to stderr"; pbad=1; }
[ "$(cat "$WORK/peer.c200.rc")" = 0 ] || { echo "  ★ FAIL PEER-4 [no sha256 tool] exit code $(cat "$WORK/peer.c200.rc")"; pbad=1; }

# PEER-5 the fourth external source satisfies the only-our-SGR invariant by construction, not by filtering: whatever the record
# holds, the sole contribution it can make to the line is a six-hex digest OF it. Not one byte of the value itself may appear.
for pcase in "hostile $phostref" "hostile4k $phost4kref"; do
  set -- $pcase
  peerrun "$WORK/peerreg/$1.json" "200" "$JPEER" 1
  p5=$(peerplain 200)
  case "$p5" in *"[$2] my-session") ;; *) echo "  ★ FAIL PEER-5 [$1] did not yield its digest [$2]: [$p5]"; pbad=1 ;; esac
  case "$p5" in *AAAA*) echo "  ★ FAIL PEER-5 [$1] registry text reached the line: [$p5]"; pbad=1 ;; esac
  grep -q $'\302\233' "$WORK/peer.c200" && { echo "  ★ FAIL PEER-5 [$1] the record's U+009B reached the terminal"; pbad=1; }
  [ "$(grep -c '' "$WORK/peer.c200")" -eq 1 ] || { echo "  ★ FAIL PEER-5 [$1] broke the single-line invariant"; pbad=1; }
  p5w=$(vw < "$WORK/peer.c200"); [ "$p5w" -le $((200-EDGE_PAD)) ] || { echo "  ★ FAIL PEER-5 [$1] width $p5w exceeds drawable"; pbad=1; }
done

# PEER-6 truncation is all-or-nothing for the reference. A half-rendered "[7921" reads as a DIFFERENT session, so at every width the
# reference is either complete or wholly absent — and there is a width band where it survives while the NAME is what gets cut.
# The band where the reference stops fitting is only a few columns wide, so it is swept one column at a time: a coarse sweep
# steps over the exact widths where a cut would land inside the token and the case goes green having tested nothing.
pcols="160 150 140 130 125 120 115 110 105 100 95 90 85 80 75 70 65 60 55 50 48 46 44 42 40 38 36 34 33 32 31 30 29 28 27 26 25 24 23 22 21 20 19 18"
peerrun "$WORK/peerreg/good.json" "$pcols" "$JPEERLONG" 1
ptrunc=0
for c in $pcols; do
  pl=$(peerplain "$c")
  case "$pl" in
    *"[$PEERREF]"*)
      case "$pl" in *"…"*) case "$pl" in *"forces right truncation") ;; *) ptrunc=1 ;; esac ;; esac ;;
    *"["*) echo "  ★ FAIL PEER-6 partial reference at C=$c: [$pl]"; pbad=1 ;;
  esac
  [ "$(grep -c '' "$WORK/peer.c$c")" -eq 1 ] || { echo "  ★ FAIL PEER-6 C=$c not a single line"; pbad=1; }
  pw=$(vw < "$WORK/peer.c$c"); [ "$pw" -le $((c-EDGE_PAD)) ] || { echo "  ★ FAIL PEER-6 C=$c width $pw exceeds drawable"; pbad=1; }
done
[ "$ptrunc" -eq 1 ] || { echo "  ★ FAIL PEER-6 no width kept the whole reference while truncating the name (shrink before drop)"; pbad=1; }

# PEER-7 the cache is derived data and it enumerates which sessions are open on this machine: owner-only, one six-hex line, and
# never authoritative over a registry record newer than it — a recycled pid must not inherit the previous session's reference.
peerrun "$WORK/peerreg/good.json" "200" "$JPEER" 1 "$WORK/peerreg/good2.json"
pref2=$(printf '%s' "session:/tmp/cc-socks/99999.sock" | shasum -a 256 | cut -c1-6)
pperm=$(stat -f '%Lp' "$PEERCACHE" 2>/dev/null); [ "$pperm" = 700 ] || { echo "  ★ FAIL PEER-7 cache dir mode $pperm != 700"; pbad=1; }
pperm=$(stat -f '%Lp' "$PEERCACHE/$PEERPID" 2>/dev/null); [ "$pperm" = 600 ] || { echo "  ★ FAIL PEER-7 cache entry mode $pperm != 600"; pbad=1; }
[ "$(grep -c '' "$PEERCACHE/$PEERPID" 2>/dev/null)" = 1 ] || { echo "  ★ FAIL PEER-7 cache entry is not exactly one line"; pbad=1; }
case "$(cat "$PEERCACHE/$PEERPID" 2>/dev/null)" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
  *) echo "  ★ FAIL PEER-7 cache entry is not a bare six-hex value: [$(cat "$PEERCACHE/$PEERPID" 2>/dev/null)]"; pbad=1 ;; esac
pr1=$(nocol < "$WORK/peer.r1"); pr2=$(nocol < "$WORK/peer.r2")
case "$pr1" in *"[$PEERREF]"*) echo "  ★ FAIL PEER-7 stale reference displayed after the record changed: [$pr1]"; pbad=1 ;; esac
case "$pr2" in *"[$pref2] my-session") ;; *) echo "  ★ FAIL PEER-7 reference not re-derived from the newer record (want [$pref2]): [$pr2]"; pbad=1 ;; esac

# PEER-8 the pid guard. The registry path is built from $PPID, so a value that is not a plain decimal number must stop the whole
# path dead — before any file test, any directory creation, any job. Called directly (the frame can only ever supply a real pid),
# with a record planted under the bogus pid so that a missing guard would visibly start a job and create the cache directory.
rm -rf "$PEERSESS" "$PEERCACHE"; mkdir -p "$PEERSESS"
cp "$WORK/peerreg/good.json" "$PEERSESS/12x34.json"
pguard=$(env HOME="$FAKE_HOME" bash -c '
  . "$1/lib/collect.sh"
  now=1700000000
  for p in "12x34" "" "-1" "9 9" "042 " ; do read_peer_ref "$p"; printf "[%s]" "$peer_ref"; done' _ "$SL")
sleep 0.4
[ "$pguard" = "[][][][][]" ] || { echo "  ★ FAIL PEER-8 a non-decimal pid produced a reference: [$pguard]"; pbad=1; }
[ -d "$PEERCACHE" ] && { echo "  ★ FAIL PEER-8 a non-decimal pid still started a derivation job (cache directory created)"; pbad=1; }
rm -rf "$PEERSESS"

# PEER-9 negative caching. A record that can never yield a reference (unparseable, wrong type, field absent) must be resolved ONCE:
# without a cached "no reference" marker every single frame re-forks a detached jq+shasum job that is guaranteed to fail, which both
# never converges and, on a large unparseable record, steals enough CPU to push the FOREGROUND past its 2 ms budget.
peerrun "$WORK/peerreg/badjson.json" "200 199 198" "$JPEER" 1
pn=$(grep -c '' "$WORK/peer.entries" 2>/dev/null)
[ "$pn" = 1 ] || { echo "  ★ FAIL PEER-9 cache holds $pn entries after four frames, want exactly 1 (leftover temp files or re-derivation)"; pbad=1; }
[ "$(cat "$PEERCACHE/$PEERPID" 2>/dev/null)" = "-" ] || { echo "  ★ FAIL PEER-9 no-reference marker not written: [$(cat "$PEERCACHE/$PEERPID" 2>/dev/null)]"; pbad=1; }
cmp -s "$WORK/peer.ino1" "$WORK/peer.ino2" \
  || { echo "  ★ FAIL PEER-9 the entry was rewritten by a later frame (inode changed) — the failed derivation is not cached"; pbad=1; }
cmp -s "$WORK/peer.baseline" "$WORK/peer.c200" \
  || { echo "  ★ FAIL PEER-9 the marker changed the rendered line: [$(peerplain 200)]"; pbad=1; }
pk=0; while [ "$pk" -lt 20 ] && pgrep -f "$SL/statusline-command.sh" >/dev/null 2>&1; do sleep 0.1; pk=$((pk+1)); done
pgrep -f "$SL/statusline-command.sh" >/dev/null 2>&1 && { echo "  ★ FAIL PEER-9 a derivation job outlived its frames by more than 2s"; pbad=1; }

# PEER-10 the cache is ours; a symlink in it is not. Following one hands whoever planted it the value that names this session to
# other software (verified: a link pointing at a file holding "deadbe" put [deadbe] on the line). Defense in depth — planting it
# needs write access to ~/.claude, which also buys the registry record itself — so both the entry and the directory refuse links.
for pcase in "entry $WORK/peerfake/entry" "dir $WORK/peerfake/dir"; do
  set -- $pcase
  rm -rf "$WORK/peerfake"; mkdir -p "$WORK/peerfake"; rm -f "$WORK/jqcount"
  ( PATH="$WORK/countbin:$PATH"; peerrun "$WORK/peerreg/good.json" "200 199 198" "$JPEER" 0 "" "$1" "$2" )
  cmp -s "$WORK/peer.baseline" "$WORK/peer.c200" \
    || { echo "  ★ FAIL PEER-10 [$1 symlink] followed into the link: [$(peerplain 200)]"; pbad=1; }
  case "$(peerplain 200)" in *deadbe*) echo "  ★ FAIL PEER-10 [$1 symlink] planted value reached the line"; pbad=1 ;; esac
  cmp -s "$WORK/peer.snap1" "$WORK/peer.snap2" \
    || { echo "  ★ FAIL PEER-10 [$1 symlink] the cache path was modified by a frame"; pbad=1; }
  [ "$(jqcount)" = 0 ] || { echo "  ★ FAIL PEER-10 [$1 symlink] started $(jqcount) derivation job(s) instead of none"; pbad=1; }
done

# PEER-11 the cache path may also be the WRONG KIND of thing, which is not an attack, just a mess someone left behind — and the
# two shapes fail in opposite directions. A regular file where the directory belongs makes every mkdir -p fail, so the marker can
# never land and every frame re-forks a job that cannot possibly finish. A directory where the ENTRY belongs makes [ -f ] false
# forever, which re-forks the same way AND lets "mv -f $tmp $dest" bury one temp file inside that directory per frame. Both must be
# treated exactly like a symlink: read nothing, start nothing, write nothing.
for pcase in plainfile entrydir; do
  rm -rf "$WORK/peerfake"; mkdir -p "$WORK/peerfake"; rm -f "$WORK/jqcount"
  ( PATH="$WORK/countbin:$PATH"; peerrun "$WORK/peerreg/good.json" "200 199 198" "$JPEER" 0 "" "$pcase" "" )
  cmp -s "$WORK/peer.baseline" "$WORK/peer.c200" \
    || { echo "  ★ FAIL PEER-11 [$pcase] frame differs from the no-registry frame: [$(peerplain 200)]"; pbad=1; }
  cmp -s "$WORK/peer.snap1" "$WORK/peer.snap2" \
    || { echo "  ★ FAIL PEER-11 [$pcase] a frame modified the cache path (temp file left behind, or the target rewritten)"; pbad=1; }
  [ "$(jqcount)" = 0 ] || { echo "  ★ FAIL PEER-11 [$pcase] three frames started $(jqcount) doomed derivation job(s), one per frame"; pbad=1; }
done
[ "$(cat "$PEERCACHE" 2>/dev/null)" = "not-a-directory" ] || [ ! -f "$PEERCACHE" ] \
  || { echo "  ★ FAIL PEER-11 the plain file standing in for the cache directory was rewritten"; pbad=1; }
# The writer's own destination guard, exercised directly. The foreground now refuses these shapes before any job starts, so a frame
# can no longer reach the writer with a bad destination — except by racing it, since the shape can change after the frame looked.
# Called directly so the guard is pinned on its own rather than riding on the foreground's.
rm -rf "$PEERSESS" "$PEERCACHE"; mkdir -p "$PEERSESS" "$PEERCACHE/4242"
cp "$WORK/peerreg/good.json" "$PEERSESS/4242.json"
printf 'sentinel\n' > "$PEERCACHE/4242/keep"
env HOME="$FAKE_HOME" bash -c '. "$1/lib/collect.sh"; peer_ref_update 4242 1700000000' _ "$SL" >/dev/null 2>&1
[ "$(ls -A "$PEERCACHE/4242" | tr '\n' ' ')" = "keep " ] \
  || { echo "  ★ FAIL PEER-11 the writer moved its temp file into a directory standing where the entry belongs: [$(ls -A "$PEERCACHE/4242" | tr '\n' ' ')]"; pbad=1; }
# ...and a symlink standing there. `-e` and `-f` both FOLLOW links, so a shape test built only from those two accepts a link to a
# regular file and rejects only a dangling one; "mv -f" then replaces the LINK, which is still replacing something we did not
# create. The target's bytes are never written through, so this is tidiness of ownership rather than a leak — but the writer says
# it does not replace what it did not create, so it must not.
printf 'deadbe\n' > "$WORK/peerfake/wtarget"
ln -s "$WORK/peerfake/wtarget"  "$PEERCACHE/4243"     # link to a regular file: passes -e and -f
ln -s "$WORK/peerfake/nothing"  "$PEERCACHE/4244"     # dangling link: fails -e and -f, but is still not ours to replace
cp "$WORK/peerreg/good.json" "$PEERSESS/4243.json"; cp "$WORK/peerreg/good.json" "$PEERSESS/4244.json"
pw43=$(stat -f '%i %p' "$PEERCACHE/4243"); pw44=$(stat -f '%i %p' "$PEERCACHE/4244")
env HOME="$FAKE_HOME" bash -c '. "$1/lib/collect.sh"; peer_ref_update 4243 1700000000; peer_ref_update 4244 1700000000' _ "$SL" >/dev/null 2>&1
for pl in 4243 4244; do
  [ -L "$PEERCACHE/$pl" ] || { echo "  ★ FAIL PEER-11 the writer replaced the symlink at entry $pl with a file of its own"; pbad=1; }
done
[ "$(stat -f '%i %p' "$PEERCACHE/4243" 2>/dev/null)" = "$pw43" ] || { echo "  ★ FAIL PEER-11 entry 4243 (link to a regular file) was rewritten"; pbad=1; }
[ "$(stat -f '%i %p' "$PEERCACHE/4244" 2>/dev/null)" = "$pw44" ] || { echo "  ★ FAIL PEER-11 entry 4244 (dangling link) was rewritten"; pbad=1; }
[ "$(cat "$WORK/peerfake/wtarget")" = deadbe ] || { echo "  ★ FAIL PEER-11 the writer wrote through the symlink into its target"; pbad=1; }
[ "$(ls -A "$PEERCACHE" | sort | tr '\n' ' ')" = "4242 4243 4244 " ] \
  || { echo "  ★ FAIL PEER-11 the writer left something behind: [$(ls -A "$PEERCACHE" | sort | tr '\n' ' ')]"; pbad=1; }
# The writer's exit status is its own, not whatever the pruning walk's last comparison happened to leave behind.
rm -rf "$PEERCACHE"; mkdir -p "$PEERCACHE"
cp "$WORK/peerreg/good.json" "$PEERSESS/4245.json"
env HOME="$FAKE_HOME" bash -c '. "$1/lib/collect.sh"; peer_ref_update 4245 1700000000' _ "$SL" >/dev/null 2>&1
pwrc=$?
[ "$pwrc" = 0 ] || { echo "  ★ FAIL PEER-11 the writer returned $pwrc after a successful derivation"; pbad=1; }
[ "$(cat "$PEERCACHE/4245" 2>/dev/null)" = "$PEERREF" ] || { echo "  ★ FAIL PEER-11 the direct writer call did not publish [$PEERREF]"; pbad=1; }
rm -rf "$PEERSESS" "$PEERCACHE"

# the counting shim must itself be able to see a job, or the two zeros above would be meaningless
rm -f "$WORK/jqcount"
( PATH="$WORK/countbin:$PATH"; peerrun "$WORK/peerreg/badjson.json" "200" "$JPEER" 1 )
[ "$(jqcount)" -ge 1 ] || { echo "  ★ FAIL PEER-11 the jq counting shim never fired — the two zero-job asserts above prove nothing"; pbad=1; }

rm -rf "$PEERSESS" "$PEERCACHE" "$WORK/peerfake"   # leave no record behind: a later frame's $PPID could collide with a pid used here
[ "$pbad" -eq 0 ] && echo "  PEER fixed vector, cold first frame, empty name, six silent failure modes, hostile records, all-or-nothing truncation, private cache + re-derivation, pid guard, negative caching, symlink and wrong-shape refusal OK" || fail=1

echo "── EFF. EFFORT MODE: ultracode from attachment records, /effort output and the claude argv fallback; latest event wins; quoted text never counts"
effbad=0
EFFD="$WORK/eff"
mkdir -p "$EFFD/cwd" "$EFFD/noperl"
# Real-shaped JSONL builders, one line each, keys in the order Claude Code 2.1.283 writes them (the change's design.md quotes them).
eff_enter() { printf '{"parentUuid":"p1","isSidechain":false,"attachment":{"type":"ultra_effort_enter","reminderType":"%s"},"type":"attachment","uuid":"u1"}\n' "$1"; }
eff_exit()  { printf '{"parentUuid":"p1","isSidechain":false,"attachment":{"type":"ultra_effort_exit"},"type":"attachment","uuid":"u2"}\n'; }
eff_stdout() {  # $1=mode word → the text /effort prints for it
  case "$1" in
    auto)      printf 'Effort level set to auto' ;;
    ultracode) printf 'Set effort level to ultracode (this session only): xhigh + dynamic workflow orchestration' ;;
    *)         printf 'Set effort level to %s (this session only)' "$1" ;;
  esac
}
# $1=the command's stdout text. Interactive mode writes a user record; -p/SDK mode writes a system record of subtype local_command.
eff_set_user() { printf '{"parentUuid":"p1","isSidechain":false,"type":"user","message":{"role":"user","content":"<local-command-stdout>%s</local-command-stdout>"},"uuid":"u3"}\n' "$1"; }
eff_set_sys()  { printf '{"parentUuid":"p1","isSidechain":false,"type":"system","subtype":"local_command","content":"<local-command-stdout>%s</local-command-stdout>","level":"info","uuid":"u4"}\n' "$1"; }
# Quotations: a tool_result block that quotes a whole attachment record (its quotes escaped), and one whose content IS the stdout.
eff_quote_attach() { jq -cn --arg q "$(eff_enter full)" '{parentUuid:"p1",isSidechain:false,type:"user",message:{role:"user",content:[{tool_use_id:"toolu_q1",type:"tool_result",content:$q}]},uuid:"u5"}'; }
eff_quote_stdout() { printf '{"parentUuid":"p1","isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_q2","type":"tool_result","content":"<local-command-stdout>%s</local-command-stdout>"}]},"uuid":"u6"}\n' "$(eff_stdout ultracode)"; }
eff_fill_user() { printf '{"parentUuid":"p1","isSidechain":false,"type":"user","message":{"role":"user","content":"keep going"},"uuid":"u7"}\n'; }
eff_fill_asst() { printf '{"parentUuid":"p1","isSidechain":false,"message":{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":"ok"}]},"type":"assistant","uuid":"u8"}\n'; }
eff_fill() {  # $1=line count → that many ordinary records, user and assistant alternating
  awk -v n="$1" -v u="$(eff_fill_user)" -v a="$(eff_fill_asst)" 'BEGIN { for (i = 0; i < n; i++) print (i % 2 ? a : u) }'
}
efft() {  # $1=file, then tokens in file order: enter sparse exit set:<word> sys:<word> say:<stdout text> qattach qstdout fill:<lines>
  local f=$1 t; shift
  for t in "$@"; do
    case "$t" in
      enter)   eff_enter full ;;
      sparse)  eff_enter sparse ;;
      exit)    eff_exit ;;
      set:*)   eff_set_user "$(eff_stdout "${t#set:}")" ;;
      sys:*)   eff_set_sys "$(eff_stdout "${t#sys:}")" ;;
      say:*)   eff_set_user "${t#say:}" ;;
      qattach) eff_quote_attach ;;
      qstdout) eff_quote_stdout ;;
      fill:*)  eff_fill "${t#fill:}" ;;
    esac
  done > "$f"
}
effhas() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }   # $1=haystack $2=literal needle

# EFF-B builder self-check: every line is JSON; the record's own attachment key is unescaped, a quotation of it is not.
EFFATT='"attachment":{"type":"ultra_effort_'
EFFSTD='"role":"user","content":"<local-command-stdout>'
for effb in "eff_enter full" "eff_enter sparse" eff_exit "eff_set_user x" "eff_set_sys x" eff_quote_attach eff_quote_stdout eff_fill_user eff_fill_asst; do
  $effb | jq -e . >/dev/null 2>&1 || { echo "  ★ FAIL EFF-B builder [$effb] does not emit one JSON object"; effbad=1; }
done
for effl in "$(eff_enter full)" "$(eff_enter sparse)" "$(eff_exit)"; do
  effhas "$effl" "$EFFATT" || { echo "  ★ FAIL EFF-B attachment line lacks the unescaped record key: [$effl]"; effbad=1; }
done
effl=$(eff_quote_attach)
effhas "$effl" 'ultra_effort_enter' && ! effhas "$effl" "$EFFATT" || { echo "  ★ FAIL EFF-B quoting line is not an escaped quotation: [$effl]"; effbad=1; }
effl=$(eff_quote_stdout)
effhas "$effl" '<local-command-stdout>Set effort level to ultracode' && ! effhas "$effl" "$EFFSTD" \
  || { echo "  ★ FAIL EFF-B quoted stdout line carries a record's own stdout anchor: [$effl]"; effbad=1; }
effhas "$(eff_set_user x)" "$EFFSTD" || { echo "  ★ FAIL EFF-B interactive stdout record lacks its anchor"; effbad=1; }
echo "  EFF-B builders emit JSON, attachment keys unescaped, quotations escaped"

# A stand-in claude process. The frame's argv lookup reads its parent's argument list through $PPID, so this script runs the frame
# as a CHILD (never exec, and not as its last command) with the flags it was itself given, and records what `ps` shows for it.
cat > "$EFFD/wrap.sh" <<'EW'
#!/bin/bash
# env: EFF_SL=statusline root, EFF_HOME=the fake HOME, EFF_SIDE=file that receives this process's own `ps -o args=` line
ps -o args= -p "$$" > "$EFF_SIDE"
env HOME="$EFF_HOME" bash "$EFF_SL/statusline-command.sh"
rc=$?
exit "$rc"
EW
effpre=""   # prepended to the frame's PATH; only the failed-source case sets it
effrender() {  # $1=effort.level $2=transcript_path, then the stand-in claude's argv → the raw frame
  local lvl=$1 tp=$2; shift 2
  jq -cn --arg cwd "$EFFD/cwd" --arg tp "$tp" --arg lvl "$lvl" \
      '{workspace:{current_dir:$cwd}, model:{display_name:"Opus"}, context_window:{used_percentage:5}, effort:{level:$lvl}, transcript_path:$tp}' \
    | env HOME="$FAKE_HOME" EFF_HOME="$FAKE_HOME" COLUMNS=200 PATH="$effpre$PATH" EFF_SL="$SL" EFF_SIDE="$EFFD/side" \
        bash "$EFFD/wrap.sh" "$@"
}
EFDM=$( . "$SL/lib/render.sh"; _theme=""; STYLE="$SASTYLE"; load_palette; printf '%s' "$DM" )
EFOG=$( . "$SL/lib/render.sh"; _theme=""; STYLE="$SASTYLE"; load_palette; printf '%s' "$OG" )
EFRD=$( . "$SL/lib/render.sh"; _theme=""; STYLE="$SASTYLE"; load_palette; printf '%s' "$RD" )
EFRS=$'\033[0m'
effcase() {  # $1=case id $2=expected effort text $3=expected SGR $4=effort.level $5=transcript_path, then the stand-in claude's argv
  local id=$1 want=$2 col=$3 raw got; shift 3
  raw=$(effrender "$@")
  got=$(printf '%s' "$raw" | nocol); got=${got#* │ }; got=${got#* │ }; got=${got%% │ *}   # path │ model │ EFFORT │ …
  printf '  %s want=[%s] got=[%s]\n' "$id" "$want" "$got"
  [ "$got" = "$want" ] && effhas "$raw" "$col$want$EFRS" && return 0
  echo "  ★ FAIL $id want [$want] in its colour, got [$got]"; effbad=1
}

# EFF-W wrapper self-check: the argument list a frame's lookup will read really carries the flag, so a red argv case is never the harness.
effrender xhigh "$EFFD/absent.jsonl" --settings '{"ultracode":true}' >/dev/null
effhas "$(cat "$EFFD/side" 2>/dev/null)" '{"ultracode":true}' \
  && echo "  EFF-W stand-in claude argv seen by ps: [$(cat "$EFFD/side")]" \
  || { echo "  ★ FAIL EFF-W ps does not show the wrapper's flag: [$(cat "$EFFD/side" 2>/dev/null)]"; effbad=1; }

ON='{"ultracode":true}'
# Display rules (effort_mode reaches render only through the transcript here).
efft "$EFFD/t-uc.jsonl" fill:4 set:ultracode fill:2
efft "$EFFD/t-auto.jsonl" fill:4 set:auto fill:2
efft "$EFFD/t-none.jsonl" fill:6
efft "$EFFD/t-said.jsonl" fill:4 "say:Effort level set to xhigh" fill:2
effcase EFF-1 ultra "$EFDM" xhigh "$EFFD/t-uc.jsonl"
effcase EFF-2 high "$EFDM" high "$EFFD/t-uc.jsonl"
effcase EFF-3 "auto·medium" "$EFOG" medium "$EFFD/t-auto.jsonl"
effcase EFF-4 low "$EFRD" low "$EFFD/t-none.jsonl"
effcase EFF-5 turbo "$EFDM" turbo "$EFFD/t-none.jsonl"
effcase EFF-6 xhigh "$EFDM" xhigh "$EFFD/t-said.jsonl"
# Flag-started ultracode: the real attachment record among ordinary records, no effort-set record, no argv flag.
efft "$EFFD/t-enter.jsonl" fill:4 enter fill:4
effcase EFF-7 ultra "$EFDM" xhigh "$EFFD/t-enter.jsonl"
# Plain xhigh, both ways a session gets there.
efft "$EFFD/t-setx.jsonl" fill:4 set:xhigh fill:2
effcase EFF-8 xhigh "$EFDM" xhigh "$EFFD/t-none.jsonl" --effort xhigh
effcase EFF-9 xhigh "$EFDM" xhigh "$EFFD/t-setx.jsonl"
# /effort ultracode in the interactive and in the -p record shape.
efft "$EFFD/t-ucsys.jsonl" fill:4 sys:ultracode fill:2
effcase EFF-10 ultra "$EFDM" xhigh "$EFFD/t-uc.jsonl"
effcase EFF-11 ultra "$EFDM" xhigh "$EFFD/t-ucsys.jsonl"
# Turn-off sequences in a flag-started session (the flag stays in argv; any transcript event outranks it).
efft "$EFFD/t-off1.jsonl" fill:2 enter fill:2 set:high fill:2
efft "$EFFD/t-off2.jsonl" fill:2 enter fill:2 set:high fill:2 exit fill:2
efft "$EFFD/t-off3.jsonl" fill:2 enter fill:2 set:xhigh fill:2 exit fill:2
efft "$EFFD/t-off4.jsonl" fill:2 enter fill:2 set:auto fill:2
efft "$EFFD/t-off5.jsonl" fill:2 enter fill:2 set:auto fill:2 exit fill:2
efft "$EFFD/t-off6.jsonl" fill:2 enter fill:2 exit fill:2
efft "$EFFD/t-off7.jsonl" fill:2 set:ultracode fill:2 enter fill:2 set:high fill:2 exit fill:2 set:ultracode fill:2
effcase EFF-12 high "$EFDM" high "$EFFD/t-off1.jsonl" --settings "$ON"
effcase EFF-13 high "$EFDM" high "$EFFD/t-off2.jsonl" --settings "$ON"
effcase EFF-14 xhigh "$EFDM" xhigh "$EFFD/t-off3.jsonl" --settings "$ON"
effcase EFF-15 "auto·xhigh" "$EFDM" xhigh "$EFFD/t-off4.jsonl" --settings "$ON"
effcase EFF-16 "auto·xhigh" "$EFDM" xhigh "$EFFD/t-off5.jsonl" --settings "$ON"
effcase EFF-17 xhigh "$EFDM" xhigh "$EFFD/t-off6.jsonl" --settings "$ON"
effcase EFF-18 ultra "$EFDM" xhigh "$EFFD/t-off7.jsonl" --settings "$ON"
# Ultracode whose level resolves to something other than xhigh (a model without xhigh).
effcase EFF-19 high "$EFDM" high "$EFFD/t-enter.jsonl"
# Quoted event text inside tool results.
efft "$EFFD/t-qatt.jsonl" fill:4 qattach fill:2
efft "$EFFD/t-qstd.jsonl" fill:4 qstdout fill:2
efft "$EFFD/t-qafter.jsonl" fill:2 enter fill:2 exit fill:2 qattach fill:2
effcase EFF-20 xhigh "$EFDM" xhigh "$EFFD/t-qatt.jsonl"
effcase EFF-21 xhigh "$EFDM" xhigh "$EFFD/t-qstd.jsonl"
effcase EFF-22 xhigh "$EFDM" xhigh "$EFFD/t-qafter.jsonl" --settings "$ON"
# An event on line 20 followed by 2500 ordinary records still decides.
efft "$EFFD/t-farenter.jsonl" fill:19 enter fill:2500
efft "$EFFD/t-farset.jsonl" fill:19 set:ultracode fill:2500
effcase EFF-23 ultra "$EFDM" xhigh "$EFFD/t-farenter.jsonl"
effcase EFF-24 ultra "$EFDM" xhigh "$EFFD/t-farset.jsonl"
# Argument fallback matrix: the transcript path is non-empty but names no file yet, or a file with no event.
effcase EFF-25 ultra "$EFDM" xhigh "$EFFD/absent.jsonl" --dangerously-skip-permissions --settings "$ON"
effcase EFF-26 ultra "$EFDM" xhigh "$EFFD/t-none.jsonl" --settings '{"ultracode": true}'
effcase EFF-27 ultra "$EFDM" xhigh "$EFFD/absent.jsonl" --effort ultracode
effcase EFF-27b ultra "$EFDM" xhigh "$EFFD/absent.jsonl" --effort=ultracode   # the one-argument spelling of EFF-27
effcase EFF-28 xhigh "$EFDM" xhigh "$EFFD/absent.jsonl" --settings '{"ultracode":false}'
effcase EFF-29 xhigh "$EFDM" xhigh "$EFFD/absent.jsonl" --dangerously-skip-permissions
effcase EFF-30 high "$EFDM" high "$EFFD/absent.jsonl" --settings "$ON"
effcase EFF-31 xhigh "$EFDM" xhigh "$EFFD/t-off6.jsonl" --settings "$ON"
# An empty or blanked transcript_path runs neither source, even with the flag in argv.
effcase EFF-32 xhigh "$EFDM" xhigh "$EFFD/p/../s.jsonl" --settings "$ON"
effcase EFF-33 xhigh "$EFDM" xhigh "" --effort ultracode
# A failed scan (perl exits 1) with no argv flag never yields ultra, even though an enter record is there.
printf '#!/bin/sh\nexit 1\n' > "$EFFD/noperl/perl"; chmod +x "$EFFD/noperl/perl"
effpre="$EFFD/noperl:"
effcase EFF-34 xhigh "$EFDM" xhigh "$EFFD/t-enter.jsonl"
effpre=""

# effort_scan called directly: "E <mode>" when the file holds an effort event, an empty line when it holds none.
effscan() {  # $1=transcript → effort_scan's exact output followed by "." so an empty line stays visible
  env HOME="$FAKE_HOME" bash -c '. "$1/lib/collect.sh"; effort_scan "$2"; printf .' _ "$SL" "$1" 2>/dev/null
}
effscancase() {  # $1=case id $2=expected line (without its newline) $3=transcript
  local got; got=$(effscan "$3")
  printf '  %s effort_scan want=[%s] got=[%s]\n' "$1" "$2" "${got%$'\n.'}"
  [ "$got" = "$2"$'\n.' ] && return 0
  echo "  ★ FAIL $1 effort_scan printed [${got%$'\n.'}], want exactly one line [$2]"; effbad=1
}
efft "$EFFD/d-reenter.jsonl" fill:2 enter fill:2 exit fill:2 sparse fill:2
effscancase EFF-35 "E ultracode" "$EFFD/d-reenter.jsonl"
effscancase EFF-36 "E auto" "$EFFD/t-off5.jsonl"
effscancase EFF-37 "E " "$EFFD/t-off6.jsonl"
efft "$EFFD/d-quoted.jsonl" fill:2 qattach fill:2 qstdout fill:2
effscancase EFF-38 "" "$EFFD/d-quoted.jsonl"

[ "$effbad" -eq 0 ] && echo "  EFF display rules, attachment + /effort events, latest-event-wins turn-off, quoted text ignored, whole-file scan, argv fallback + its gates, failed source OK" || fail=1

echo "── G. perf: 10 frames"
time (for _ in 1 2 3 4 5 6 7 8 9 10; do run 140 "$J" >/dev/null; done)


echo "── SET. SETTINGS UNTOUCHED: after every frame of this run, both seeded settings files keep content and mtime, none added"
setbad=0
[ "$(setsnap)" = "$SETSNAP0" ] || { printf '  ★ FAIL SET a settings file changed:\n  before: %s\n  after:  %s\n' "$SETSNAP0" "$(setsnap)"; setbad=1; }
setls=$(cd "$FAKE_HOME/.claude" && ls -d settings*.json 2>&1 | tr '\n' ' ')
[ "$setls" = "settings.json settings.local.json " ] || { echo "  ★ FAIL SET ~/.claude/settings*.json is now [$setls]"; setbad=1; }
[ "$setbad" -eq 0 ] && echo "  SET settings.json + settings.local.json unchanged (content + mtime), no other settings*.json OK" || fail=1

if [ "$fail" -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "SOME FAILED"; exit 1; fi
