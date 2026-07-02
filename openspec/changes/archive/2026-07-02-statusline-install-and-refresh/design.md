## Context

Claude Code 以「拉式」呼叫 statusline:只在新 assistant 訊息、`/compact`、permission/vim 模式切換時重跑腳本(300ms debounce)。session 一 idle,整行就凍結 —— 時長/倒數停走、last-msg 快取新鮮度顏色不再前進。`refreshInterval`(CC v2.1.97+)可加一道定時重繪。安裝端則需把腳本絕對路徑寫進 `~/.claude/settings.json` 的 `statusLine.command`,而該檔通常已有大量其他設定(permissions、hooks、model…),絕不能覆蓋。本 change 純為回溯文件化,不改 code。

## Goals / Non-Goals

**Goals:**

- 讓 `installation` 成為單一擁有以下契約的 capability:install.sh 的冪等合併安裝、備份、非法 JSON 拒絕、相依檢查、絕對路徑解析;以及 `refreshInterval` 的預設 60、覆寫、`0`=省略/刪除、與 burn 取樣的交互。
- 規格內容與 `e25d8a2` 已 shipped 的行為逐字一致(install.sh 六情境行為測試為驗收)。

**Non-Goals:**

- 不改 code、不硬編 refreshInterval 下限、不規範其他 settings 鍵。

## Decisions

- **`jq` 合併而非覆寫**:`~/.claude/settings.json` 已有使用者其他設定。install.sh 讀整份、只重指派 `.statusLine`(以 `(.statusLine // {}) + $patch` 合併,保留既有 `padding`/`hideVimModeIndicator` 等鍵),其他鍵原封不動。相依於 `jq` 是合理的 —— statusline 本身即以 jq 解析 stdin,`jq` 已是硬相依。
- **寫入前時間戳備份 + 非法 JSON 拒絕**:改動使用者的中央設定檔屬高風險。install.sh 先 `jq empty` 驗證既有檔為合法 JSON,非法則拒絕改動並提示(絕不覆蓋一個壞檔或把它弄得更壞);合法則先複製到 `settings.json.bak.<timestamp>` 再以暫存檔 + `mv` 原子寫入。
- **`refreshInterval` 預設 60,理由載入規格**:此行所有顯示皆整分鐘粒度,故 60s 與 1s 觀感無異;而 burn-projection 每幀取樣、只留最新 5 點、且斜率要求頭尾間隔 ≥60s —— 60s 的刷新恰好讓取樣序列跨越數分鐘而有效。<~15s 會令 5 點擠進一分鐘、斜率閘永不通過而熄火;~30s 為不改 code 的安全下限。這個「60 不是隨意值,而是同時滿足顯示粒度與 burn 取樣」的理由必須在規格中,否則未來調參會誤破壞已規範的警報。
- **`0` = 省略且刪除**:`REFRESH_INTERVAL=0`(或引數 0)在「建立新檔」時不寫入 `refreshInterval` 鍵;在「合併既有檔」時額外刪除既有的 stale `refreshInterval`,使 `0` 真正回到「純事件更新」而非殘留舊值。此對稱性是刻意的。
- **絕對路徑由 install.sh 自身位置解析**:`SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)`,`command` 指向 `$SCRIPT_DIR/statusline-command.sh`,故 clone 到任意路徑皆正確,且以 `jq --arg` 傳遞使含空白/特殊字元的路徑安全。

## Implementation Contract

- **行為(已 shipped)**:(a) 既有 settings 的非 statusLine 鍵於安裝後不變;(b) 既有 `statusLine` 的其他鍵(如 padding)保留,僅 command/refreshInterval 更新;(c) 無既有檔時建立僅含 statusLine 的最小檔;(d) 既有檔非法 JSON → 拒絕、不改動、非零退出;(e) `REFRESH_INTERVAL=0` → 建立時省略、合併時刪除該鍵;(f) 引數或環境變數可覆寫間隔(正整數);(g) `command` 為可執行的絕對路徑。
- **介面/資料形狀**:寫出的 `statusLine` 物件為 `{type:"command", command:<abs>, refreshInterval?:<int>}`,合併進使用者既有 JSON;不改任何其他鍵。
- **失敗模式**:缺 `jq`、找不到 statusline 腳本、既有檔非法 JSON、非負整數以外的間隔 → 明確 stderr 訊息 + 非零退出(install.sh 是工具,失敗要響亮,與 statusline 腳本「禁 set -e」相反)。
- **驗收**:install.sh 六情境行為測試皆通過 —— 全新建立(ri=60、command 可執行絕對路徑)、合併保留其他鍵(model/permissions/padding)並更新 interval、冪等重跑、`REFRESH_INTERVAL=0` 移除鍵、非法 JSON 拒絕且原檔不變、備份確有產生;`shellcheck install.sh` 乾淨。
- **範圍邊界**:in scope = install.sh 安裝契約 + refreshInterval 語義的規格化;out of scope = 其他 settings 鍵、顯示旋鈕、code 改動。

## Risks / Trade-offs

- [未來把 refreshInterval 預設調到 <15s] → spec 明列其與 burn 取樣 ≥60s 閘的交互與安全下限,作為調參守門;rate-burn-projection spec 的 dt≥60 閘為對應的 code 端守衛。
- [install.sh 弄壞使用者 settings] → 三重防護寫入規格:先 `jq empty` 驗證、先備份、暫存檔 + 原子 `mv`;非法 JSON 一律拒絕改動。
- [`jq` 缺席] → install.sh 明確報錯並給安裝提示(`brew install jq`);statusline 本身亦硬相依 jq,故此相依不是新負擔。
