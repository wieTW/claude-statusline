# Fix: rate-limit 視窗 roll 後凍結 session 永久顯示過期值

## Why

實驗證實（最小重現，2026-08-01）: 5h/7d 視窗一 roll，roll 之前開的每個 session 的凍結 `resets_at` 就永遠對不上新視窗的 cache key——`_reconcile_core` 的權威值查找用 `resets_at` 精確配對（`Wval[r5]`），key 不合 → adoption 永久失效 → 顯示回落到該 session 凍結的舊視窗 used%，倒數卡死在 `0m`。重現輸出: 真實狀態 `2H30m 97%`，凍結 session 顯示 `0m 13%`。

使用者症狀完全吻合: 「經常在比較低的使用率時候，五小時、週限時的顯示都會不準確」——低使用率正是剛 reset 完的時段，此時所有 roll 前的 session 都顯示舊視窗的高 used%。5h 視窗每 5 小時 roll 一次，long-lived session 幾乎必中；7d 視窗每週 roll 時全部 session 同時中招。

另一個現場證據: 真實 cache 存在 `W 9999999999 28 1782492124` 不朽垃圾行（key 永不過期、2026-06-27 寫入至今），W 行 key 缺上限 sanity bound。

## What Changes

- **W 行改帶視窗類別標籤、每類別單一權威**: `W <resets_at> <used> <fs>` → `W5|W7 <resets_at> <used> <fs>`。現實中每類別（5h/7d）同時只有一個活視窗；舊格式允許同類多 key 並存，正是 roll 斷鏈根源。newest-or-equal 規則不變，但改為 class-scoped：更新的 session 報告會連 key 一起換掉該類別的權威記錄。
- **凍結 session 採納 live 權威（值＋resets_at 一起）**: 本 frame 自己的 key 過期時，改採 cache 中該類別的 live authority——used% 與 resets_at 同時採納，倒數因此一併修正（不再永遠 `0m`）。
- **emission 由 3 欄改 5 欄**: `<five>|<seven>|<burn_tte>` → `<five>|<eff5>|<seven>|<eff7>|<burn_tte>`；`reconcile_read` 對 eff key 加純數字 guard 後覆寫 `five_reset`/`seven_reset`。
- **視窗 key sanity bound**: key 必須 `< now + 691200`（8d = 最長 7d 視窗 604800 + 86400 skew margin）才被載入/採納，`9999999999` 型不朽鍵從此進不了 cache；現存垃圾行藉舊格式淘汰一併清除。
- **P 行格式不變**，但取樣與 slope 改 keyed by effective 5h key（採納後的權威 key；snapshot 活著時等同原本的 r5）。
- **殘餘限制（明寫進 spec）**: roll 後若沒有任何新 session 提供新視窗 authority，凍結 frame 維持舊行為（顯示自己凍結值＋`0m`）——upstream 資料不存在，無從補。
- **混版過渡**: 舊版 code drop `W5/W7`、新版 drop 舊 `W`——混跑期間雙向退化為各自凍結值（等同修前行為），舊 session 結束後自癒；無 crash、無資料毀損路徑。

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `rate-limit-sync`: W 行類別標籤化與 per-class 單一權威；window-roll 後採納 live 權威（值＋resets_at）；emission 5 欄；key sanity bound；legacy `W` 行列入 old-format 淘汰。
- `rate-burn-projection`: P 取樣與 slope 的 key 由「本 frame 的 r5」改為「reconciled effective 5h key」（snapshot 活著時兩者相同，行為不變）。

（`rate-limit-display` 不動: `0m` 倒數與 remaining% 的渲染規則不變，變的是餵進去的值。）

## Impact

- Affected specs: rate-limit-sync, rate-burn-projection
- Affected code:
  - Modified: lib/collect.sh, tests/run-tests.sh, CLAUDE.md, AGENTS.md
  - New: (none)
  - Removed: (none)
