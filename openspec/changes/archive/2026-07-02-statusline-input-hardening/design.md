## Context

statusline 把外部字串(路徑、model 名、session 名、git 分支、last-msg 檔內容…)直接拼進一行終端輸出。任一未清理的 ESC 位元組會同時(a)注入終端被解析成 CSI,(b)讓 `vis_width` 的可見寬度計算與終端不一致而把單行推成換行。因此清理不是可選項,而是正確性與安全的共同前提。硬約束沿用全域規則:bash 3.2、禁用 `set -e`、背景 job 一律 `</dev/null`、`LC_ALL=C` 釘住(`${#x}` 以位元組計數是 `vis_width` 的依據)、`parse_input` 位置對應 read 順序不得更動。本 change 純為回溯文件化,不改 code。

## Goals / Non-Goals

**Goals:**

- 讓 `input-sanitization` 成為單一擁有以下契約的 capability:parse_input 清理集、`session_id` allow-list、`transcript_path` 穿越拒絕、共用 `_sanitize_field`、`umask 077` 私有快取、以及「只有自己的 SGR 抵達終端」總不變式。
- 規格內容與 `6ee64f9` 已 shipped 的行為逐字一致(回歸案例 H/L/N/P/Q/R/S 為驗收)。

**Non-Goals:**

- 不改 code、不改任何過濾集或上限、不重構 parse_input 契約。

## Decisions

- **allow-list 而非逐一 escape**:`session_id` 會被拼進(a)last-msg 檔路徑、(b)awk `-v sid=`、(c)空白分隔快取行三種下游。逐一 escape 需對三種語境各寫一套逃逸,易漏;改為只允許 `[A-Za-z0-9_-]`(真實 UUID 的超集邊界),一次擋掉 `\`(awk)、空白(記錄)、`/`與`..`(路徑)三類危險字元。違規整欄歸空,而非部分修剪 —— 下游每個讀者都已把空值視為 graceful no-op(跳過讀檔/跳過 token 累加),故歸空是安全且已有處理的降級。
- **清理放在 jq 之後,而非塞進 jq filter**:jq 的 explode/implode 只保證 JSON 結構層的字元類;但 allow-list 與穿越拒絕是「特定下游用途」(檔路徑、awk、記錄格式)的約束,和 JSON 無關。放 jq 後、read 之前一次 `case` builtin,零 fork,且不動 jq 陣列的位置對應。
- **抽出 `_sanitize_field` 共用**:`git_branch`(來自 git)與 `last_msg`(讀自檔)兩條都繞過 jq。先前 last-msg 在 render.sh 內嵌三行手寫清理,git_branch 則完全沒清 —— 一個惡意分支名可注入 SGR。抽成 collect.sh 的單一 `_sanitize_field`(設全域 `REPLY`,無 command-substitution fork;bash 3.2 無 nameref),兩處共用,消除「改一處忘另一處」的漂移風險。清理集與 parse_input 的 `select(. >= 32 and (. < 127 or . > 159))` 一對一鏡像。
- **`umask 077` 而非事後 `chmod`**:快取/暫存/鎖在多處建立(mkdir 鎖、`: > tmpfile`、`mv`),事後逐一 chmod 易漏且有 race。改在 `_reconcile_core` 與 `tokens_update` 子行程開頭一次 `umask 077`,之後所有建立自動 600/700。兩者皆為 subshell 範圍(procsub / 背景 job / 測試 subshell),不污染主行程 umask。
- **256 上限是位元組(bash 鏡像),非 codepoint**:`_sanitize_field` 的 `REPLY:0:256` 在 `LC_ALL=C` 下截位元組,與 parse_input 的 256-codepoint 意圖對齊但機制不同;此上限同時是防 `vis_width` O(n²) 卡頓的 DoS 守衛(非純美觀),故位元組略嚴於 codepoint 是安全方向。

## Implementation Contract

- **行為(已 shipped)**:(a) 任何欄位含 C0/DEL/C1 → 該區間字元被剝除;(b) `session_id` 含 `[A-Za-z0-9_-]` 以外字元(含 `/`、`..`、空白、控制碼) → 整個 `session_id` 歸空,連帶 last-msg 讀取與 token 累加皆 graceful 跳過;(c) `transcript_path` 含 `..` → 歸空;(d) `git_branch` 與 `last_msg` 經 `_sanitize_field` 後只含可列印字元且 ≤256 位元組;(e) rate-limit / token 快取、暫存、鎖以 600/700 建立。
- **介面/資料形狀**:無對外契約改變。`_sanitize_field` 設全域 `REPLY`;`parse_input` 的 read 順序與 jq 陣列位置對應不變;快取檔行格式(S/W/P、T)不變。
- **失敗模式**:全部靜默安全降級 —— 違規值歸空由下游當 no-op,非法輸入絕不 abort、不 `set -e`。
- **驗收**:`bash tests/run-tests.sh` 的安全回歸案例 H/L/N/P/Q/R/S 全綠;行為測試確認穿越樣式 `session_id` 不外洩任意檔首行、快取檔權限為 600;完整 gate(`bash -n`×3、`shellcheck -x`、測試套件)皆 exit 0,末行 `ALL CHECKS PASSED`。
- **範圍邊界**:in scope = 上述六項清理契約的規格化;out of scope = 其餘所有行為與 code 改動(本 change 不改 code)。

## Risks / Trade-offs

- [未來放寬 allow-list] → spec 以 H/L/N/P/Q/R/S 回歸案例作守門;`session_id` 歸空的下游 no-op 行為列為明確 scenario,任何放寬都會使該案例失敗。
- [allow-list 誤擋合法 session id] → 真實 CC session id 為 UUID(`[0-9a-f-]`),嚴格是 `[A-Za-z0-9_-]` 的子集,不會被誤擋;此邊界於 spec 記錄。
- [`umask` 洩漏到主行程] → 兩處 `umask 077` 皆在只經 procsub/背景 job 執行的函式內,為 subshell 範圍;spec 明列此約束以防未來把函式改成在主行程 inline 呼叫。
