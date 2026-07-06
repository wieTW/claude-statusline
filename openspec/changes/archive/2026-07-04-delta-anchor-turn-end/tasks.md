## 1. collect.sh 產出最後活動時刻

- [x] 1.1 依「決策：以 transcript mtime 作為「turn 結束」的時刻來源」，在 lib/collect.sh 主流程用 `stat -f %m "$transcript_path"`（guard transcript_path 非空且檔案存在，失敗留空）計算最後活動時刻並寫入新的 act_epoch global。行為：有 transcript 時 act_epoch 等於該檔 mtime，否則為空。驗證：`bash -n lib/collect.sh` 通過，並以一個含 transcript_path 的 fixture frame 手動執行 statusline 觀察 act_epoch 反映該檔 mtime。
- [x] 1.2 依「決策：collect→render 契約新增 act_epoch global」，在 lib/collect.sh 的 `WRITES:` header 與 lib/render.sh 的 `READS:` header 增列 act_epoch，維持 collect→render 全域變數契約同步。行為：兩份 header 皆列出 act_epoch。驗證：檢視兩檔 header 含 act_epoch；`shellcheck -x statusline-command.sh` 無新增告警。

## 2. render.sh 把 Δ 年齡改錨到最後活動時刻

- [x] 2.1 依「Last-message timestamp with cache-freshness-colored delta」與「決策：只有 Δ 的年齡改錨，clock 主文字與跨日仍用 lm_epoch」，在 lib/render.sh 的 build_left 內以 delta_epoch（act_epoch 為有效整數時取之，否則 lm_epoch）計算 `lm_age = now - delta_epoch`，保留既有 `[ -n "$lm_epoch" ]` delta gate、三層顏色門檻、不到 60 秒隱藏、負值 clamp，且 clock 主文字與跨日比較仍用 lm_epoch。行為：長 turn 剛結束時 Δ 顯示小的 idle 而非 turn 時長。驗證：4.1 的 U 區塊 regression 通過。
- [x] 2.2 依「決策：transcript 不可用時回退 lm_epoch」，確保 act_epoch 為空或非數字時 delta_epoch 退回 lm_epoch。行為：無 transcript 的 frame 與修改前輸出完全相同。驗證：tests/run-tests.sh 的 U/DUR/API 區塊中未提供 transcript 的既有 frame 全數維持綠燈。

## 3. Cross-day 語意一致性

- [x] 3.1 依「Cross-day timestamps include the date」與「決策：跨日前綴維持既有 delta-shown gate（接受 legacy 邊界）」，確認 clock-fallback 的跨日日期前綴仍以 lm_epoch 的本地日曆日比較、並維持在 delta-shown（現為 idle-based `lm_age >= 60s`）gate 內，不因 Δ 改錨而改動 clock 或跨日語意。行為：跨日 prompt 的 clock 仍得到 `MM-DD` 前綴。驗證：tests/run-tests.sh 的 U 區塊跨日案例全綠。

## 4. 測試與文件

- [x] 4.1 [P] 在 tests/run-tests.sh 的 U 區塊新增可證偽 regression：一個 frame 設 lm_epoch 為 7800 秒前（prompt）、transcript mtime 為 90 秒前（turn 剛結束），斷言 Δ 為 dim `(1m)`。行為：把改動 revert（Δ 改回以 lm_epoch 計）後該案例斷言變成紅 `(2H10m)` 而失敗（可證偽）。驗證：`bash tests/run-tests.sh` 印出 `ALL CHECKS PASSED`，並手動暫時 revert 確認該案例失敗。
- [x] 4.2 [P] 更新 CLAUDE.md 的「Session duration + last-message age」段落，說明 Δ 改為 idle-since-turn-end、來源為 transcript mtime（act_epoch）、transcript 不可用時回退 lm_epoch、clock 與跨日仍用 lm_epoch。行為：文件不再把 Δ 描述為「距上次 user prompt 多久」。驗證：內容檢視與實作一致，無殘留舊描述。
