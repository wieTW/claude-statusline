# Design: fix-authority-freshest-observation

## Context

現行規則（`lib/collect.sh:362-365` 的 `applycls`，以及 `lib/collect.sh:374-378` 的 W 行載入）用 `first_seen` 排序決定誰是權威: `if (!(c in Rv) || myfs+0 >= Rf[c]+0)`。權威記錄持久化在 `~/.claude/sl-ratelimit-cache` 的 `W5`/`W7` 行第 4 欄（`auth_first_seen`），session 註冊在 `S <session_id> <first_seen>` 行（`lib/collect.sh:367-371` 載入、`lib/collect.sh:397` 寫回）。

這條規則假設「最新開的 session 看到的值最接近真值」。2026-08-27 實測推翻了它賴以成立的前提: 一個 session 在持有權威的 44 分鐘內，cache 的 W5 由 14 變 20、W7 由 85 變 86，代表 Claude Code 在每次 API round trip 都會刷新該 session 的 `rate_limits`。既然 session 的值會跟著自己的使用更新，「新」就不再等於「準」: 最後開的那個 session 只要閒置，它的值就停在最後一次 round trip，而規則又不准比它舊的活躍 session 覆蓋，顯示因此被凍住（實測 19% vs 真值 15%）。

`commit b971f4b` 記錄過另一個被否決的方案「每個 window 取 max used%」: cap 調高時 used% 會下降，max 會黏在過期的高點。新規則必須維持「下降也採納」這一點。

## Goals / Non-Goals

**Goals:**

- 權威改由最新觀測持有: 任何 session 只要觀測到新的 `(resets_at, used%)`，就能取得該 class 的權威，與它的 `first_seen` 無關。
- 採納在兩個方向與 window roll 上都成立: 上升、cap 調高後的下降、`resets_at` 換新。
- cache 格式的過渡不需要 migration 步驟，舊行第一輪 reconcile 就自然收斂。
- 既有的 lock 序列化、安全降級、唯讀路徑、TTL 下限、post-roll 採納行為一律保留。

**Non-Goals:**

- 不動 rendering（`lib/render.sh` 的 `remaining% = 100 - used%` 與 D/H 倒數）、`statusline-command.sh` 與顯示格式。
- 不改 burn projection 的取樣規則、`P` 行格式、slope 與兩道 gate。
- 不改 lock 機制（mkdir spin-lock、stale steal、bounded retry）與 `RL_SYNC` 開關語意。
- 不新增第二條 sanitization 路徑，`parse_input` 仍是唯一入口。
- 不做「值不變也定期刷新 observed_at」的心跳機制（見 Risks 的取捨說明）。

## Decisions

### pair 改變才更新 observed_at

新鮮度訊號取「本 frame 回報的 `(resets_at, used%)` 與自己上一 frame 回報的那組是否不同」: 不同代表這個 session 剛從 upstream 拿到新資料，`observed_at = now`；相同則沿用原本的 `observed_at`，不因為又 render 了一次就變新。

考慮過但不採用的替代訊號: 用 stdin `cost.*` 欄位的成長判斷 session 是否活躍。否決理由是它量的是「這個 session 有沒有在花錢」，不是「這個 session 的 rate-limit 讀數有沒有更新」，兩者在 cap 調高、其他 session 消耗額度等情境下會脫鉤，等於再引入一個需要各自驗證的代理訊號。pair 改變則直接就是被觀測到的事實。

### observed_at 放在 S 行、每個 class 一組

`observed_at` 是「某個 session 對某個 class 的觀測時間」，屬於 session 狀態而不是權威狀態，所以存回該 session 自己的 registry 行。`S` 行由 3 欄擴為 9 欄: `S <session_id> <first_seen> <r5> <u5> <o5> <r7> <u7> <o7>`，沒回報過的 class 三欄一律填 `-`。放同一行的理由是 awk 已經逐行掃這個檔，session 狀態集中一行可以在既有的單趟 pass 內讀寫完，不必新增第二種行型與第二次配對查找。

### W 行第四欄語意改為 auth_observed_at

`W5`/`W7` 的第 4 欄由 `auth_first_seen` 改為 `auth_observed_at`，欄位型別不變（epoch 秒），因此舊行不需要轉檔就能參與比較: 舊值是某個 session 的 `first_seen`，必然小於等於現在，任何一個觀測到變化的 session 都能在第一輪 reconcile 蓋掉它。不另設 schema 版本欄或 migration pass，是因為這個 cache 本來就是可重建的衍生資料，最壞情況只是多等一個 frame。

### 採納比較用 >=，同秒由後寫者勝

`applycls` 的條件由 `myfs+0 >= Rf[c]+0` 換成 `myobs+0 >= Rf[c]+0`（`Rf` 改存 `auth_observed_at`），比較運算子維持 `>=`。維持 `>=` 是刻意的: 秒級時間戳同秒平手時，後寫入者勝，與今天的行為一致（lock 序列化已保證兩個寫者不會交錯）。改成 `>` 會讓同秒的新觀測被丟掉，且沒有任何正確性上的好處。

### 舊格式 S 行視為沒有前次 pair

3 欄的舊 `S` 行不被當成 malformed 丟掉（丟掉會連 `first_seen` 一起消失，讓該 session 下一 frame 以 `first_seen = now` 重新註冊，反而拿到最新的 `observed_at`）: 它被接受並就地升級成 9 欄，缺的欄位視為「沒有前次 pair」。第一次回報因此 `observed_at = first_seen`，舊 session 在升級當下不會奪權；等它真的觀測到變化，才以 `now` 取得權威。

## Implementation Contract

**Behavior**: 每個 class 的顯示值來自「最後一次被觀測到變化的回報」。一個閒置 session 留下的值，會在另一個 session 觀測到不同的 `(resets_at, used%)` 的那一個 frame 被取代，不論兩者誰先開始。使用者可觀察到的結果是 5h/7d 兩段的百分比與 `/usage` 一致，而非落後於它。

**Interface / data shape**:

- 共用 cache（`~/.claude/sl-ratelimit-cache`）的 session registry 行為 9 欄: session id、first_seen，接著 five-hour 的 `(resets_at, used%, observed_at)`，再接 seven-day 的同三欄；沒回報過的 class 三欄填 `-`。3 欄舊行仍可讀，視為兩個 class 都沒有前次 pair。
- 權威行仍是每個 class 一筆，四欄，第 4 欄改為該筆值被觀測到的 epoch 秒。
- reconcile worker 的 stdout 契約不變: `<five>|<eff5>|<seven>|<eff7>|<burn_tte>` 五欄。
- 行格式仍為單行、空白分隔、`LC_ALL=C`、bash 3.2 與 awk 可解析。

**Failure modes**:

- 無法解析的行（欄數不符、該是數字的欄不是數字、9 欄 S 行的 class 三欄既非 `-` 也非數字）靜默丟棄，不報錯、不中止 frame。
- 拿不到 lock 或 `session_id` 為空的 frame 一律唯讀: 不寫 cache、不更新自己的觀測狀態，但仍顯示它讀到的權威值。
- awk 或 mv 失敗使 emission 為空時，各欄的數值 guard 讓 frame 保留自己 `parse_input` 得到的值，不出現警示。

**Acceptance criteria**:

- `tests/run-tests.sh` 全綠，且新增的 4 個 case 在把 `lib/collect.sh` 還原成修改前版本時會 FAIL。
- `bash -n lib/collect.sh` 與 `shellcheck -x statusline-command.sh` 乾淨。
- `spectra validate --changes fix-authority-freshest-observation` 與 `spectra analyze fix-authority-freshest-observation` 均 exit 0。

**Scope boundaries**: in scope 是 cross-session reconcile 的權威判準、cache 的兩種行格式、以及描述舊規則的註解與文件措辭。out of scope 是 rendering、burn projection 的取樣與 gate、lock 機制、`RL_SYNC` 語意、輸入 sanitization，以及顯示字串的版面。

## Risks / Trade-offs

- [新鮮度訊號是「pair 改變」，值一直不變的活躍 session 不會刷新 `observed_at`] → 無害: 該 session 的值此時等於權威值，誰持有權威都顯示同一個數字。真正需要奪權的情境（自己看到了不同的值）依定義就會讓 pair 改變。
- [唯讀 frame（lock 競爭或空 `session_id`）不寫回自己的觀測狀態] → 該 session 的 pair 比較會延到下一個可寫 frame，屆時仍與最後一次持久化的 pair 比較，改變照樣偵測得到，只是時間戳略晚，不影響誰該勝出。
- [秒級時間戳的平手] → `>=` 讓後寫者勝，與現行行為相同；lock 已序列化寫入，不會有兩筆同時寫進同一個記錄。
- [`S` 行欄位變多，檔案略微變大] → 每個 session 多 6 個短欄位，`RL_REG_TTL` 的剪除規則不變，檔案仍為每個 session 一行。
- [混版執行期間，舊版 code 讀到 9 欄 `S` 行會當 malformed 丟棄，使該 session 在舊版眼中變成新 session] → 曝險窗極短: `statusline-command.sh` 每一 frame 都從磁碟 source `lib/collect.sh`，換版對下一個 frame 立即生效，只有正在執行中的那一個 frame 會是舊版；且最壞結果是舊版短暫沿用它原本的 newest-session 行為，無 crash、無資料毀損。

## Migration Plan

1. 不需要轉檔: 新版讀到 4 欄 `W5`/`W7` 行時，直接把第 4 欄當 `auth_observed_at` 比較；讀到 3 欄 `S` 行時當「沒有前次 pair」並在同一次 rewrite 寫成 9 欄。
2. 第一個觀測到變化的 session 在第一輪 reconcile 就取得權威，過渡在一個 frame 內完成。
3. Purpose 段不走 delta: 2026-08-27 在本 repo 的暫存副本上跑完整 `spectra archive` 實測確認，spectra 2.3.1 的 delta 只搬 requirement 區塊，delta 裡即使寫了 `## Purpose` 也會被靜默忽略（validate 通過、archive 回報 `added: 2, modified: 7, removed: 1`，但 `openspec/specs/rate-limit-sync/spec.md` 的 Purpose 句原封不動）。前一個 archived change 就是這樣讓同一句留成過期的。因此 Purpose 的更正列為 apply 階段的實作動作（tasks 5.5）: 直接改 capability spec，不延到 archive，也不假裝 delta 蓋得掉它。
4. 回滾策略: 還原 `lib/collect.sh` 即可。舊版會丟棄 9 欄 `S` 行與所有 session 的觀測狀態，下一輪 rewrite 重新以 3 欄格式註冊，`W` 行第 4 欄回頭被當 `auth_first_seen` 解讀，行為退回修改前，cache 不需要手動清除。

## Open Questions

(none)
