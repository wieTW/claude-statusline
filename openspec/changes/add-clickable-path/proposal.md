# Add: cmd+click 路徑段開啟該資料夾（顯示文字不變）

## Why

statusline 左半第一段就是當前目錄（例 `claude-statusline`），使用者天天看著它，卻沒辦法直接跳到那個資料夾: 要開 Finder 得自己切窗、貼路徑。需求明確: **保持短名顯示**，但點下去要能開資料夾。

**先走過一條死路，實測證偽（記在這裡免得日後有人重試）**: 直覺解是把路徑段包成 OSC 8 超連結（`ESC ] 8 ; ; file://<cwd> BEL`）。靜態證據看起來全綠: CC 對 statusline stdout 只做 `trim().split().flatMap().join()`（binary 內 `v_a` 實讀）、不過濾 escape，而且 CC 自己也在發 OSC 8。**但實際捕捉真實 session 的原始 pty 輸出，OSC 8 出現 0 次**: CC 不是原樣傳遞 statusline 字串，而是解析成自己的樣式結構再重繪（我方輸出的 `ESC[0m` 出來變成 `ESC[22m`），hyperlink 在這一步被丟掉。`FORCE_HYPERLINK=1` 無效，binary 內 statusline 渲染路徑也查不到任何 hyperlink 支援。結論: **statusline 這一行本身不可能帶連結**，與寬度、終止符、字元集都無關。

既然行內帶不了連結，就讓**終端**去開。終端唯一握得住的 pane 識別是 **tty**，而:

- CC 的子進程**沒有** controlling terminal（`ps -o tty=` 回 `??`，`/dev/tty` 開不起來），所以 statusline 這側讀不到 tty。
- 但 statusline 命令的 **`$PPID` 就是 claude 進程**（實測 process chain 確認），而那個進程握有 pane 的 tty。

所以兩側各出一半: statusline 發布 `claude pid → cwd`，終端側的 opener 走 `tty → claude pid → cwd → open`。iTerm2 的 cmd+click 對匹配 Smart Selection 規則的文字會執行該規則的第一個 action（官方文件），且 CC 開著完整 mouse reporting 也不影響: iTerm2 把 cmd+click 留給自己（使用者 2026-08-10 在 CC 輸出區 cmd+click `~/` 路徑成功即為同一條路徑的既有實證）。

## What Changes

- **新 knob `PATH_CLICK`（預設 `true`）**: 開啟時，每幀用一個 detached 背景 job 把 `cwd` 寫進 `~/.claude/sl-cwd/<claude pid>`。前景不等它，渲染時間不受影響。
- **`$PPID` 必須在主 shell 讀**: 子 shell 的 `$PPID` 是 statusline 腳本自己，不是 claude。故由主流程把它當參數傳進 job。
- **一個 pid 一個檔，不用鎖**: token/rate cache 因為共用單檔才需要 mkdir 鎖；這裡改成每個 pane 各自一個檔，並行渲染不可能互蓋，也沒有 read-modify-write。
- **回收用 `ps -A` 不用 `kill -0`**: `kill -0` 對別的使用者的進程回 EPERM，與「進程已不存在」無法區分，會誤刪還活著的 pane 的記錄。整輪掃描只 fork 一次 ps。
- **權限 700/600**: 這份 map 等於列出所有開著的 pane 的工作目錄，不可被其他使用者讀。
- **新增 `scripts/open-pane-dir.sh`**: 解析 tty → claude pid（`ps -t`）→ 已發布目錄 → `open`。tty 來自 iTerm2 規則的 `\(session.tty)`，或在沒有參數時反問 iTerm2 前景 session（點擊會先 focus 該 pane）。巢狀 session 讓同一個 tty 上有多個 claude 進程，取最近寫入的記錄。tty 字串先驗格式（只允許裝置名），失敗一律走桌面通知: Smart Selection action 的 stdout/stderr 沒有任何地方看得到。
- **iTerm2 側是一次性設定**: 一條 Smart Selection 規則，regex 只框住 statusline 的第一段（`(?<![\w·])(?<!· )[A-Za-z0-9._@][A-Za-z0-9._@/-]*(?= ·)`，實測不會匹配 model/effort 段或一般散文），action 執行 opener。步驟寫進 README。
- **顯示完全不變**: 路徑段的文字、顏色、寬度、degrade 行為一個 byte 都沒動。

## Capabilities

### New Capabilities

- `path-click`: pane 工作目錄的發布與終端側開啟

### Modified Capabilities

(none: `display-segments` 與 `adaptive-layout` 不受影響，路徑段的渲染與寬度計算原封不動)
