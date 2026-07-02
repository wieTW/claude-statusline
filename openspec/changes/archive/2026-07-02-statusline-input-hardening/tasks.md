> 回溯性 change:以下實作皆已於 commit `6ee64f9`(harden external-input handling + private cache files)完成並通過完整 gate,故全部勾選。本 change 補的是規格與設計,不再改動 code。

## 1. 清理契約(已於 6ee64f9 shipped)

- [x] 1.1 Requirement: Single sanitization entry point。`parse_input`(lib/collect.sh)在單一 jq pass 中逐欄:先 `gsub` 把 `\n`/`\r` 轉義成字面量,再以 explode/implode 保留 `. >= 32 and (. < 127 or . > 159)`(剝除 C0 + DEL + C1 U+0080–U+009F),最後 `.[0:256]` 截 256 codepoints;read 順序與 jq 陣列位置一對一。**驗證**:安全案例 H/L/N/P/Q/R/S 綠燈。
- [x] 1.2 Requirement: session_id allow-list。jq 之後 `case "$session_id" in ''|*[!0-9A-Za-z_-]*) session_id="" ;; esac`,違規整欄歸空。**行為**:含 `/`、`..`、空白、`\` 或控制碼的 session_id 歸空,下游 last-msg 讀取與 token 累加 graceful 跳過。**驗證**:行為測試 —— 穿越樣式 `session_id="../secret"` 的 frame 為單行、不外洩 secret。
- [x] 1.3 Requirement: transcript_path traversal reject。jq 之後 `case "$transcript_path" in *..*) transcript_path="" ;; esac`。**行為**:含 `..` 的 transcript_path 歸空,effort_scan / token 累加跳過。**驗證**:`bash -n lib/collect.sh` 通過;含 `..` 時無 tail/find 讀取。
- [x] 1.4 Requirement: Shared re-sanitization for jq-bypass strings。抽出 `_sanitize_field`(設全域 `REPLY`:C0/DEL 單位元組 strip + 2-byte C1 strip + 256-byte cap);`git_branch`(collect.sh `collect_status`)與 `last_msg`(render.sh `build_left`)皆改呼叫它。**行為**:惡意 git 分支名或 last-msg 內容中的 SGR/控制碼被剝除,不注入終端、不 desync `vis_width`。**驗證**:安全案例 H/L/N/P/Q/R/S 綠燈;`git_branch` 與 `last_msg` 兩處清理集一致(共用同一函式)。
- [x] 1.5 Requirement: Private cache files via umask。`_reconcile_core` 與 `tokens_update` 開頭 `umask 077`,rate-limit / token 快取、暫存、鎖以 600/700 建立。**行為**:共享機器上快取檔不被跨使用者讀取。**驗證**:行為測試 —— 一次 RL_SYNC frame 後 `~/.claude/sl-ratelimit-cache` 權限為 600。
- [x] 1.6 Requirement: Only-our-SGR-reaches-the-terminal invariant。上述清理後,下游可假設終端只收到本腳本自己的 SGR;rate-limit remaining 夾為 ≥0。**驗證**:安全案例 H/L/N/P/Q/R/S 為此不變式的回歸守門,全綠。

## 2. 驗證 gate(已通過)

- [x] 2.1 完整 gate 全綠:`bash -n statusline-command.sh && bash -n lib/collect.sh && bash -n lib/render.sh`、`shellcheck -x statusline-command.sh`、`bash tests/run-tests.sh`。**驗證**:三命令皆 exit 0,末行 `ALL CHECKS PASSED`,安全案例 H/L/N/P/Q/R/S 無 `★ FAIL`。
