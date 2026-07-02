## 1. 解析新欄位 api_ms（lib/collect.sh）

- [x] 1.1 在 `parse_input` 的 jq 陣列插入 `.cost.total_api_duration_ms // ""` 作為第 17 個元素、`(now | floor)` 順移為第 18，並在 positional read 區塊對應插入 `IFS= read -r api_ms`（第 17）、`now` 順移為第 18；兩側 `# NN` 註解編號同步，`now` 保持最後一位。驗證：`bash -n lib/collect.sh` 通過，且 tests/run-tests.sh 的 V sentinel 段（見 3.1）證明 18 個欄位各自落入正確 global。
- [x] 1.2 在 collect.sh 檔頭 WRITES header 的欄位清單於 `dur_ms` 之後、`now` 之前加入 `api_ms`，使 collect→render 的 global 契約完整登記。驗證：`shellcheck -x statusline-command.sh` 無 SC2034/新警告，且 grep 確認 `api_ms` 出現在 WRITES 清單。

## 2. 主體三層鏈與秒級 formatter（lib/render.sh）

- [x] 2.1 新增 `fmt_dur_s` helper（緊接既有 `fmt_dur` 之後，不修改 `fmt_dur`）：輸入非負整數秒，<60 輸出 `<s>s`（含 `0s`）、≥60 且 <3600 輸出 `<m>m<s>s`、≥3600 委派 `fmt_dur`，結果寫入 `_dur` global。驗證：手動以 0/45/60/225/3599/4500/97200 秒呼叫，輸出對應 `0s`/`45s`/`1m0s`/`3m45s`/`59m59s`/`1H15m`/`1D3H`（由 3.2 的 API2 測項覆蓋）。
- [x] 2.2 實作規格 `Last-message timestamp with cache-freshness-colored delta`：將 `build_left` 時間段主體改為三層 fallback 鏈：先判 `[ -n "$api_ms" ] && [ "$api_ms" -gt 0 ] 2>/dev/null` → `fmt_dur_s "$(( api_ms / 1000 ))"`；否則沿用既有 `dur_ms` → `fmt_dur` 分支；結果同樣寫入 `dur_str`，使下游段落 gate（`[ -n "$last_msg" ] || [ -n "$dur_str" ]`）、`(Δ)` 邏輯、時鐘 fallback gate（`[ -z "$lm_primary" ]`）零改動。驗證：3.2 的 API1（api 取代 dur 與時鐘）、API3（api 有 dur 無）、API4（api 無效降級 dur）、API5（兩者皆無降級時鐘）全數通過。
- [x] 2.3 滿足規格 `Cross-day timestamps include the date` 與 `Time segment omitted when no timestamp inputs are available` 的既有行為在新三層鏈下不回歸：確認 api primary 為 elapsed span 不加日期前綴、cross-day 前綴仍只作用於時鐘 fallback（觸發條件為兩 cost 欄位皆不可用）、且段落 gate 在兩輸入皆缺時仍省略時間段；改寫時間段周邊註解（primary 三層鏈敘述、cross-day 理由段的 fallback 觸發條件措辭）不殘留「總時長為唯一 primary」的過時描述。驗證：3.2 的 API5/API6 + 既有 U/DUR/Z 段（見 3.3）不回歸 + `bash -n lib/render.sh` 通過。

## 3. 測試（tests/run-tests.sh）

- [x] 3.1 擴充 V sentinel 段：`VFEED` 的 cost 物件加入 `total_api_duration_ms:987654`，新增 `chkv api_ms "$api_ms" 987654`，並將收尾字串 `all 17 fields` 改為 `all 18 fields`。驗證：`bash tests/run-tests.sh` 的 V 段通過，證明新欄位不破壞 positional 對齊。
- [x] 3.2 新增 `API` 測試段（置於 DUR 段還原 last-msg 之後、W 段之前），helper `mkapi()` 吃整個 cost 物件；涵蓋 API1（api+dur+Δ600 → `3m45s (10m)`，且不得出現 `1H15m`/`09:30`）、API2（`fmt_dur_s` 邊界表 `45s`/`1m0s`/`59m59s`/`1H15m`/`1D3H`，並 pin `45s` 無分鐘前綴）、API3（api 有 dur 無 → `3m45s`）、API4（api=0/`"abc"`/`-5000` + dur 有效 → `1H15m`）、API5（cost 存在但兩者不可用 + last-msg 600s → `09:30 (10m)`）、API6（last-msg 30s → Δ 隱藏只剩 `3m45s`）；Δ 採容差慣例；段尾還原 baseline last-msg。驗證：`bash tests/run-tests.sh` 印出 `ALL CHECKS PASSED` 且 API 段無 `★ FAIL`。
- [x] 3.3 確認既有段落不回歸：U（無 cost）、DUR1–DUR5（`mkdur` 只餵 `total_duration_ms`）、Z1–Z5（`JZ` 無 cost 物件、時鐘 fallback、寬度不變）維持通過。驗證：完整 `bash tests/run-tests.sh` 綠燈，U/DUR/Z 段無 `★ FAIL`。

## 4. 文件與驗證 gate

- [x] 4.1 更新 CLAUDE.md：左半地圖描述將 API thinking time 標為時間段第一優先，「Session duration + last-message age」節首段改寫為三層 primary 鏈（api 語意：累計等 API 回應、排除閒置與本地 tool 執行；`fmt_dur_s` 格式），並補記新增的 `API` 測試段。驗證：內容審查，描述與 lib/render.sh 實作一致。
- [x] 4.2 跑完整驗證 gate 並寫 `.claude/verify.json`：`bash -n` ×3 + `shellcheck -x statusline-command.sh` + `bash tests/run-tests.sh` 三者全綠；手動 smoke（COLUMNS=140，cost 含 total_api_duration_ms=225000）確認時間段顯示 dim 的 `3m45s` 而非 `1H15m`。驗證：三命令 exit 0、smoke 輸出符合預期。
