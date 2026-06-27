## 1. 實作三個守衛

- [x] 1.1 實作 Requirement: Cache overwrite requires a successfully produced temp file。在 `lib/collect.sh` 的 `_reconcile_core` 中,於覆寫共享快取的 `mv -f "$tmpfile" "$cache"` 前加入非空守衛(`[ -s "$tmpfile" ]`):awk 失敗或只寫出空/半截暫存檔時跳過 `mv`、保留磁碟上既有快取,並照常 `rm` 暫存檔與釋放鎖。**行為**:awk 不成功的 frame 不再清空跨 session 權威快取。**驗證**:`bash -n lib/collect.sh` 通過,且 T2 斷言(任務 2.1)顯示快取內容於模擬 awk 失敗後維持不變。
- [x] 1.2 實作 Requirement: Minimum sampling interval gate for slope projection。在 `lib/collect.sh` `_reconcile_core` 的 awk burn 區塊,把 slope 投影條件由 `if (dp>0)` 收緊為 `if (dp>0 && dt>=60)`(精確 60、inclusive)。**行為**:兩取樣點實際間隔小於 60 秒時不投影、不輸出 `burn_tte`、不顯示 `↘` 警報;間隔大於等於 60 秒且既有閘通過時行為不變。**驗證**:Y 斷言(任務 2.2)顯示 2 秒爆發無警報、dt=60 仍警報;既有 Y 矩陣(含 Y4 row 6)維持綠燈。
- [x] 1.3 [P] 實作 Requirement: Registry retention TTL is clamped to a hard floor。在 `statusline-command.sh` config 區塊之後,加入 `RL_REG_TTL` 載入時 clamp:非數值或空值歸 `604800`,數值小於 `604800` 一律提升為 `604800`,大於者保留原值。**行為**:此 knob 永遠不低於最長 reset 視窗,凍結舊 session 的 registry 記錄不會因設定過小而被剪除。**驗證**:`bash -n statusline-command.sh` 通過,且 T 斷言(任務 2.3)顯示 undersized 與非數值輸入皆生效為 604800。

## 2. 回歸測試(皆寫入 `tests/run-tests.sh`,依序避免同檔衝突)

- [x] 2.1 為 Requirement: Cache overwrite requires a successfully produced temp file 在 T / T2 速率同步段新增斷言:給定快取已有有效權威行,模擬 awk 產出空暫存檔的 frame 後,斷言快取檔內容(W/S/P 行)維持不變且該 frame 仍顯示其讀到的值。**驗證**:`bash tests/run-tests.sh` 該斷言印出 OK,無 `★ FAIL`。
- [x] 2.2 為 Requirement: Minimum sampling interval gate for slope projection 在 Y 燃燒投影段新增兩條斷言:(a) 兩取樣點間隔 2 秒、used% 由 40 跳到 70 → 不顯示 `↘`;(b) 間隔正好 60 秒且投影於 reset 前耗盡 → 顯示 `↘`(紅)。**驗證**:`bash tests/run-tests.sh` 兩斷言印出 OK,且既有 Y/Y4 案例不變。
- [x] 2.3 為 Requirement: Registry retention TTL is clamped to a hard floor 在 T 速率同步段新增斷言:`RL_REG_TTL=3600`(及一個非數值輸入)時,一個 first_seen 為 5 小時前、仍存活的 session 其 registry 記錄不被剪除、不被當成新 session 搶權威。**驗證**:`bash tests/run-tests.sh` 該斷言印出 OK,無 `★ FAIL`。

## 3. 驗證 gate

- [x] 3.1 執行完整驗證 gate 並全綠:`bash -n statusline-command.sh && bash -n lib/collect.sh && bash -n lib/render.sh`、`shellcheck -x statusline-command.sh`、`bash tests/run-tests.sh`。**驗證**:三命令皆 exit 0,測試套件末行印出 `ALL CHECKS PASSED`,無 `★ FAIL`。
