## 1. 前置:防呆與去重重構(無觀感變化)

- [x] 1.1 依 design「parse_input 位移防呆」,在 lib/collect.sh 的 jq 陣列與 read 區塊兩側加上 `# NN field` 編號對照註解,並新增一條 sentinel 測試(每個欄位餵入獨特值、斷言每個全域變數落在正確欄位)。行為:欄位錯位時測試失敗、對位時通過。驗證:在 tests/run-tests.sh 故意對調兩欄位時新測項報 FAIL,還原後 bash tests/run-tests.sh 印出 ALL CHECKS PASSED。
- [x] 1.2 依 design「去重重構」,抽出共用的時間長度格式化函式(ttl 與 last-msg 的 D/H/m 邏輯共用)與共用的 bounded-emit 溢位保護(render_line 內兩段 byte-identical 區塊)。行為:重構前後對相同 stdin 產生 byte 相同輸出。驗證:重構前先存基準輸出,重構後 diff 為空,且 bash tests/run-tests.sh 全綠。

## 2. Token 消耗段(token-usage)

- [x] 2.1 依 design「Token 加總背景化與快取格式」實作背景 FD job:加總主 transcript(stdin transcript_path)與其同層 subagents 目錄下的 agent-*.jsonl,寫入使用者 .claude 目錄的 token 快取(T-line 格式),前景幀只讀快取。對應 spec「Token Data Sources」與「Non-Blocking Background Summation」。行為:前景永不阻塞於加總。驗證:以已知 transcript 手動比對加總值;對單幀計時確認不因加總而超出既有預算。
- [x] 2.2 依 design「Token 數定義(in+out,不含 cache)」實作 spec「Cumulative Session Token Display」:session 顯示 input_tokens+output_tokens 累計(排除 cache_read/cache_creation),格式化為 k/M。行為:渲染出本 session 累計 token 字串。驗證:餵入已知 usage fixture,斷言渲染字串(例如 562k)。
- [x] 2.3 實作 spec「Subagent Token Display」:有 subagent token(>0)才追加 `⊂` 與 subagent 的 in+out 累計,無則只印 session 數。行為:條件式顯示 ⊂。驗證:兩種 fixture(有/無 subagent),分別斷言 ⊂ 出現與不出現。
- [x] 2.4 實作 spec「Change-Gated Recompute」:以來源檔 size/mtime 判斷,僅在變動時於背景重算,否則沿用快取值。行為:未變動不重算。驗證:連續多幀未變動時觀察快取不被重寫(mtime 不變),來源變動後值更新。
- [x] 2.5 實作 spec「Token Display Respects Statusline Hard Rules」:token 段走既有消毒與 256 cap、背景 job 導入 </dev/null、僅用 bash 3.2 語法。行為:不洩漏控制字元、不竊取 stdin JSON。驗證:shellcheck -x statusline-command.sh 乾淨、bash -n 三檔通過、注入 fixture 不外洩。

## 3. 燃燒投影警報(rate-burn-projection)

- [x] 3.1 依 design「燃燒投影取樣與斜率」實作 spec「Bounded persisted sample series on the rate-limit cache」:於 rate-limit 快取附加有界取樣行(時間、採用後 used%),沿用單趟 awk + per-pid temp + atomic mv。行為:跨幀累積有界筆數樣本。驗證:多幀後檢視快取含 ≤ 上限筆樣本行。
- [x] 3.2 實作 spec「Burn-rate slope estimation from persisted samples」:由樣本計算平滑斜率並推算見底時間。行為:輸出見底分鐘數。驗證:給定樣本序列 fixture,斷言計算出的見底分鐘數。
- [x] 3.3 實作 spec「Conditional display of the burn alarm」:僅當斜率>0 且預估見底早於 reset 才顯示警報,否則隱形。行為:平時隱形、危險時出現。驗證:六列情境矩陣測項(隱藏/黃/紅)逐列斷言。
- [x] 3.4 實作 spec「Burn alarm indicator content and color thresholds」:顯示見底時間,>30m 黃、≤30m 紅。行為:依緊迫度上色。驗證:30m 邊界上下各一 fixture,斷言色碼。
- [x] 3.5 實作 spec「Depletion-only direction」:剩餘回升時不顯示任何指標(只 ↘)。行為:上升情境無指標。驗證:剩餘上升 fixture,斷言無 ↘/↗。
- [x] 3.6 實作 spec「Configurable sensitivity knob」:config 旋鈕三檔(保守/平衡為預設/敏感),以見底門檻控制顯示。行為:同情境不同檔顯示不同。驗證:固定情境切三檔,斷言顯示與否差異。
- [x] 3.7 實作 spec「Burn projection end-to-end result matrix」:六列情境(緩用、撐得到 reset、閒置、穩定逼近、快撞牆、暴衝)端到端行為一致。驗證:對應 tests/run-tests.sh 測項全綠。

## 4. 漸進式壓縮排版(adaptive-layout)

- [x] 4.1 實作 spec「Drawable-width invariant」與「Width-tiered rendering scenarios」:任何寬度下輸出單行、不超過可繪寬、不換行。行為:永不溢出。驗證:沿用既有 J/P/M 測法掃描多個 COLUMNS,斷言單行且寬度 ≤ 邊界。
- [x] 4.2 依 design「壓縮排版犧牲順序」實作 spec「Per-segment priority and forms」:為各區段定義優先級與緊湊/完整兩形態。行為:渲染依優先級表決定形態。驗證:內容審查 priority 表與渲染一致 + 對應測項。
- [x] 4.3 實作 spec「Fixed sacrifice order」:依固定 14 段順序逐步降級(① junction → … → ⑭ 核心)。行為:寬度遞減時依序降級。驗證:逐寬度遞減,斷言每段在預期寬度消失或縮短。
- [x] 4.4 實作 spec「Shrink and truncate preferred over drop」:截斷/縮短優先於丟棄,優先級丟棄為最後手段。行為:中等寬度時 session 變 `…` 而非直接消失。驗證:中等寬度 fixture 斷言出現截斷標記。
- [x] 4.5 實作 spec「Core always remains」:path basename 與 ctx% 永遠保留。行為:極窄仍保核心。驗證:COLUMNS 1–2 fixture 斷言仍含 path 與百分比、不崩、單行。

## 5. rate-limit 同步正確性(rate-limit-sync)

- [ ] 5.1 依 design「reconcile 併發鎖與空 session 跳過」實作 spec「Serialized read-modify-write with safe degradation on lock failure」與「Newest-session authority survives concurrent renders」:以 mkdir spin-lock(有界重試 + staleness 偷鎖)序列化 read+awk+mv,取不到鎖則安全跳過寫入但仍顯示正確採用值。行為:併發不丟更新。驗證:新增併發測項(背景多開 render 後 wait),斷言每個 session 的 W line 皆存活。
- [ ] 5.2 實作 spec「Empty session id adopts read-only without destructive rewrite」:session_id 為空時跳過 mv(唯讀採用、不寫回)。行為:匿名幀不破壞快取。驗證:空 sid render 後快取 inode/mtime 不變,但仍正確採用 authority 值。
- [ ] 5.3 實作 spec「Reconciliation respects the parse_input sanitization and cap contract」:reconcile 路徑沿用 parse_input 消毒、256 cap 與數值守門。行為:對畸形輸入不崩。驗證:torn/binary 快取 fixture render 後仍單行、含有效百分比、stderr 為空。
- [ ] 5.4 依 design「reconcile 背景化(效能)」將 reconcile 改為背景 FD job 與 git 階段重疊(維持 </dev/null 硬規則)。行為:每幀省去序列成本、結果不變。驗證:section T 全綠(行為等同)、單幀計時較改前下降。

## 6. context 與 last-message 修正(context-meter, last-message-age)

- [ ] 6.1 依 design「context 門檻改用 context_window_size / exceeds_200k_tokens」實作 spec「Model-context-size-aware usage alerting」:依 context window 大小判斷警示,1M 模型不因 used%>80% 轉紅。行為:門檻隨模型 context 大小調整。驗證:1M 模型 + 85% fixture 斷言非紅。
- [ ] 6.2 實作 spec「200k cost/cache cliff marker」:跨越 200k 成本懸崖時顯示標記。行為:越界顯示懸崖標記。驗證:exceeds_200k_tokens=true fixture 斷言標記出現。
- [ ] 6.3 實作 spec「Coloring and cliff marker are decoupled」:百分比上色與懸崖標記彼此獨立。行為:兩者互不影響。驗證:組合 fixture(高%/低% × 越界/未越界)斷言兩者獨立呈現。
- [ ] 6.4 實作 spec「Last-message timestamp with cache-freshness-colored delta」:HH:MM 加 Δ,顏色沿用快取新鮮度三階(LASTMSG_WARN/LASTMSG_STALE)。行為:既有顏色語意不變。驗證:既有 U 段測項保留並全綠。
- [ ] 6.5 依 design「跨日時鐘修正」實作 spec「Cross-day timestamps include the date」:當上次訊息與現在不同本地日曆日時前綴日期(僅 Δ≥1h 才取本地時區 fork)。行為:跨日不被誤讀為今天。驗證:26h 前 fixture 斷言渲染含日期、非裸 HH:MM;同日 fixture 斷言僅 HH:MM。

## 7. 收尾與驗證

- [ ] 7.1 更新過時敘述:移除/修正 statusline-command.sh 內過時的「no such field exists」cache 註解(現已可由 current_usage 取得),並更新 CLAUDE.md 架構說明納入 token 段、燃燒投影、新增 config 旋鈕。行為:文件與實作一致。驗證:grep 確認舊敘述不存在、內容審查新段落齊全。
- [ ] 7.2 全量 verify gate 與清理:通過 bash -n statusline-command.sh lib/collect.sh lib/render.sh、shellcheck -x statusline-command.sh、bash tests/run-tests.sh,並刪除 repo root 的 preview-*.html 討論草稿。行為:整體門檻通過、草稿不入庫。驗證:三命令皆 exit 0 且印 ALL CHECKS PASSED,ls preview-*.html 回報不存在。
