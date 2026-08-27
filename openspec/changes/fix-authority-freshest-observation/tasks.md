# Tasks: fix-authority-freshest-observation

## 1. 規格複核

- [x] 1.1 `Freshest-observation authority survives concurrent renders` 這條 requirement 讀完之後，實作者只靠它就能寫出「權威只看觀測時間、不看 `first_seen`」的判準，且四個目標情境（活躍舊 session 奪權、cap 調高後 used% 下降、window roll、閒置 session 未變 pair 奪不回）各自有 scenario。驗證: `spectra validate --changes fix-authority-freshest-observation` exit 0，並人工確認這四個 scenario 標題都在該 requirement 底下。
- [x] 1.2 `Session registry rows carry each session's last reported pair per class` 講清楚 9 欄 S 行的欄位順序、`-` 佔位、pair 相同時 `observed_at` 沿用、沒有前次 pair 時取 `first_seen`，以及唯讀 frame 不記錄觀測狀態。驗證: `spectra analyze fix-authority-freshest-observation` exit 0，並確認該 requirement 的 example 涵蓋「舊 3 欄行升級後不奪權」。
- [x] 1.3 六條 MODIFIED requirement（`Serialized read-modify-write with safe degradation on lock failure`、`Empty session id adopts read-only without destructive rewrite`、`Registry retention TTL is clamped to a hard floor`、`Malformed and old-format cache lines are silently dropped`、`Burn-projection sample series persists as a third cache line type`、`RL_SYNC master toggle gates the entire reconciliation`）除了指定的措辭與欄數更新之外，逐字保留原有內容。驗證: 對 `openspec/specs/rate-limit-sync/spec.md` 的同名區塊做 diff，變動行只出現在預期的幾句上。
- [x] 1.4 `Newest-session authority survives concurrent renders` 以 REMOVED 退場，Reason 記錄被推翻的前提與實測證據，Migration 指名接手的 requirement。驗證: 逐條列出舊 requirement 的保證（每 class 一筆、no lost update、雙向採納、權威不受 TTL 剪除、同 class 多行取最新），每一項都在新 requirement 找得到對應句子。

## 2. 測試先行（先紅後綠）

- [x] 2.1 新增 case T14: 較舊 `first_seen` 的 session 觀測到新 pair 時，會蓋掉閒置新 session 留下的權威，顯示改成新值。驗證: `tests/run-tests.sh` 的 T14 在修改前的 `lib/collect.sh` 上 FAIL、修好後 PASS。
- [x] 2.2 新增 case T15: cap 調高造成 used% 下降時，觀測到的較低值被採納，顯示不黏在舊的高值。驗證: T15 斷言 cache 的 `W5` 行值變小且 frame 顯示新值。
- [x] 2.3 新增 case T16: 任何 session 觀測到新的 `resets_at`（window roll）時整筆 re-key，舊 window 的記錄不與新記錄並存。驗證: T16 斷言 rewrite 後只剩新 key 的 `W5` 行。
- [x] 2.4 新增 case T17: 閒置 session 的 pair 未變時，即使 `first_seen` 最大也奪不回權威。驗證: T17 斷言 `W5` 行維持較新觀測的值，且該 frame 顯示的是權威值而非自己的舊值。
- [x] 2.5 既有 fixture 與斷言改用 9 欄 S 行，並保留一個 3 欄舊行 fixture 驗升級路徑。驗證: `tests/run-tests.sh` 既有 case 全綠，且升級後的 cache 內容符合 `Malformed and old-format cache lines are silently dropped` 的新 scenario。

## 3. 實作（lib/collect.sh）

- [x] 3.1 依決策「observed_at 放在 S 行、每個 class 一組」與「舊格式 S 行視為沒有前次 pair」，S 行載入與寫回改成 9 欄含 `-` 佔位，3 欄舊行在同一次 rewrite 就地升級。驗證: T14 到 T17 與 2.5 的升級斷言通過，`grep '^S ' ~/.claude/sl-ratelimit-cache` 在測試 fixture 上呈現 9 欄。
- [x] 3.2 依決策「pair 改變才更新 observed_at」，計算本 frame 每個 class 的觀測時間: pair 不同取 `now`、相同沿用、無前次 pair 取 `first_seen`。驗證: T17（相同 pair 不刷新）與 T14（不同 pair 刷新）同時通過。
- [x] 3.3 依決策「採納比較用 >=，同秒由後寫者勝」，`applycls` 的比較對象由 `first_seen` 換成觀測時間，其餘 guard（window key live and sane、used% 為數字）不變。驗證: T14、T15、T16 通過，且 `Freshest-observation authority survives concurrent renders` 的每個 scenario 都有對應斷言。
- [x] 3.4 依決策「W 行第四欄語意改為 auth_observed_at」，載入與寫回都把第 4 欄當觀測時間，舊行不需轉檔即可比較。驗證: 以既有 4 欄 `W5` fixture 起跑，第一輪 reconcile 後該行第 4 欄被換成觀測時間。
- [x] 3.5 唯讀 frame（lock 競爭或空 `session_id`）維持不寫 cache、不記錄觀測狀態，仍顯示讀到的權威，符合 `Serialized read-modify-write with safe degradation on lock failure` 與 `Empty session id adopts read-only without destructive rewrite`；`Registry retention TTL is clamped to a hard floor` 的 604800 下限與 `Burn-projection sample series persists as a third cache line type` 的取樣規則不動。驗證: 既有 T2.2 與 T2.4 保持綠，且 T2.4 之後 cache 的 inode、大小、mtime 不變。

## 4. 驗證

- [x] 4.1 全套測試綠燈，靜態檢查乾淨。驗證: `bash -n lib/collect.sh`、`shellcheck -x statusline-command.sh`、`tests/run-tests.sh` 三者皆 exit 0 且輸出 ALL CHECKS PASSED。
- [x] 4.2 新測試真的綁住這次改動。驗證: 在 copy 上把 `lib/collect.sh` 還原成修改前版本，`tests/run-tests.sh` 必須在 T14 到 T17 FAIL 並 exit 1。
- [x] 4.3 真實 cache 的遷移不掉資料。驗證: 複製一份現網 `~/.claude/sl-ratelimit-cache` 到暫存 HOME 跑一輪 reconcile，確認 S 行升級成 9 欄、W 行沿用、P 行不受影響、frame 仍輸出單行。

## 5. 文件與註解更正

- [x] 5.1 `lib/collect.sh` 的 rate-limit sync 區塊註解（現在的 232 到 266 行）改為正確前提: Claude Code 每次 API round trip 都會刷新該 session 的 `rate_limits`，閒置 session 才會一直回報最後拿到的值；同時把規則段改寫成 freshest-observation 與新的 S/W 行格式。驗證: `grep -n "START snapshot" lib/collect.sh` 無命中，且註解描述的行格式與實際寫回的欄位一致。
- [x] 5.2 `CLAUDE.md` 與 `AGENTS.md` 的 Cross-session rate-limit sync 節（兩檔逐字相同，現在的 148 到 166 行: 錯誤前提句在 148 到 149、cache 行型在 151 到 153、規則句在 155 到 158）同步正確前提、新的 `S`/`W` 行型與 freshest-observation 規則。驗證: `grep -n "newest session is the authority\|freezes .rate_limits. at each session" CLAUDE.md AGENTS.md` 無命中，且 `diff <(sed -n '146,170p' CLAUDE.md) <(sed -n '146,170p' AGENTS.md)` 無輸出。
- [x] 5.3 `README.md` 描述舊前提的三處（現在的第 3、122、157 行）改成「閒置 session 會一直回報最後拿到的值，這條 statusline 會跨 session 校正」。驗證: `grep -n "freezes your quota\|freezes each session's rate-limit\|frozen startup snapshot" README.md` 無命中。
- [ ] 5.4 `rate-burn-projection` 的 `Burn-rate slope estimation from persisted samples` 在 archive 之後，描述的取樣量是 freshest-observation authority 的採納值，不再引用已退場的規則名。驗證: archive 後 `grep -n "newest-session" openspec/specs/rate-burn-projection/spec.md` 無命中，且該 requirement 的 scenario 與 example 與 archive 前逐字相同（`git diff` 只動到那一句）。
- [x] 5.5 `openspec/specs/rate-limit-sync/spec.md` 的 Purpose 段（現在的第 5 到 6 行）在本次實作中直接改寫: 前提由 `correcting Claude Code's frozen per-session start snapshot` 改成「校正閒置 session 一直回報的過期值」，規則名由 `"newest session is the authority"` 改成 `"freshest observation is the authority"`。這一步屬 apply 階段的實作動作，不得延到 archive: delta 機制不搬 Purpose 段（實測依據見 design.md 的 Migration Plan 末段）。驗證: `! grep -n 'newest session is the authority\|frozen per-session start snapshot' openspec/specs/rate-limit-sync/spec.md`。

## 6. 收尾驗收

- [x] 6.1 fresh-context verifier（不夾帶實作者自評）確認每條 delta requirement 都有對應實作與測試。驗證: verifier 回報逐條對應的 檔案:行號，且自行重跑 4.1 與 4.2 的命令得到同樣結果。
- [x] 6.2 change 的 artifact 一致性。驗證: `spectra validate --changes fix-authority-freshest-observation` 與 `spectra analyze fix-authority-freshest-observation` 皆 exit 0 且無未解 finding。
