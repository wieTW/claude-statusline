## 1. 測試先行: CTX 節新增紅燈案例

- [x] 1.1 在 tests/run-tests.sh 的 CTX 節接在 CTX7 之後新增 CTX8 與 CTX9，鎖定 Warning-aligned context percentage source 的主路徑與優先序: CTX8 餵入 `current_usage` 四個 token 數總和為 960400、`context_window_size` 為 1000000 的 frame，斷言 ctx 段顯示的百分比為 98；CTX9 用同一 frame 另帶 `used_percentage` 96，斷言仍顯示 98，證明對齊值勝過上游原值。斷言數字取自 design.md 的「決策: 顯示值用 100 減警示 remaining，不獨立四捨五入」所定義的 100 減 R。驗證: 實作尚未進行時跑 bash tests/run-tests.sh ，CTX8 與 CTX9 各印出一行 ★ FAIL 且整體 exit code 為 1。
- [x] 1.2 在 CTX 節續加 CTX10 與 CTX11，覆蓋 design.md 的「決策: fallback 與 suppression 的三層判準」的第一層邊界與第二層退場: CTX10 餵 token 總和大於 P 的 frame，斷言顯示 100（R clamp 為 0）；CTX11 餵 `context_window_size` 為 20000 的 frame，斷言不走對齊計算、顯示值等於同一 frame 的 `used_percentage` 經 `fmt_pct` 的結果。驗證: 實作尚未進行時跑 bash tests/run-tests.sh ，CTX10 印 ★ FAIL；CTX11 屬 fallback 迴歸鎖，實作前後皆須印 OK。
- [x] 1.3 在 CTX 節續加 CTX12 與 CTX13，鎖住 Context segment suppression on absent or non-numeric usage 與舊格式相容: CTX12 餵只有 `used_percentage` 96 的舊格式 frame，斷言 ctx 段輸出與改動前逐字元相同；CTX13 餵既無 `used_percentage` 也無 `current_usage` 的 frame，斷言 ctx 段連同 cliff marker 整段不輸出。驗證: 兩案例在實作前後皆須印 OK，且 CTX12 的期望字串是以改動前的實際輸出擷取而非手寫。

## 2. 實作: 常數與輸入解析

- [x] 2.1 [P] statusline-command.sh 頂部設定區新增具名常數 CTX_RESERVE 值 20000，註解記載來源（CC 2.1.232 binary 靜態實證、2026-08-14、隨 CC 版本可能漂移）與重驗方法（對 CC binary 以字串搜尋比對該常數）: 交付的契約是輸出保留區在整個 repo 只有這一處定義，lib/render.sh 一律引用它而非重複寫 20000，且不進 README 的 config knob 表。落實 design.md 的「決策: CTX_RESERVE 常數置頂部設定區附來源註解」。驗證: grep -c 'CTX_RESERVE=' statusline-command.sh 得 1，grep -n '20000' lib/render.sh 無命中，bash -n statusline-command.sh exit 0。
- [x] 2.2 [P] lib/collect.sh 的 `parse_input` 在 jq 提取陣列尾端附加五個數值欄位（`current_usage` 的 `input_tokens`、`cache_creation_input_tokens`、`cache_read_input_tokens`、`output_tokens`，以及 `context_window_size`），positional read 依同一順序一對一附加、缺值以空字串表示，並同步更新檔頭的 WRITES 全域清單: 交付的契約是 collect 之後五個新全域可被 render 讀到，既有 15 個欄位的落位一格未動，stdin 仍只有這一個讀者。落實 design.md 的「決策: 新欄位一律經 parse_input 尾端附加，計算放 render.sh」。驗證: bash tests/run-tests.sh 的 V 節 positional sentinel 案例全數印 OK（證明無錯位），bash -n lib/collect.sh exit 0。

## 3. 實作: 對齊計算與 ctx 段接線

- [x] 3.1 lib/render.sh 新增 `ctx_aligned_pct`（無參數、讀 collect 寫出的全域、stdout 回傳百分比字串或空字串）: 五個新欄位皆為數值且 `context_window_size` 大於 CTX_RESERVE 時回傳 100 減 R，R 以純 bash 整數算術 round-half-up 求得、P 減 T 先 clamp 到不小於 0，不 fork 任何外部程式；gate 不成立時回傳空字串交由呼叫端走 fallback。分母只扣 CTX_RESERVE、不再扣 auto-compact 的 13000，照 design.md 的「決策: 對齊 Context low 口徑，不含 auto-compact 13k buffer」。驗證: bash tests/run-tests.sh 的 CTX8、CTX9、CTX10 由 ★ FAIL 轉為 OK。
- [x] 3.2 `build_left` 的 ctx 段改為先取 `ctx_aligned_pct` 、取不到才回既有 `fmt_pct` 路徑: 交付的契約是 bar 形態、ctx:N% 形態與 bare N% 形態三者吃同一個對齊後數值，CTX_BAR gradient context bar 的分區邊界（3、6、9）與 Context meter text and compact forms 的文字形態一格未改，只有輸入值換來源。驗證: bash tests/run-tests.sh 從頭到尾全綠（含 Z 到 Z5 的 degrade 節），另以 COLUMNS=140 手動餵入 design.md 的錨點 frame（T 為 960400、window 為 1000000），在 CTX_BAR 為 true 與 false 兩種設定下都顯示 98%。
- [x] 3.3 迴歸簽收四項 MODIFIED requirement 只換輸入值、不動門檻與獨立性: Model-context-size-aware usage alerting 的 80 與 92 兩個門檻數值不變、200k cost/cache cliff marker 仍只由上游 over-200k 旗標驅動、Coloring and cliff marker are decoupled 的顏色與 marker 互不影響；CTX_BAR configuration knob 屬措辭連動修改（scenario 的判斷輸入由 `used_percentage` 改稱 selected context percentage），無獨立實作工作，斷言併入既有迴歸案例即可。驗證: bash tests/run-tests.sh 的 CTX0 至 CTX7 全部印 OK，grep -n 'ctx_red_at=' lib/render.sh 只出現 92 與 80 兩個賦值；knob 部分在同一組迴歸案例上補斷言，固定同一個對齊後百分比切換 CTX_BAR 為 true 與 false，確認 full form 分別為 12 格 bar 加百分比與 ctx:N% 文字、bare N% compact form 在兩種設定下逐字元相同、cliff marker 的出現與否不受 knob 影響。

## 4. 文件與產物同步

- [x] 4.1 [P] README.md 的 context meter 敘述改寫為新口徑: 說明 ctx% 的分子含 output tokens、分母為 context window 減 CTX_RESERVE，顯示值與 Claude Code 的 Context low 警示 remaining% 恰為 100 互補，並在 troubleshooting 註明對齊基準版本為 CC 2.1.232、auto-compact 開啟時對「until auto-compact」指示仍有 13000 的樂觀差。交付的契約是讀者不看 code 就能自行驗算一個 frame 的顯示值。驗證: 內容審閱確認上述三點齊備，grep -c 'Context low' README.md 至少為 1。
- [x] 4.2 [P] CLAUDE.md 的 Context meter 章節補上數值來源與三層 fallback 判準，維持該檔既有的英文敘述風格: 交付的契約是下一個 session 讀該章節就知道 ctx% 不是上游 `used_percentage` 原值、知道 gate 不成立時會退回舊路徑。驗證: 內容審閱確認章節同時提到 `ctx_aligned_pct` 與 CTX_RESERVE，grep -c 'ctx_aligned_pct' CLAUDE.md 至少為 1。
- [x] 4.3 [P] 跑 assets/generate.sh 重產 README 截圖 SVG: 交付的契約是 hero、alerts、degrade、themes 四張圖顯示的 ctx% 與新口徑一致，README 不留舊口徑數字。驗證: bash assets/generate.sh exit 0，git status --short 列出被更新的 assets/*.svg ；若 fixture JSON 不含 `current_usage` 導致四張圖 byte 不變，於 apply 回報明寫「截圖無變更，因 fixture 走 fallback 路徑」。

## 5. 最終驗收

- [x] 5.1 跑完整驗收三連並做 revert 反證: bash -n statusline-command.sh 、bash -n lib/collect.sh 、bash -n lib/render.sh 三者 exit 0，shellcheck -x statusline-command.sh 無新增警告，bash tests/run-tests.sh 印出 ALL CHECKS PASSED；接著把 lib/render.sh 與 lib/collect.sh 的本次改動暫時還原，確認 CTX8、CTX9、CTX10 轉為 ★ FAIL 後再復原。交付的契約是新測試真的鎖住新行為而非恆綠。驗證: 上述四條命令的實跑輸出與 revert 反證結果一併寫進 apply 階段回報。
