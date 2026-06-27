## Why

statusline 在三個邊界條件下會顯示錯誤的資源數字,而「顯示錯數字」比「慢幾毫秒」更嚴重。三個缺陷都成本低、且被現有測試套件圍住,適合一次修掉,不夾帶任何速度優化或大型重構。

## What Changes

- **Bug fix(現存)**: `_reconcile_core` 在以 `mv` 覆寫共享快取前,先確認暫存檔非空(代表 awk 成功產出);awk 失敗或只寫出半截時,保留磁碟上既有的跨 session 權威快取,而不是用空檔把它清掉。目前覆寫只受鎖與 session_id 把關,沒有把關 awk 是否成功。
- **Bug fix(假警報)**: burn 投影在估算 slope 前,要求兩個取樣點的實際時間間隔不小於 60 秒;間隔過短(重繪爆發,間隔僅 1~2 秒)時不投影。消除「短間隔 + used% 跳變」外插出的假「即將耗盡」紅警報。閾值 60 為臨界值,設成大於 60 或大於等於 120 會破壞現有合法的 dt 約等於 60 秒紅警報案例。
- **Bug fix(footgun)**: `RL_REG_TTL` 在載入時 clamp 到不小於最長 reset 視窗(604800 秒);非數值一律歸 604800。防止此設定被設過小時,剪掉仍存活舊 session 的 registry 記錄,使其下次 render 被當成全新 session、用凍住的低 used% 搶回權威而少報用量。
- 三項皆在測試套件對應段(T / T2 速率同步、Y 燃燒投影)新增回歸斷言。

## Non-Goals

- 不含任何速度或延遲優化(git speculative overlap、theme 兩段 jq 合併、token-job 移到 render 之後等)。已知 frame 約 26ms 卡在約 16ms 的並行 git 地板,且 git 狀態快取因 diffstat staleness 而不安全 — 明確排除。
- 不含大型重構(parse_input 改用 key 對應取代位置對應契約、把 reconcile awk 抽到獨立檔、degrade 14 步改命名常數、抽 build_time、property tests 等)。
- 不改變既有規則:reconcile 的「最新 session 為權威」、burn 既有的兩道閘(slope 為正、投影耗盡早於 reset)、RL_REG_TTL 的預設值 604800。

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `rate-limit-sync`: 新增兩條守衛 — 快取覆寫前需暫存檔非空(awk 成功);RL_REG_TTL 載入時 clamp 至下限。
- `rate-burn-projection`: slope 投影新增最小取樣間隔閘(dt 不小於 60 秒)。

## Impact

- Affected specs: rate-limit-sync, rate-burn-projection
- Affected code:
  - Modified:
    - lib/collect.sh
    - statusline-command.sh
    - tests/run-tests.sh
  - New: (none)
  - Removed: (none)
