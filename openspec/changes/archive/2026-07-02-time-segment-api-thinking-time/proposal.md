## Why

時間段目前的主體是 session 總時長（`cost.total_duration_ms`，wall-clock 含閒置），回答的是「session 開多久了」，不是使用者要的「Claude 這個 session 累計實際思考/生成了多久」。stdin JSON 有現成欄位 `cost.total_api_duration_ms`（累計等 API 回應的時間；不含閒置、不含本地 tool 執行），是最貼近「thinking 時間」的可得值 — 純 extended-thinking block 的時間任何來源都拿不到。

## What Changes

- 時間段 primary 改為三層 fallback 鏈：`cost.total_api_duration_ms` 有效且 >0 → API 工作時間為主體（**取代**總時長顯示）；否則 `cost.total_duration_ms` 有效且 >0 → 現行總時長；否則 → 現行時鐘 fallback（含 cross-day 前綴規則，全部不變）。
- 新增秒級精度 formatter `fmt_dur_s`：<1m → `45s`、<1h → `3m45s`、≥1h 委派既有 `fmt_dur`（`1H15m`／`1D3H`）。既有 `fmt_dur` 不動。
- `parse_input` 新增 positional 欄位 `api_ms`（jq 陣列與 read 各插一位，`now` 維持最後一位），走共用 sanitize map。
- `(Δ)` last-msg delta 的門檻、顏色、顯示規則完全不變；primary 維持 dim；不加 glyph；段落仍掛 `seg_lastmsg`，degrade ladder 14 步不重編號。

## Non-Goals

- 不做「當前單輪計時」（spinner 那種回完歸零的時間）— 無現成欄位，需掃 transcript 推算，已否決。
- 不顯示純 extended-thinking block 時間 — 任何來源（stdin JSON、transcript）都不存在此資料。
- 不採「API 時間與總時長並列」— 使用者已明確選擇取代。
- 不動 git 段、token 段、rate-limit 段、degrade ladder 步序。
- 不掃 transcript、不加背景 job — 本功能只讀既有 stdin JSON。

## Capabilities

### New Capabilities

（無）

### Modified Capabilities

- `last-message-age`: 時間段 primary 的來源從「session 總時長（fallback 時鐘）」兩層鏈改為「API 工作時間 → session 總時長 → 時鐘」三層鏈；新增 `fmt_dur_s` 秒級格式規則與無效值（0／負數／非數值）降級行為。cross-day 前綴條款的觸發條件措辭同步改為「兩個 cost 欄位皆不可用」。

## Impact

- Affected specs: `last-message-age`（delta：MODIFIED 兩條 requirement）
- Affected code:
  - Modified: lib/collect.sh（WRITES header + jq 陣列 + positional read 新欄位 api_ms）
  - Modified: lib/render.sh（新增 fmt_dur_s、primary 三層鏈、相關註解改寫）
  - Modified: tests/run-tests.sh（V sentinel 段擴充至 18 欄；新增 API 測試段）
  - Modified: CLAUDE.md（時間段文件與左半地圖描述）
