## Why

Claude Code statusline 目前看不到兩個對重度使用者最關鍵的資訊:**累計 token 消耗**(尤其 subagent / workflow 那筆隱形大額開銷 —— 實測單場對話 subagent 的 token 量可達主 session 的數倍),以及**額度會在 reset 前耗盡的預警**。同時有三個既有正確性問題:跨 session rate-limit 同步在多 session 併發 render 時會遺失更新(lost update);context 用量警示對 1M context 模型沿用寫死的 80% 門檻而失準;跨日的「上次訊息」時鐘只存 HH:MM,昨天的 prompt 會被當成今天而誤導。本變更一次補齊可見度缺口並修正這些問題。

## What Changes

新功能:
- 新增 **token 消耗段**:左側顯示本 session 的 input+output 累計(不含 cache),有 subagent 時追加 subagent 累計;資料由 stdin 的 transcript path 與其同層 subagents 目錄推得,背景加總寫 cache、前景只讀,永不阻塞單幀。
- 新增 **rate-limit 燃燒投影警報**:依近期消耗速度預測額度見底時間,僅在「正在消耗且會在 reset 前見底」時於 quota 旁顯示倒數警報,平時隱形;緊迫度以顏色分級,敏感度可由設定旋鈕調整。
- 新增 **漸進式壓縮排版**:為每個區段定義優先級與緊湊/完整兩種形態,終端變窄時依固定犧牲順序逐步降級(先截斷、收 junction,最後才依優先級丟棄),取代目前較粗的截斷行為。

修正:
- 修正跨 session rate-limit 同步:多 session 併發下的 lost-update 競態,以及空 session_id 仍做整檔破壞性改寫的問題。
- 修正 context 用量警示:改以 context window 大小 / 超過 200k 旗標判斷,取代寫死的 80% 門檻。
- 修正跨日「上次訊息」時鐘:跨本地日曆日時補上日期,避免顯示成今天。

內部強化(無觀感變化,歸於 design / tasks):parse_input 位移耦合防呆(欄位編號註解 + sentinel 測試)、抽出重複的時間格式化與溢位保護邏輯、rate-limit 同步背景化以省去每幀序列成本、更新過時註解。

## Capabilities

### New Capabilities

- `token-usage`: statusline 顯示本 session 與 subagent 的累計 token 消耗,以及其背景加總與快取機制
- `rate-burn-projection`: 依消耗速度預測 rate-limit 額度見底,並以警報語意條件式顯示
- `adaptive-layout`: 單行內依終端寬度逐步降級(截斷 / 收 junction / 依優先級丟棄)的排版規則
- `rate-limit-sync`: 跨 session rate-limit 用量同步在併發與空 session 情境下的正確性
- `context-meter`: context 用量百分比的顯示與警示門檻(對 200k / 1M context 模型皆正確)
- `last-message-age`: 「上次訊息」時間與快取新鮮度顏色,含跨日正確性

### Modified Capabilities

(none)

## Impact

- Affected specs: token-usage, rate-burn-projection, adaptive-layout, rate-limit-sync, context-meter, last-message-age(皆為新增)
- Affected code:
  - Modified: statusline-command.sh, lib/collect.sh, lib/render.sh, tests/run-tests.sh, CLAUDE.md
  - New: openspec/specs 下 6 個新 capability 規格(由本流程產生)
  - Removed: (無;repo root 的 preview-*.html 為討論草稿,實作後清除,不屬規格範圍)
- Runtime artifacts: 新增一個 token 加總快取檔於使用者 .claude 目錄(仿現有 rate-limit 快取);現有 rate-limit 快取新增取樣行供燃燒投影使用
- 約束:須遵守 CLAUDE.md 硬規則(目標 bash 3.2、不得 set -e、每個背景 job 導入 /dev/null、LC_ALL=C 固定、parse_input 為唯一輸入消毒點、256 codepoint 上限不可放寬、jq 控制字元過濾用 explode/implode、parse_input 讀取順序與 jq 陣列一一對位);所有改動須通過既有 verify gate(三檔 bash -n、shellcheck -x、tests/run-tests.sh 印出 ALL CHECKS PASSED)
