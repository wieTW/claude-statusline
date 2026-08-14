# Tasks — add-clickable-path

## 1. 可行性實查（每條都要有證據，不接受靜態推論）

- [x] 1.1 OSC 8 走不走得通: 抓真實 CC session 原始 pty 輸出，statusline 行的 OSC 8 計數為 0；我方 `ESC[0m` 被改寫成 `ESC[22m`，證明 CC 重繪而非原樣傳遞
- [x] 1.2 排除能力偵測干擾: `FORCE_HYPERLINK=1` + `TERM_PROGRAM=iTerm.app` 重測，仍為 0
- [x] 1.3 排除「CC 接收端過濾」誤判: binary 內 `v_a` 只做 trim/split/flatMap/join，不過濾 escape（過濾在渲染層，不在這裡）
- [x] 1.4 statusline 側能不能拿到 tty: 不能，CC 子進程 `ps -o tty=` 回 `??`、`/dev/tty` 開不了
- [x] 1.5 statusline 的 `$PPID` 是不是 claude: 是（實測 process chain），且該進程持有 pane 的 tty
- [x] 1.6 iTerm2 的 cmd+click 會不會執行 Smart Selection action: 官方文件確認「A cmd-click on text matching a smart selection rule will invoke the first rule」
- [x] 1.7 mouse reporting 會不會吃掉 cmd+click: CC 開了 1000/1002/1003/1006，但 iTerm2 保留 cmd+click（使用者 2026-08-10 在 CC 輸出區 cmd+click `~/` 路徑成功為既有實證）
- [x] 1.8 iTerm2 自己認的目錄能不能用: 不能，實測它回報的目錄與 CC 的 cwd 不同（CC 不是 shell，沒有 shell integration）

## 2. 規格

- [x] 2.1 新 capability `path-click`: 發布契約、回收規則、權限、opener 解析與失敗行為、knob

## 3. 實作

- [x] 3.1 `PATH_CLICK` knob（`statusline-command.sh`，預設 `true`）
- [x] 3.2 `start_cwdmap_job` / `cwdmap_update`（`lib/collect.sh`）: detached 發布、每 pid 一檔、`ps -A` 回收、umask 077
- [x] 3.3 主流程在主 shell 傳入 `$PPID`
- [x] 3.4 `scripts/open-pane-dir.sh`: tty 格式驗證 → `ps -t` 找 claude pid → 取最近寫入的記錄 → `open`；失敗走桌面通知，`SL_OPEN_NOTIFY=0` 可靜音

## 4. 測試

- [x] 4.1 新增 CLK section: 發布格式（以 pid 命名、內容為 cwd）、目錄 700 / 檔案 600、死 pid 回收、活 pid（含他人的 pid 1）不得誤刪、非 pid 檔案不得誤刪、`PATH_CLICK=false` 零發布、opener 的 tty 穿越字串拒絕與未知 pane 乾淨失敗
- [x] 4.2 revert 檢驗: `PATH_CLICK=false` 時 CLK 轉紅（實跑確認）
- [x] 4.3 全套件綠: `ALL CHECKS PASSED`；`shellcheck -x statusline-command.sh` 與 `shellcheck scripts/open-pane-dir.sh` 皆乾淨；三個 `bash -n` 通過
- [x] 4.4 端到端實跑 opener: `open-pane-dir.sh /dev/ttys002` → Finder 前景視窗 target 實測為該 pane 的目錄

## 5. 文件

- [x] 5.1 README: 路徑段說明、`PATH_CLICK` knob、「Clickable path」設定步驟（regex 與 action 可直接複製）
- [x] 5.2 CLAUDE.md / AGENTS.md: 摘要段、knob 清單、新增架構節（含 OSC 8 為何不可行的實測結論，防日後重試）、測試 section 索引

## 6. 待使用者

- [ ] 6.1 在 iTerm2 加那條 Smart Selection 規則（無法代做: iTerm2 執行中改 plist 會在它結束時被覆寫）
- [ ] 6.2 實機 cmd+click 驗收
- [ ] 6.3 決策點 B: 准許 archive
