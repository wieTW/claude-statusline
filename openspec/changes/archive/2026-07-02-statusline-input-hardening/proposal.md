## Why

statusline 的信任邊界 —「所有外部字串在到達終端前如何被清理」— 至今沒有任何 capability spec 擁有它。既有的六份 spec 只把它當成「pre-existing 前提」交叉引用(每份都寫「MUST be read only through parse_input, the single sanitization entry point」),卻沒有一份規範這道防線本身：清哪些字元、為什麼、以及繞過 jq 的兩條路徑(git 輸出、last-msg 檔)如何補清。

commit `6ee64f9`(harden external-input handling + private cache files)又新增了四道守衛 —— post-jq 的 `session_id` allow-list、`transcript_path` 穿越拒絕、抽出共用的 `_sanitize_field`、以及快取檔的 `umask 077` —— 全部 shipped 但無 proposal / design / tasks / spec。這是目前最大的 SDD 缺口:一次未來的編輯若悄悄放寬 allow-list、拿掉穿越檢查、或讓 `git_branch` 漏清,沒有任何規格或回歸守門會攔住它。

本 change 為「已存在但無主」的清理契約與「已 shipped 但無規格」的四道守衛,補上單一擁有它們的 capability:`input-sanitization`。純屬回溯性文件化,不改任何 code。

## What Changes

- **記錄既有契約(無主 → 有主)**:`parse_input` 是所有外部字串的唯一清理入口 —— 逐欄先把 `\n`/`\r` 轉義成字面量以維持單行對齊,再以 explode/implode(非 regex)保留 `. >= 32 and (. < 127 or . > 159)`,即剝除 C0 + DEL + C1 區塊(U+0080–U+009F,含 U+009B 8-bit CSI),最後截到 256 codepoints。jq 的 `read` 順序與陣列一對一位置對應。
- **記錄守衛 1 — `session_id` allow-list(6ee64f9)**:jq 之後再收緊,`session_id` 僅允許 `[A-Za-z0-9_-]`,任何其他字元 → 整欄歸空。真實 CC session id(UUID)是此集合的子集。擋掉:awk 逸出(需 `\`)、空白分隔快取記錄破壞(需空白)、路徑穿越(需 `/` 或 `..`)。
- **記錄守衛 2 — `transcript_path` 穿越拒絕(6ee64f9)**:jq 之後 `*..*` → 歸空,避免 tail/find 讀到非預期路徑。
- **記錄守衛 3 — 共用 `_sanitize_field`(6ee64f9)**:繞過 jq 的兩條外部字串 —— `git_branch`(來自 git)與 `last_msg`(讀自檔)—— 共用同一組 C0/DEL + 2-byte C1 strip + 256-byte cap,兩份過濾器不再各寫一份而漂移。
- **記錄守衛 4 — 私有快取檔 `umask 077`(6ee64f9)**:`_reconcile_core` 與 `tokens_update` 以 `umask 077` 建立 rate-limit / token 快取、暫存檔、鎖目錄(600/700),共享機器上不被跨使用者讀取(它們存放 session id 與用量)。
- **記錄總不變式**:經上述清理後,下游可假設「只有本腳本自己的 SGR 碼會抵達終端」;此外 rate-limit remaining 夾為 ≥0。既有回歸案例 H/L/N/P/Q/R/S 即是這道防線的守門。

## Non-Goals

- 不改任何 code。四道守衛已於 `6ee64f9` shipped 且測試全綠;本 change 僅回溯補規格,tasks 皆已完成勾選。
- 不新增守衛、不放寬或收緊任何既有過濾集(C0/DEL/C1 範圍、allow-list 字元集、256 上限、穿越樣式)。
- 不重構 `parse_input` 的位置對應 read 契約為 key 對應(那是另一個明確被排除的大型重構)。
- 不涉及顯示內容/顏色、效能、或其他 capability 的行為。

## Capabilities

### New Capabilities

- `input-sanitization`: statusline 對所有外部字串(stdin JSON 欄位、git 輸出、last-msg 檔)的清理契約與注入/穿越/私有快取防線。

### Modified Capabilities

(none)

## Impact

- Affected specs: input-sanitization (new)
- Affected code(已於 6ee64f9 shipped,本 change 不再改動):
  - Modified: lib/collect.sh, lib/render.sh
  - New: (none)
  - Removed: (none)
