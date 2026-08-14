## Context

statusline 的 ctx 段目前把上游 `context_window.used_percentage` 原值經 `fmt_pct` 四捨五入後直接顯示（bar、`ctx:N%`、bare `N%` 三形態同一數值）。Claude Code 的「Context low (N% remaining)」警示（2.1.232 binary 靜態實證，2026-08-14）用另一套公式: T 為 `current_usage` 四個 token 數之和（input、cache_creation、cache_read、output），P 為 `context_window_size` 減 20000 的輸出保留區，remaining 為 round(100 乘 (P 減 T) 除以 P)。兩口徑在 1M 模型邊緣差約 2 個百分點（實例 96% 對 2% remaining）。stdin JSON 已含本地重算所需全部欄位: `context_window.current_usage` 的四個 token 數與 `context_window.context_window_size`。既有硬規則: `parse_input` 是唯一 stdin 讀者、positional read 契約、no set -e、LC_ALL=C、collect 與 render 的 WRITES/READS 全域變數契約。

## Goals / Non-Goals

**Goals:**

- ctx 段顯示的 used% 與 CC「Context low」警示的 remaining% 在同一筆 usage 快照下恰為 100 互補（整數層級一致，含 .5 邊界）。
- 舊版 CC（無 `current_usage` 或無 `context_window_size`）行為完全不變（fallback 到 `used_percentage`）。
- 紅門檻、cliff marker、三形態、degrade 行為全部照舊，只換輸入數值。

**Non-Goals:**

- 不追 auto-compact 開啟時的額外 13000 buffer（CC 該狀態下字樣是「N% until auto-compact」）: statusline JSON 看不到 auto-compact 狀態，且使用者委託明指對齊「Context low」。
- 不新增 remaining% 顯示形態、不改 bar 視覺、不動 token 段與 rate 段。
- 不做 20000 的 README 級使用者 config knob（反投機設定；見決策）。
- 不在本 change 內重校 80 與 92 紅門檻數值（維持現值；見 Open Questions）。

## Decisions

### 決策: 對齊 Context low 口徑，不含 auto-compact 13k buffer

對齊目標選 auto-compact 關閉時的「Context low」公式（P 為 window 減 20000）。替代案「再扣 13000 對齊 auto-compact 指示」否決: statusline JSON 無 auto-compact 狀態欄位，硬扣會讓 auto-compact 關閉的 session（使用者實際情境）反而失準。

### 決策: 顯示值用 100 減警示 remaining，不獨立四捨五入

顯示 used% 定義為 100 減 round(100 乘 (P 減 T) 除以 P)，而非獨立算 round(100 乘 T 除以 P): 兩式在 .5 邊界會差 1，前者保證與警示顯示的整數恰互補。T 大於等於 P 時 remaining clamp 為 0、顯示 100。運算用純 bash 整數算術（round-half-up: rem 等於 (200 乘 (P 減 T) 加 P) 整除 (2 乘 P)，P 減 T 先 clamp 到不小於 0），不 fork 外部程式，符合本 repo 的並行效能哲學。

### 決策: 新欄位一律經 parse_input 尾端附加，計算放 render.sh

lib/collect.sh 的 `parse_input` jq 陣列尾端附加五個數值欄位（`current_usage` 的 input_tokens、cache_creation_input_tokens、cache_read_input_tokens、output_tokens 與 `context_window_size`），positional read 順序一對一跟進，維持單一 sanitization 入口。對齊值計算放 lib/render.sh 新 helper `ctx_aligned_pct`（讀 collect 寫出的全域、echo 結果字串），`build_left` 的 ctx 段改吃它: collect 只 parse、render 管 presentation math，維持 WRITES/READS 契約。替代案「collect.sh 算好再交」否決: 混層，且 fallback 判斷屬顯示語意。

### 決策: CTX_RESERVE 常數置頂部設定區附來源註解

20000 以具名常數 CTX_RESERVE 放 statusline-command.sh 頂部設定區，註解記載來源（CC 2.1.232 binary 常數，2026-08-14 靜態實證，隨 CC 版本可能漂移）與重驗方法。不進 README config knob 表: 使用者無調整需求，開 knob 是投機設定；集中一處是為了 CC 改版時單點可修。

### 決策: fallback 與 suppression 的三層判準

第一層: 五個新欄位皆為數值且 context_window_size 大於 CTX_RESERVE，用對齊口徑。第二層: 否則 fallback 既有 `used_percentage` 路徑（含 `fmt_pct` 四捨五入），行為與現行完全相同。第三層: 兩來源皆無數值，整段 suppress（沿用既有 `fmt_pct` 空值 gate，cliff marker 一併隱藏）。紅門檻 80 與 92 的比較機制與 cliff marker 的獨立性不動，只是比較對象換成最終選定的百分比。

## Implementation Contract

- 行為: 當 stdin JSON 的 `context_window.current_usage` 四個 token 數皆為數值、且 `context_window.context_window_size` 為數值並大於 20000 時，ctx 段三形態顯示的百分比 N 滿足 N 等於 100 減 R，R 為 round(100 乘 (P 減 T) 除以 P)、P 為 context_window_size 減 20000、T 為四個 token 數之和、P 減 T 為負時 R 為 0。實算錨點: T 為 960400、window 為 1000000 時 P 為 980000、R 為 2、顯示 98%（現行顯示 96%）。
- Fallback 行為: 新欄位任一缺席或非數值、或 context_window_size 不大於 20000，顯示值回到 `used_percentage` 經 `fmt_pct` 的現行路徑，輸出與改動前逐字元相同。兩來源皆空時整段（含 cliff marker）不輸出。
- 介面與資料形狀: `parse_input` 的 jq 提取陣列與 positional read 各在尾端新增五個欄位，全部數值型、缺值以空字串表示；lib/render.sh 新增函式 `ctx_aligned_pct`（無參數、讀全域、stdout 回傳最終百分比字串或空字串）；`build_left` ctx 段的 `_pct` 改由該函式取得。CTX_RESERVE 常數定義於 statusline-command.sh 頂部設定區。
- 失敗模式: 任何欄位解析失敗走 fallback，不得輸出錯誤訊息到 statusline（本 repo 無 set -e 且輸出即畫面）；除法分母恆為正（gate 已排除非正值）。
- 驗收: tests/run-tests.sh 的 CTX 節新增案例至少涵蓋: (a) T 960400、window 1000000 顯示 98%；(b) 同 frame 帶 used_percentage 96 但含完整 current_usage 時對齊值勝出（證明優先序）；(c) 僅有 used_percentage 的舊格式 frame 顯示 96%（fallback 逐字元不變）；(d) T 大於 P 顯示 100%；(e) window 缺或不大於 20000 走 fallback；(f) 全部缺席整段 suppress。全套驗收命令: bash -n 三檔、shellcheck -x statusline-command.sh、bash tests/run-tests.sh 印出 ALL CHECKS PASSED；把實作 revert 後新 CTX 案例必須 FAIL。顯示會變，照 repo 慣例跑 assets/generate.sh 重產 README 截圖。
- 範圍邊界: in scope 為 ctx 段數值來源、五個新 parse 欄位、CTX 測試、README 與 CLAUDE.md 的 context meter 敘述、截圖重產；out of scope 為 degrade ladder、token 段、rate 段、auto-compact 偵測、remaining 顯示形態、紅門檻數值重校。

## Risks / Trade-offs

- [CC 未來版本改動 20000 常數或警示公式] → 常數單點集中＋來源註解記載重驗方法（對 binary 以字串搜尋比對），README troubleshooting 註明對齊基準版本 2.1.232。
- [auto-compact 開啟的 session 對「until auto-compact」指示仍有 13k 樂觀差] → 已列 Non-Goals，README 註明此限制。
- [1M 模型邊緣紅色比改動前早約 2 個百分點觸發] → 方向保守（更早警告），視為 intended，spec 範例同步更新。
- [五個新 positional 欄位加大 parse_input 契約面] → 附 positional 對齊測試（既有 V 節 sentinel 機制天然covers 錯位），一次附加減少後續再動。

## Migration Plan

單一 repo 內腳本改動，無部署面。回滾以 git 還原該 commit 即可；fallback 設計保證舊版 CC 使用者無感。

## Open Questions

- 紅門檻 80 與 92 是否維持數值不變（建議: 維持，理由見 Risks 第三條）。使用者於決策點 A 裁決。
- CTX_RESERVE 是否僅為頂部常數附註解、不進 README knob 表（建議: 是）。使用者於決策點 A 裁決。
