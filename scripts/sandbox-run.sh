#!/usr/bin/env bash
# sandbox-run.sh — run statusline-command.sh against a throwaway HOME, never the user's real one.
#
# Why this exists: the statusline shares rate-limit state across sessions through $HOME/.claude/sl-ratelimit-cache, and the
# authority rule there is "freshest observation wins". A single frame rendered against the real $HOME with a made-up session id
# therefore becomes the newest observation and rewrites the number EVERY live session displays. On 2026-08-31 exactly that
# happened: a demo frame run as `sl-sepdemo` flipped the 7d segment from "84% left / 6D15H" to a red "16% left / 1D7H" in every
# open session. lib/collect.sh now also refuses to persist a non-UUID session id, but that is a last line of defence — the way to
# render a frame for inspection is this script, which makes the blast radius a temp directory.
#
# Exit status: the statusline's own, or 2 for a usage/guard failure (the HOME guard NEVER runs the statusline).
set -u

SELF=${0##*/}
SL=$(cd "$(dirname "$0")/.." && pwd)
REAL_HOME=${HOME:-}

usage() {
    cat <<EOF
$SELF — render statusline-command.sh inside a throwaway HOME (never the real one)

Usage:
  $SELF [--cache FILE] [--tokens FILE] [--quota NAME=FILE] [--last-msg SID=FILE]
                  [--script PATH] [--columns N] [--keep] [--print-home] [--help]

Reads the statusline JSON on stdin and writes the rendered line on stdout, exactly like the real command.

Options:
  --cache FILE        Seed <sandbox>/.claude/sl-ratelimit-cache from FILE (cross-session rate-limit cache fixture).
  --tokens FILE       Seed <sandbox>/.claude/sl-tokens-cache from FILE (per-session token totals fixture).
  --quota NAME=FILE   Seed <sandbox>/.claude/state/statusline-quota/NAME from FILE (alternate-billing quota fixture).
                      NAME is the quota file's basename, e.g. claude-opus-5. Repeatable.
  --last-msg SID=FILE Seed <sandbox>/.claude/last-msg/SID from FILE (last-message-age fixture). Repeatable.
  --script PATH       Run PATH instead of $SL/statusline-command.sh (for sed-modified variant copies).
  --columns N         Export COLUMNS=N for the run (terminal width the renderer aligns to).
  --keep              Do not delete the sandbox HOME on exit; its path is printed to stderr so the resulting
                      caches can be inspected afterwards.
  --print-home        Print the sandbox HOME path to stderr before running (implied by --keep).
  --help              Show this help.

Examples:
  # Render one frame and see the line, with nothing of the user's touched:
  printf '%s' "\$JSON" | $SELF --columns 120

  # Reproduce a cross-session rate-limit scenario from a seeded cache, then inspect what the frame persisted:
  printf 'W7 1788764400 16 1788188829\n' > /tmp/rl.fixture
  printf '%s' "\$JSON" | $SELF --cache /tmp/rl.fixture --keep
  # -> stderr prints e.g.  sandbox HOME: /var/folders/.../sl-sandbox.XXXX  ; read its .claude/sl-ratelimit-cache

  # Render a BURN_SENS variant copy of the script:
  printf '%s' "\$JSON" | $SELF --script /tmp/variant/statusline-command.sh --columns 200
EOF
}

die() { printf '%s: %s\n' "$SELF" "$1" >&2; exit 2; }

SCRIPT="$SL/statusline-command.sh"
CACHE_FIXTURE=""; TOKENS_FIXTURE=""; COLS=""; KEEP=0; PRINT_HOME=0
QUOTA_FIXTURES=(); LASTMSG_FIXTURES=()

while [ $# -gt 0 ]; do
    case "$1" in
        --cache)      [ $# -ge 2 ] || die "--cache needs a FILE";      CACHE_FIXTURE=$2; shift 2 ;;
        --tokens)     [ $# -ge 2 ] || die "--tokens needs a FILE";     TOKENS_FIXTURE=$2; shift 2 ;;
        --quota)      [ $# -ge 2 ] || die "--quota needs NAME=FILE";   QUOTA_FIXTURES+=("$2"); shift 2 ;;
        --last-msg)   [ $# -ge 2 ] || die "--last-msg needs SID=FILE"; LASTMSG_FIXTURES+=("$2"); shift 2 ;;
        --script)     [ $# -ge 2 ] || die "--script needs a PATH";     SCRIPT=$2; shift 2 ;;
        --columns)    [ $# -ge 2 ] || die "--columns needs an N";      COLS=$2; shift 2 ;;
        --keep)       KEEP=1; PRINT_HOME=1; shift ;;
        --print-home) PRINT_HOME=1; shift ;;
        --help|-h)    usage; exit 0 ;;
        --)           shift; break ;;
        *)            die "unknown option: $1 (see --help)" ;;
    esac
done

[ -f "$SCRIPT" ] || die "statusline script not found: $SCRIPT"
[ -z "$COLS" ] || case "$COLS" in *[!0-9]*) die "--columns must be a positive integer, got: $COLS" ;; esac

SB_HOME=$(mktemp -d "${TMPDIR:-/tmp}/sl-sandbox.XXXXXX") || die "could not create a sandbox HOME"
cleanup() { [ "$KEEP" = 1 ] || rm -rf "$SB_HOME"; }
trap cleanup EXIT     # armed BEFORE the guard so a refused sandbox still removes the directory mktemp just made

# HARD GUARD — the whole point of this script. Refuse to run if the HOME we are about to hand the statusline is (or is inside)
# a real user home. mktemp normally lands under /var/folders on macOS; a TMPDIR pointed at /Users would land there instead, and
# that must fail closed rather than write a synthetic observation into somebody's shared cache.
case "$SB_HOME" in
    ''|/) die "refusing to run: sandbox HOME resolved to [$SB_HOME]" ;;
    /Users/*) die "refusing to run: sandbox HOME [$SB_HOME] is inside a real user home (/Users/...). Point TMPDIR somewhere else." ;;
esac
if [ -n "$REAL_HOME" ]; then
    case "$SB_HOME" in
        "$REAL_HOME"|"$REAL_HOME"/*) die "refusing to run: sandbox HOME [$SB_HOME] is the real HOME [$REAL_HOME] or inside it" ;;
    esac
fi

# Minimal skeleton the statusline reads: .claude/ (settings + the shared caches live here), the last-msg dir and the quota dir.
mkdir -p "$SB_HOME/.claude/last-msg" "$SB_HOME/.claude/state/statusline-quota" || die "could not build the sandbox skeleton"
printf '{}\n' > "$SB_HOME/.claude.json"
printf '{"theme":"dark"}\n' > "$SB_HOME/.claude/settings.json"

seed() {  # $1=source file $2=destination inside the sandbox
    [ -f "$1" ] || die "fixture not found: $1"
    cp "$1" "$2" || die "could not seed fixture $1 -> $2"
}
[ -z "$CACHE_FIXTURE" ]  || seed "$CACHE_FIXTURE"  "$SB_HOME/.claude/sl-ratelimit-cache"
[ -z "$TOKENS_FIXTURE" ] || seed "$TOKENS_FIXTURE" "$SB_HOME/.claude/sl-tokens-cache"
for spec in ${QUOTA_FIXTURES+"${QUOTA_FIXTURES[@]}"}; do
    case "$spec" in *=*) ;; *) die "--quota wants NAME=FILE, got: $spec" ;; esac
    seed "${spec#*=}" "$SB_HOME/.claude/state/statusline-quota/${spec%%=*}"
done
for spec in ${LASTMSG_FIXTURES+"${LASTMSG_FIXTURES[@]}"}; do
    case "$spec" in *=*) ;; *) die "--last-msg wants SID=FILE, got: $spec" ;; esac
    seed "${spec#*=}" "$SB_HOME/.claude/last-msg/${spec%%=*}"
done

[ "$PRINT_HOME" = 1 ] && printf '%s: sandbox HOME: %s\n' "$SELF" "$SB_HOME" >&2

# Final assertion before handing over: the child must see the sandbox, not the real home.
[ "$SB_HOME" != "$REAL_HOME" ] || die "internal: sandbox HOME equals the real HOME"

if [ -n "$COLS" ]; then
    env HOME="$SB_HOME" COLUMNS="$COLS" bash "$SCRIPT" "$@"
else
    env HOME="$SB_HOME" bash "$SCRIPT" "$@"
fi
