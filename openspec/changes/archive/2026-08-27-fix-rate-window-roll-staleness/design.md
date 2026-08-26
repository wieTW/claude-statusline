# Design — fix-rate-window-roll-staleness

## 根因（實測定案，非推測）

`_reconcile_core` 的權威 map 以 `resets_at` 精確值為 key（`Wval[r5]` 查找、`applywin` 寫入、emission `Wval[r5]""`）。視窗 roll 後：

1. roll 前開的 session，其凍結 `five_reset`/`seven_reset` 指向已過期的舊視窗。
2. 舊視窗的 W/P 行在下一次 rewrite 被 prune（`resets_at <= now`）。
3. 該 session 的 key 從此對不上任何 live W 行 → emission 為空 → `reconcile_read` guard 回落到 frame 自己的凍結值。
4. render 端 `ttl()` 對過期 `resets_at` 輸出 `0m`。

重現（fake HOME，cache 種入 live 權威 5h=3%/7d=24%）: key 對得上時顯示 `2H30m 97%`；key 過期時顯示 `0m 13%`（凍結 used=87 的 remaining）。

## 關鍵決策

### 1. 類別顯式標籤（W5/W7），不用 heuristic 推類

替代方案「以 `key - now <= 18000` 判定 5h 類」被否決: 7d 視窗臨近 reset 的最後 5 小時，`key - now` 也 < 18000，會被誤判成 5h 類並互相污染。顯式標籤零歧義，成本是 cache 格式 bump 一次。

### 2. per-class 單一權威記錄，不保留多 key 並存

現實中每類別同時最多一個活視窗；「同類多 key 並存」只可能來自 roll 斷鏈（本 bug）、upstream jitter、或垃圾資料——三者都該由 newest-session 收斂成單條。舊 spec 的「distinct windows 並存」scenario 實際上把病灶合法化了，本 change 予以取代。

### 3. emission 加 effective resets_at（5 欄）

只修 used% 不修倒數，凍結 session 仍會永遠顯示 `0m`。權威記錄本來就帶著自己的 key，一起 emit、一起採納，`build_rate` 的倒數自然修正。`reconcile_read` 對 eff key 用 all-digits guard（epoch 整數），guard 不過就保留 frame 自己的 resets_at——與 used% guard 同一套安全退化。

### 4. key sanity bound = now + 691200（8d）

依據: 最長視窗 7d = 604800s，加 86400s margin 容忍時鐘偏移與 upstream 邊界抖動。現場 cache 的 `W 9999999999 28 1782492124`（2026-06-27 寫入）證明缺上限的 key 會不朽。載入與採納兩側都套用。

### 5. keys 一律以字串保存、比較時才 `+0`

awk 對非整數值的 number→string 轉換走 CONVFMT（`%.6g`），epoch 級數字一旦帶小數就會被印成科學記號寫壞 cache。key 保持字串（不 `+0` 存放）、數值比較時顯式 `+0`，杜絕這一族問題。

### 6. P 行格式不變，取樣 key 改 effective key

P 行天然只屬 5h 類（只有 5h 被取樣），不需類別標籤。取樣與 slope 改用 effective key 後：snapshot 活著時 key 相同、行為不變；凍結 frame 也能繼續為 live 視窗貢獻樣本（修前它根本取不了樣）。

## 遷移與混版

- 新版讀舊 cache: 舊 `W` 行（NF==4、tag `W`）不再被識別 → 按既有「old-format 靜默淘汰」requirement 於首次 writable rewrite 清除（`9999999999` 垃圾行一併死亡）。權威值短暫重建自當下各 frame 的 report，一個視窗週期內收斂。
- 舊版讀新 cache: `W5/W7` tag 不被舊 parser 識別 → 舊 session 退化為只信自己的凍結值（等同修前行為）。
- 混跑期間新舊互 drop 對方的 W 行——sync 雙向失效但無 crash、無毀損；舊版 session 全部結束後自癒。

## 殘餘限制（有意為之）

roll 之後、任何新 session 出現之前，凍結 session 顯示不變（自己的凍結值＋`0m`）: upstream 沒有任何來源知道新視窗的 used% 與 resets_at，顯示「未知」的改動屬 rate-limit-display 範疇且收益低（使用者一開新 session 即自癒）。明寫進 spec 作為 fallback scenario。
