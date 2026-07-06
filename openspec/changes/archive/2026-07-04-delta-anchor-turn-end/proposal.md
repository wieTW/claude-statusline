## Why

statusline 時間段的 `(Δ)` 目前從「送出 prompt 的時刻」（`lm_epoch`，由 UserPromptSubmit hook 寫入）起算。這讓它把 Claude 實際回應的耗時也算成 idle：一次本身花 `2H8m` 的 turn 一做完，Δ 就顯示接近 2 小時並亮紅燈，但 prompt cache 是那一刻剛刷新、最熱的。Δ 的數字與其 dim/yellow/red 顏色本來就是 prompt-cache 新鮮度信號，而 cache TTL（5 分鐘 / 1 小時）是從「最後一次 request」起算，約等於 turn 結束，所以把錨點放在 prompt-submit 會讓整個信號（數字與顏色門檻）被整段 turn 時長灌水。

## What Changes

- Δ 的起算點從「送出 prompt」改為「turn 結束（最後一次活動）」。Δ 因此代表真實 idle 時間（使用者離開多久），而非「距上次 prompt 多久」。
- turn 結束時刻的來源改為 transcript 檔的 mtime（`now − mtime(transcript_path)`），沿用既有的 `transcript_path` global，不新增任何 hook。turn 進行中 transcript 持續被 append，mtime 為新、idle 只有數秒（隱藏或 dim）；idle 時 mtime 凍結，idle 隨時間增長。
- 其餘一律不變：Δ 的顯示規則（不到 60 秒隱藏、負值 clamp 為 0）、三層顏色門檻（dim 低於 `LASTMSG_WARN` / yellow 達 `LASTMSG_WARN` / red 達 `LASTMSG_STALE`），以及 clock-fallback 主文字（`HH:MM` 與跨日日期前綴）仍以 `lm_epoch`（prompt 時刻）為準。這是最小改動：只有 Δ 的年齡錨點被換掉。
- lib/collect.sh 新增一個「最後活動時刻」global 供 render.sh 使用；render.sh 的 `build_left` 用它計算 Δ 的 `lm_age`，取代 `lm_epoch`。當 transcript 不可用時回退為 `lm_epoch`，保持向後相容。

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `last-message-age`: Δ 的語意由「距上次 prompt 多久」改為「距 turn 結束的 idle」，其年齡來源由 `lm_epoch` 改為新的「最後活動時刻」（transcript mtime），並在 transcript 不可用時回退為 `lm_epoch`；顏色門檻、不到 60 秒隱藏、負值 clamp、clock-fallback 主文字與跨日前綴的既有行為不變。

## Impact

- Affected specs: last-message-age
- Affected code:
  - Modified: lib/collect.sh, lib/render.sh, tests/run-tests.sh, CLAUDE.md
  - New: (none)
  - Removed: (none)
