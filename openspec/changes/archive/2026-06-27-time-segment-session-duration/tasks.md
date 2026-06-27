## 1. 資料接入：解析 session 時長

- [x] 1.1 在 `lib/collect.sh` 的 `parse_input` jq pass 解析 `cost.total_duration_ms` 為新 global `dur_ms`，作為 positional 欄位第 16（`now` 順移第 17），並同步 WRITES header。完成時：每個解析欄位都落在自己的 global，無錯位。驗證：`bash tests/run-tests.sh` 的 V 段印出「all 17 fields land in their own global OK」（含 `dur_ms` 哨兵）。

## 2. 渲染：時間段與 model 顯示

- [x] 2.1 在 `lib/render.sh` 的 `build_left` 改寫時間段，落實 "Last-message timestamp with cache-freshness-colored delta"：主文字改為 `fmt_dur(dur_ms/1000)` 的 session 時長並取代絕對時鐘，保留 `(Δ)` 與其快取新鮮度配色、age<60s 隱藏 Δ、負值夾 0；`dur_ms` 缺值或非數值時 fallback 回 `HH:MM` 時鐘。同時落實 "Cross-day timestamps include the date" 改為僅作用於時鐘 fallback（時長主文字不加日期前綴）。驗證：`bash tests/run-tests.sh` 的 DUR1–DUR5 全綠，且 U 段（時鐘 fallback 行為）維持不變。
- [x] 2.2 在 `lib/render.sh` 將 model 全形代換由 `${model/ (1M context)/ (1M)}` 改為 `${model/ (1M context)/(1M)}`，使顯示為 `Opus 4.8(1M)`（去掉括號前空格）；compact 形式（首字 `Opus`）與 1M 偵測讀未代換的 `model` 不受影響。驗證：A2（content order）與 Z2（per-segment compact）斷言 `Opus 4.8(1M)` 通過。

## 3. 文件同步

- [x] 3.1 [P] 更新 `CLAUDE.md`：概覽行左段清單與「時間段」章節改寫為 session 時長為主、時鐘 fallback、跨日前綴僅限 fallback 的新行為。完成時：文件描述與 `lib/render.sh` 實際行為一致。驗證：人工複查該章節無殘留「顯示 HH:MM 時鐘」的舊描述，且新增 `DUR` 段交叉引用正確。

## 4. 驗證 gate

- [x] 4.1 在 `tests/run-tests.sh` 新增 `DUR` 測試段（時長取代時鐘、<1min 隱藏 Δ、無 last-msg 仍顯示、`fmt_dur` 邊界 `40m`/`2D3H`、無 `cost` 時 fallback），並把 V 哨兵擴為 17 欄位含 `dur_ms`、更新 A2/Z2 的 model 斷言。完成時：新行為皆有測項覆蓋。驗證：`bash tests/run-tests.sh` 末行印「ALL CHECKS PASSED」。
- [x] 4.2 跑完整 gate 確認三道命令皆 exit 0。驗證：`bash -n statusline-command.sh && bash -n lib/collect.sh && bash -n lib/render.sh`、`shellcheck -x statusline-command.sh`、`bash tests/run-tests.sh` 全部 exit 0。
