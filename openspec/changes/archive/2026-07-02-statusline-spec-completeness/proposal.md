## Why

六份既有 spec 各自漏描述了一些已存在且被測試圍住的行為 —— 例如 context 段的漸層 bar、rate-limit 快取的第三種 `P` 行、burn 的 `RL_SYNC` 開關、token 的 dedup/single-flight/prune、以及 last-message 的 zero-duration 邊界。這些不是 drift(spec 沒說錯),而是 incomplete(spec 沒說完)。本 change 把它們補齊,讓規格覆蓋實際行為。純文件,不改 code。

## What Changes

- **`context-meter`(ADD)**:`CTX_BAR` 漸層 bar(12 格、四區顏色、TRK 灰軌)、`ctx:N%` 與裸 `N%` compact 形式、以及 `⚑` 標記附加於全部形式;used% 空/非數值時整段(含標記)靜默。含 `CTX_BAR` 旋鈕。
- **`rate-limit-sync`(ADD)**:快取第三種行型 `P <resets_at> <ts> <used>`(每窗 ≤5 樣本、~10800s horizon);`RL_SYNC` 主開關與關閉路徑;stale-lock steal;過期窗口(resets_at ≤ now)剪除;malformed/舊格式行於改寫時靜默丟棄。
- **`rate-burn-projection`(ADD)**:`RL_SYNC=false` 時整個警報停用;取樣/投影僅 5h 窗口(7d 從不取樣);balanced 上限具體為 6300s(105 分)、conservative 1800s(30 分)、sensitive 無額外上限。
- **`token-usage`(ADD)**:以 `.message.id` dedup(CC 每內容區塊一列、重複同一 usage,否則超計 ~10x);mkdir single-flight 重算鎖(30s stale-steal);跨 session 依 `RL_REG_TTL` 剪 `T` 行;段顏色(session WH / subagent YL / `⊂` DM);快取行 schema。
- **`adaptive-layout`(ADD)**:`RIGHT_ALIGN` 旋鈕(關閉或寬度不可得 → 退回 ` │ ` join);`EDGE_PAD` / `JGAP` 作為可調旋鈕文件化。
- **`last-message-age`(MODIFY + ADD)**:MODIFY —— session 時長為主文字的條件收緊為「present 且 >0」(`dur_ms -gt 0`),0/負值退回 HH:MM 時鐘(此為記錄 code 現狀,不改行為);ADD —— 無 last-msg 檔且無時長時整個時間段省略。

## Non-Goals

- 不改任何 code。所有行為皆已存在且測試綠;本 change 只補規格。
- 不新增 capability(那是 display-segments / theme-palette / rate-limit-display 三個 change)。
- 不改 `last-message-age` 的既有行為 —— zero-duration 採「文件對齊 code」方向(非改 code 顯示 `0m`)。

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `context-meter`: 補漸層 bar、compact 形式、空值靜默、`CTX_BAR` 旋鈕。
- `rate-limit-sync`: 補 `P` 行型、`RL_SYNC` 開關、stale-steal、過期剪除、malformed 清理。
- `rate-burn-projection`: 補 `RL_SYNC` 停用、5h-only、具體 sensitivity 上限。
- `token-usage`: 補 dedup、single-flight、prune、段顏色、快取 schema。
- `adaptive-layout`: 補 `RIGHT_ALIGN` 退回、`EDGE_PAD`/`JGAP` 旋鈕。
- `last-message-age`: 修正 zero-duration 條件、補 both-empty 省略。

## Impact

- Affected specs: context-meter, rate-limit-sync, rate-burn-projection, token-usage, adaptive-layout, last-message-age
- Affected code: (none — 純文件補完;行為已存在於 lib/render.sh、lib/collect.sh)
