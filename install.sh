#!/usr/bin/env bash
# install.sh — wire this statusline into Claude Code (~/.claude/settings.json).
#
# What it does (idempotent, safe to re-run):
#   • points  statusLine.command  at this repo's statusline-command.sh (absolute path)
#   • sets    statusLine.type            = "command"
#   • sets    statusLine.refreshInterval = 60   (idle re-render cadence; see below)
# It MERGES into your existing settings.json with jq — every other setting (permissions,
# hooks, model, …) is preserved untouched — and backs the file up before writing.
#
# Usage:
#   ./install.sh                 # install with refreshInterval 60 (default)
#   ./install.sh 30              # install with a custom interval (seconds, integer >= 1)
#   REFRESH_INTERVAL=0 ./install.sh   # install WITHOUT refreshInterval (0 = omit the key)
#
# Why 60: the line's display granularity is whole minutes (Δ / countdowns / duration), and the
# burn-projection alarm samples used% at most every render — 60s keeps that sampling series valid.
# Going below ~15s can starve the burn alarm; the safe floor without code changes is ~30s.
#
# Unlike the statusline itself (which must never use set -e), this installer fails loudly on error.
set -euo pipefail

# ── resolve paths ─────────────────────────────────────────────────────────────────────────────
# Absolute dir of THIS script → the statusline lives right next to it. Handles symlinks/relative $0.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
STATUSLINE="$SCRIPT_DIR/statusline-command.sh"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"   # CLAUDE_SETTINGS override is mainly for testing

# ── interval: arg 1 or $REFRESH_INTERVAL, default 60; 0 = omit the key ─────────────────────────
REFRESH_INTERVAL="${1:-${REFRESH_INTERVAL:-60}}"
case "$REFRESH_INTERVAL" in
    ''|*[!0-9]*) echo "install: refresh interval must be a non-negative integer, got: $REFRESH_INTERVAL" >&2; exit 1 ;;
esac

# ── dependency + target checks ────────────────────────────────────────────────────────────────
if ! command -v jq >/dev/null 2>&1; then
    echo "install: jq is required (the statusline parses its stdin JSON with jq)." >&2
    echo "         macOS:  brew install jq" >&2
    exit 1
fi
if [ ! -f "$STATUSLINE" ]; then
    echo "install: cannot find statusline-command.sh next to this installer ($STATUSLINE)." >&2
    exit 1
fi
chmod +x "$STATUSLINE" 2>/dev/null || true   # Claude Code invokes it directly; make sure it's executable

# ── build the statusLine object as JSON (merged into any existing statusLine, preserving padding/etc.) ─
# refreshInterval is included only when > 0; a 0 (or explicit omit) drops the key so CC reverts to
# event-only updates. jq --arg keeps the path safe regardless of spaces/special chars.
if [ "$REFRESH_INTERVAL" -gt 0 ]; then
    SL_PATCH=$(jq -n --arg cmd "$STATUSLINE" --argjson ri "$REFRESH_INTERVAL" \
        '{type:"command", command:$cmd, refreshInterval:$ri}')
else
    SL_PATCH=$(jq -n --arg cmd "$STATUSLINE" '{type:"command", command:$cmd}')
fi

mkdir -p "$(dirname "$SETTINGS")"

# ── merge (or create) ─────────────────────────────────────────────────────────────────────────
tmp=$(mktemp "${SETTINGS}.XXXXXX")
trap 'rm -f "$tmp"' EXIT
if [ -f "$SETTINGS" ]; then
    if ! jq empty "$SETTINGS" 2>/dev/null; then
        echo "install: $SETTINGS is not valid JSON — refusing to touch it. Fix or move it, then re-run." >&2
        exit 1
    fi
    backup="${SETTINGS}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$SETTINGS" "$backup"
    # Merge so a pre-existing statusLine (e.g. a custom padding/hideVimModeIndicator) keeps its other keys,
    # but drop a stale refreshInterval first when we're omitting it, so REFRESH_INTERVAL=0 truly removes the key.
    jq --argjson sl "$SL_PATCH" \
       '.statusLine = ((.statusLine // {}) + $sl)
        | if ($sl | has("refreshInterval")) then . else .statusLine |= del(.refreshInterval) end' \
       "$SETTINGS" > "$tmp"
    mv "$tmp" "$SETTINGS"
    echo "install: updated $SETTINGS (backup: $backup)"
else
    jq -n --argjson sl "$SL_PATCH" '{statusLine:$sl}' > "$tmp"
    mv "$tmp" "$SETTINGS"
    echo "install: created $SETTINGS"
fi
trap - EXIT

# ── report ────────────────────────────────────────────────────────────────────────────────────
echo
echo "statusLine is now:"
jq '.statusLine' "$SETTINGS"
echo
echo "Done. Restart your Claude Code session (or run /statusline) for it to take effect."
