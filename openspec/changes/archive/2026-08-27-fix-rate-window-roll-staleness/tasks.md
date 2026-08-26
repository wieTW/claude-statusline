# Tasks — fix-rate-window-roll-staleness

## 1. 規格

- [x] 1.1 rate-limit-sync delta: per-class 權威（W5/W7）、roll 後採納（值＋resets_at）、emission 5 欄、key sanity bound、legacy `W` 行淘汰
- [x] 1.2 rate-burn-projection delta: P 取樣/slope key 改 reconciled effective 5h key
- [x] 1.3 衝突檢查（fresh agent、不附自評）＋ spectra validate（衝突檢查抓到 3 條既有 requirement 的舊格式範例未列 MODIFIED＋burn spec 一處措辭，已全數補進 delta；validate 綠）

## 2. 測試先行（先紅後綠）

- [x] 2.1 新增 regression case T10: 凍結 session（own key 過期）＋ cache 有 live W5/W7 → 採納值與倒數（實測 RED on pre-fix code）
- [x] 2.2 新增 case T11: 類別隔離（只有 live W7 時，過期的 5h 不得誤採 7d 權威）
- [x] 2.3 新增 case T12: sanity bound（`W5 9999999999 …` 不載入、不採納、rewrite 後消失；frame report 的絕遠 key 不寫入）
- [x] 2.4 新增 case T13: legacy 4 欄 `W` 行於 rewrite 淘汰、不被採納
- [x] 2.5 既有 T/T2/Y fixture 與斷言改 W5/W7 格式＋5 欄 emission；T2.1 改為跨類別（W5×W7）並行 no-lost-update

## 3. 實作

- [x] 3.1 `_reconcile_core` awk: per-class 載入（newest-fs 收斂）、class-scoped applycls（含 sanity bound、key 存字串防 CONVFMT）、effective-key 取樣與 slope、5 欄 emission
- [x] 3.2 `reconcile_read`: 5 欄解析＋eff key all-digits guard 覆寫 `five_reset`/`seven_reset`
- [x] 3.3 collect.sh 區塊註解與 cache 行格式說明同步；statusline-command.sh RL_SYNC 註解同步

## 4. 文件

- [x] 4.1 CLAUDE.md 架構節（cache 行型、rule、emission 格式）同步；AGENTS.md 同句同步

## 5. 驗證

- [x] 5.1 bash -n ×3 ＋ shellcheck -x ＋ tests/run-tests.sh 全綠（ALL CHECKS PASSED，2026-08-01）
- [x] 5.2 重跑最小重現: Case B 由 `0m 13%` 變 `2H30m 97%`；真實 cache 以 copy 做遷移 smoke（legacy 淘汰、9999999999 歸零）；live 環境實測已自然遷移完成
- [x] 5.3 T5 fresh verifier 驗收: 通過（gate 三命令 exit 0＋ALL CHECKS PASSED；copy 上 revert lib/collect.sh → 14 ★ FAIL exit 1，集中 T10-T13 與連鎖 case；六條 delta requirement 逐條對應實作行號、無缺口。2026-08-01）
