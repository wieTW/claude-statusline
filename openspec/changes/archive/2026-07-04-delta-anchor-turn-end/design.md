## Context

statusline 時間段（`build_left` 的 time segment）在主文字後面接一個括號 `(Δ)`。目前 `(Δ)` 的年齡是 `lm_age = now − lm_epoch`，`lm_epoch` 來自 per-session 的 last-message 檔（由 UserPromptSubmit hook 寫入 prompt 送出時刻）。`(Δ)` 的數字與其 dim/yellow/red 三層顏色是 prompt-cache 新鮮度信號。問題在於：prompt cache 的 5 分鐘 / 1 小時 TTL 是「從最後一次 request 起算」的滑動窗，最後一次刷新約在 turn 結束；把 Δ 錨在 prompt-submit，會把 Claude 回應那一段耗時也算進 idle，使長 turn 剛做完時 Δ 直接接近 turn 時長並亮紅，與 cache 實際狀態相反。

既有硬規則必須遵守：不得 `set -e`；背景 job 一律 `</dev/null`；`parse_input` 的 `read` 順序對應 jq 陣列位置；目標 bash 3.2；collect.sh 的 `WRITES:` 與 render.sh 的 `READS:` header 是 collect→render 的全域變數契約。

## Goals / Non-Goals

**Goals:**

- 把 `(Δ)` 的語意由「距上次 prompt 多久」改為「距 turn 結束的 idle」，讓數字與顏色門檻對齊真實 cache 壽命。
- 只改 Δ 的年齡錨點；顯示規則、顏色門檻、clock-fallback 主文字與跨日前綴的既有行為維持不變（最小改動）。
- 不新增任何 hook。

**Non-Goals:**

- 不採用選項 A（cache 熱時隱藏 Δ）與 (a)（數字顯示 cold-time = idle − 門檻）；本次採 B + b（一律顯示、數字為真實 idle）。
- 不改顏色門檻數值（`LASTMSG_WARN` / `LASTMSG_STALE`）、不改不到 60 秒隱藏、不改負值 clamp。
- 不重寫 clock-fallback 主文字或跨日語意；不裝 Stop hook。

## Decisions

### 決策：以 transcript mtime 作為「turn 結束」的時刻來源

turn 進行中 transcript 持續被 append，idle 時停止寫入，因此檔案 mtime 天然等於「最後一次活動」的時刻，約等於最後一次 request（cache 最後刷新）。沿用既有的 `transcript_path` global，用 BSD `stat -f %m`（collect.sh 已在 token 簽章 `stat -f '%z %m'` 用同一 idiom）取 mtime，零新 hook，成本是一次本地 stat。

替代方案：Stop hook 寫 epoch（鏡像 `session-time.sh`）較精準，但要動 `settings.json`（全域禁區、需使用者核准），使用者已否決。維持 UserPromptSubmit 時刻即現況，語意錯，正是要修的對象。

前提：實作前必須實測 idle 期間 transcript mtime 確實凍結（沒有其他背景寫入 bump 它）；這是機制成立與否的唯一未知。

### 決策：只有 Δ 的年齡改錨，clock 主文字與跨日仍用 lm_epoch

Δ 年齡改為 `lm_age = now − delta_epoch`，其中 `delta_epoch` 取 `act_epoch`（有效整數）否則 `lm_epoch`。clock-fallback 的主文字（`HH:MM`）與跨日日曆日比較仍用 `lm_epoch`——那是「你上次 prompt 的牆鐘」，語意正確、不該動。保留既有 delta gate `[ -n "$lm_epoch" ]`：沒有 last-message 檔就不顯示 Δ（維持現有「no last-message file → no Δ」scenario 不變），僅在檔案存在時把年齡改錨。這讓主文字（牆鐘）與 Δ（idle）各自表達正確的量。

### 決策：transcript 不可用時回退 lm_epoch

`act_epoch` 為空或非數字（無 `transcript_path`、檔案不存在、`stat` 失敗）時，`delta_epoch` 退回 `lm_epoch`，行為完全等同修改前。這是向後相容保證：未提供 transcript 的既有測試 frame 與舊 CC 環境不受影響。

### 決策：跨日前綴維持既有 delta-shown gate（接受 legacy 邊界）

跨日日期前綴仍位於 `[ -n "$lm_delta" ]`（Δ 有顯示）區塊內、以 `lm_epoch` 的本地日曆日比較。因 Δ gate 現在改由 idle（`lm_age >= 60`）決定，理論上「legacy clock-fallback ＋ turn 跨午夜 ＋ idle < 60 秒」會漏掉日期前綴。此情況三重罕見（僅舊 CC 無 cost 欄位、turn 跨午夜、且渲染在 turn 結束 60 秒內），列為已知限制，不在本次範圍。

### 決策：collect→render 契約新增 act_epoch global

collect.sh 的 `WRITES:` header 增列 `act_epoch`，render.sh 的 `READS:` header 對應增列。`act_epoch` 由 collect.sh 在主流程（非背景 job）從 `stat -f %m "$transcript_path"` 計算，guard `transcript_path` 非空且檔案存在，失敗留空。mtime 是便宜的本地 stat，不需背景 job，也不觸 stdin。

## Implementation Contract

- **Behavior**：`(Δ)` 顯示「距 turn 結束的 idle」。長 turn 剛結束時 Δ 接近 0 並為 dim，不再顯示接近 turn 時長的紅色。三層顏色（dim / yellow / red 依 `LASTMSG_WARN` / `LASTMSG_STALE`）、不到 60 秒隱藏、負值 clamp 為 0、clock-fallback 與跨日行為，在對應輸入下維持不變。
- **Interface / data shape**：新增全域字串 `act_epoch`（整數 epoch 秒，或空字串）。collect.sh 寫入，render.sh `build_left` 讀取。來源 `stat -f %m "$transcript_path"`。render.sh 內 `delta_epoch = act_epoch（有效數字時）否則 lm_epoch`，`lm_age = now − delta_epoch`。
- **Failure modes**：`transcript_path` 缺失或 `stat` 失敗 → `act_epoch` 空 → 回退 `lm_epoch`（舊行為）。永不 `set -e`；所有既有 fallback 路徑（duration primary、clock fallback、legacy 檔格式、omit 空段）不變。
- **Acceptance criteria**：
  - 新增可證偽 regression（在 `tests/run-tests.sh` 的 `U` 區塊或新增子區塊）：一個 frame 設 `lm_epoch` 為很久以前（prompt）、transcript mtime 為近期（turn 剛結束），斷言 Δ 為小的 idle 值且為 dim；把改動 revert（Δ 改回用 `lm_epoch`）後，該斷言變成大的紅色 Δ，測試失敗。
  - 既有 `U` / `DUR` / `API` 區塊中未提供 transcript 的 frame 全數維持綠燈（靠 `act_epoch` 空即回退）。
  - 三道 gate 全綠：`bash -n statusline-command.sh lib/collect.sh lib/render.sh`、`shellcheck -x statusline-command.sh`、`bash tests/run-tests.sh` 印出 `ALL CHECKS PASSED`。
- **Scope in**：Δ 年齡錨點、`act_epoch` global 與 collect/render header、對應測試、CLAUDE.md 時間段說明、last-message-age spec delta。
- **Scope out**：選項 A 的隱藏行為、(a) 的 cold-time 數字、顏色門檻數值、Stop hook、clock 主文字與跨日語意的重寫。

## Risks / Trade-offs

- [idle 期間 transcript mtime 被非預期寫入 bump，使 idle 一直歸零] → 實作前實測：觀察閒置數分鐘 mtime 不動再繼續；若被 bump 則此機制不成立，停下改用替代方案（transcript 最後一列的 timestamp，或改裝 Stop hook 並先問使用者）。
- [既有測試耦合 lm_epoch 年齡而變紅] → 由「`act_epoch` 空即回退 `lm_epoch`」保證未設 transcript 的 frame 不變；逐一確認 `U` / `DUR` / `API` 綠燈，必要時為新錨點更新的測試明確設定 transcript mtime。
- [legacy 跨日邊界漏日期前綴] → 已知限制，罕見且僅 legacy 路徑，不修（見上方決策）。

## Migration Plan

純顯示行為修正，無資料遷移。部署即生效於下一幀；rollback 為 revert 該 commit。
