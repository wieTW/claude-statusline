## Why

時間段原本只顯示「上次發問的絕對時鐘 `HH:MM`」，缺少「這個 session 已經跑多久」這個常用資訊；而 Claude Code 在 stdin JSON 已提供 `cost.total_duration_ms`（session 開始至今的牆鐘時長，含閒置），卻未被使用。把時間段主文字改成 session 時長，可在**不增加版面段數**的前提下補上這項資訊。

## What Changes

- 時間段（`build_left` 左半最後一段）的主文字由「絕對時鐘 `HH:MM`」改為 **session 時長**：來源 `cost.total_duration_ms`，除以 1000 後經**既有** `fmt_dur` 格式化（`1H15m` / `40m` / `2D3H`），以暗灰（`DM`）呈現。
- 保留括號內「距上次發問」的 delta `(Δ)` 及其快取新鮮度配色（`LASTMSG_WARN` / `LASTMSG_STALE` 兩階）；age < 60s 仍隱藏 Δ；負值（時鐘偏移）仍夾為 0。
- `cost.total_duration_ms` 缺漏或非數值時 **fallback 回原本 `HH:MM` 時鐘**（含跨日 `MM-DD` 前綴），完全向後相容。
- 跨日 `MM-DD` 前綴自此**僅作用於時鐘 fallback**；session 時長是經過的時間跨度、非時鐘，不需跨日修正。
- 連帶外觀調整：model 顯示全形由 `Opus 4.8 (1M)` 壓成 `Opus 4.8(1M)`（去掉括號前空格），替時長段讓出版面。

## Non-Goals

- **不新增獨立版面段**：時長併入既有時間段，自動沿用其降級 step（不動 14 步降級階梯、不動 `adaptive-layout` 規範）。
- **不改 `fmt_dur` 格式**（維持大寫 H：`1H15m`）；改小寫 h 會連帶影響 rate 倒數顯示，不在本次範圍。
- **不更新示意字串**：`adaptive-layout` / `context-meter` spec 內以 `Opus 4.8 (1M)` 作為 example 的字串、以及 `context-meter` 對 `model/ (1M context)/ (1M)` 的程式碼引用，皆不在本次更新範圍 — 去空格是純外觀的全形拼寫變動，不改任何規範行為（壓縮契約仍 full→`Opus`、1M 偵測不變），為一個空格 restate 三個 requirement 無規範價值。
- **不顯示 per-turn（單輪）時間或 spinner 詞**：Claude Code 的 statusline JSON 未提供這兩者。

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `last-message-age`: 時間段主文字改為 session 時長並取代絕對時鐘、時鐘降為 fallback；跨日日期前綴改為僅作用於時鐘 fallback；delta `(Δ)` 的計算、隱藏條件與配色階梯維持不變。

## Impact

- Affected specs: last-message-age（modified）
- Affected code:
  - Modified:
    - lib/collect.sh — 新增 cost.total_duration_ms 解析為 dur_ms（positional 欄位第 16、now 順移第 17，WRITES header 同步）
    - lib/render.sh — 時間段改寫（時長為主、時鐘 fallback）＋ model 代換去空格
    - tests/run-tests.sh — 新增 DUR 測試段、V 哨兵擴為 17 欄位含 dur_ms、A2 與 Z2 的 model 斷言更新
    - CLAUDE.md — 概覽行與時間段章節同步
  - New: (none)
  - Removed: (none)
