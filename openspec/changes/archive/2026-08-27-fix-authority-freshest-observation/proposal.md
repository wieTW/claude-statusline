# Fix: 權威改由最新觀測決定，閒置 session 不再凍住週限顯示

## Why

statusline 的 7d 額度顯示落後真值: 使用者看到 `4D14H 19%`，同一時間 `/usage` 顯示 `4D14H 15%`。2026-08-27 端對端重現確認根因是跨 session cache 的權威規則「first_seen 最大的 session 就是權威」（`lib/collect.sh:362-365` 的 `applycls`，對應 spec requirement `Newest-session authority survives concurrent renders`）: 最後開的那個 session 一旦閒置，它最後回報的值就被凍在權威記錄裡；同一時間正在被使用、因而看得到真值的較舊 session，被 `myfs+0 >= Rf[c]+0` 擋住，寫不進去。

這條規則賴以成立的前提本身是錯的。實測（2026-08-27，session id `52a82f13`、`first_seen 1787761211`）: 該 session 連續持有權威的 44 分鐘內，cache 的 W5 由 14 變 20、W7 由 85 變 86。證明 Claude Code 每次 API round trip 都會刷新該 session 的 `rate_limits`，並沒有把值凍結在 session 啟動時。真正成立的只有「閒置的 session 會一直回報它最後拿到的值，只有倒數在動」。`lib/collect.sh:232-234` 的區塊註解與 `openspec/specs/rate-limit-sync/spec.md:5` 的 Purpose 句（`correcting Claude Code's frozen per-session start snapshot`）依此更正。

## What Changes

- **權威判準由 session 年齡改為觀測新鮮度**: 每個 class（five-hour / seven-day）的權威記錄，改由「最後一次被觀測到變化的回報」持有，與回報者的 `first_seen` 無關。較舊但正在使用中的 session 因此能改寫閒置新 session 留下的過期值。
- **每個 session、每個 class 記錄上一次回報的 `(resets_at, used%)` pair 與它的 `observed_at`**: 本 frame 的 pair 與自己 `S` 行裡的前次 pair 不同，`observed_at` 蓋成 `now`；相同則原值沿用不動；沒有前次 pair 時（新 session，或舊格式 `S` 行升級）`observed_at` 取該 session 的 `first_seen`，升級當下的舊 session 因此不會憑空奪權。
- **`applycls` 改比 `observed_at`**: 回報的 `observed_at >=` 該 class 權威記錄的 `observed_at` 才整筆採納（key、值、`observed_at` 一起換），否則保留 cache 既有行。採納對兩個方向與 window roll 都成立: used% 上升、cap 調高後 used% 下降、`resets_at` 換新（新 key 依定義就是 pair 改變）。同一秒平手沿用今天的行為，由後寫者勝。
- **cache 格式**: `W5`/`W7` 第 4 欄語意由 `auth_first_seen` 改為 `auth_observed_at`（同為 epoch 秒，舊行可直接比較，第一輪 reconcile 即完成過渡，沒有 migration 步驟）；`S` 行由 3 欄擴為 9 欄，尾端帶每個 class 的 `<resets_at> <used> <observed_at>`，該 class 沒回報過就以 `-` 佔位。舊的 3 欄 `S` 行仍被接受並就地升級，缺欄視為「沒有前次 pair」。格式維持單行、空白分隔、`LC_ALL=C`、bash 3.2 與 awk 可解析。
- **明列為不變的行為**: lock 序列化的 read-modify-write 與 no-lost-update、拿不到 lock 時的安全降級、空 `session_id` 的唯讀路徑、registry retention TTL 下限、frame 一律顯示它讀到的 class 權威（archived change 的 post-roll 行為）、session 結束後權威仍持續、權威行不受 TTL 剪除。
- **前提措辭更正**: `lib/collect.sh` 的 rate-limit sync 區塊註解、capability spec 的 Purpose 句、README 中「Claude Code 在 session 啟動時凍結 quota %」的三處描述，一律改為「閒置 session 會一直回報它最後拿到的值」。
- **測試**: `tests/run-tests.sh` 增 4 個 regression case（較舊 session 的新觀測奪權、cap 調高後的下降被採納、window roll 被採納、閒置 session 的未變 pair 奪不回權威），細節在 tasks.md 第 2 節。

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `rate-limit-sync`: 權威規則由 newest-session 改為 freshest-observation；`S` 行擴充為帶 per-class 觀測狀態；`W5`/`W7` 第 4 欄語意改為 `auth_observed_at`；old-format 判定與其餘引用舊規則的 requirement 措辭同步。
- `rate-burn-projection`: 取樣量的描述由已退場的 newest-session authority 改為 freshest-observation authority 的採納值；取樣鍵、bounded series、slope 與兩道 gate 都不變。

## Impact

- Affected specs: rate-limit-sync, rate-burn-projection
- Affected code:
  - Modified: lib/collect.sh, tests/run-tests.sh, README.md, CLAUDE.md, AGENTS.md
  - New: (none)
  - Removed: (none)
- 不受影響: lib/render.sh（`remaining% = 100 - used%` 與 D/H 倒數）、statusline-command.sh、顯示格式。
