# Design — add-clickable-path

## 為什麼不是 OSC 8（這節是防重試，不是背景交代）

日後任何人想「讓 statusline 帶超連結」都會先想到 OSC 8。這條路已經實測走死，證據如下，不要重來:

- 抓真實 CC session 的原始 pty 輸出（expect 開 pty、log 全部 byte），statusline 那行送出的是
  `ESC[38;2;122;162;247m ESC[1m claude-statusline ESC[22m …`，整份捕捉的 OSC 8 計數是 **0**。
- 注意 `ESC[22m`: statusline 腳本輸出的是 `ESC[0m`。CC 把字串解析成自己的樣式模型再重繪，`bold` 的關閉被寫成
  `22m`。既然是重繪，任何它不認識的 escape（OSC 8 在內）就不會被重建。
- `FORCE_HYPERLINK=1` 加上 `TERM_PROGRAM=iTerm.app` 重測，仍是 0。
- binary 內與 statusline 渲染相關的程式碼沒有任何 hyperlink 處理；搜到的 hyperlink 字串全部來自內嵌的 ripgrep。

補充一個容易誤導的中間結論: CC 接收 statusline stdout 的那一段（`v_a`）確實**沒有**過濾 escape，只做
`trim().split("\n").flatMap(c=>c.trim()||[]).join("\n")`。只讀那裡會得出「可行」的錯誤結論。過濾發生在渲染層。

## 識別 pane 的唯一可行鏈

終端能認得的 pane 識別只有 tty。兩邊各缺一半:

| | 有什麼 | 缺什麼 |
|---|---|---|
| statusline 側 | `cwd`（stdin JSON 給的） | tty: CC 的子進程沒有 controlling terminal（`ps -o tty=` 回 `??`，`/dev/tty` 開不了） |
| 終端側 | tty（iTerm2 的 session 變數） | `cwd`: iTerm2 猜的目錄不準（實測它回報的是另一個目錄，因為 CC 不是 shell、沒有 shell integration） |

接起來的關鍵是 **statusline 命令的 `$PPID` 就是 claude 進程**（實測 process chain: statusline → claude → …），
而 claude 進程**有** tty。所以用 claude pid 當共同 key: 一邊寫 `pid → cwd`，一邊查 `tty → pid`。

`$PPID` 必須在主 shell 求值。背景 job 內的 `$PPID` 是 statusline 腳本自己的 pid，不是 claude，寫出去的 key 會對不上。

## 為什麼一個 pid 一個檔

token cache 與 rate-limit cache 都是單一共用檔，所以都得配 mkdir 自旋鎖來序列化 read-modify-write。這裡不需要:
每個 pane 只寫自己那一個檔案，內容是整份覆寫，並行渲染在檔案層天然隔離。少一組鎖就少一整類競態與 stale-lock 問題。

代價是要自己回收死掉的 pane 的檔案。回收用 `ps -A` 掃一次，不用 `kill -0`: 後者對別人的進程回 EPERM，跟
「進程不存在」在 shell 層無法區分，會把還活著的 pane 記錄刪掉（測試 `CLK` 有一條專門盯這個: pid 1 不屬於本使用者，
必須存活）。

## regex 為什麼長這樣

`(?<![\w·])(?<!· )[A-Za-z0-9._@][A-Za-z0-9._@/-]*(?= ·)`

- `(?= ·)`: 只認「後面接空格加 `·`」的 token，那是 statusline 的段分隔符。
- `(?<!· )`: 排除前面是 `· ` 的 token，也就是 model、effort 這些後續段。
- `(?<![\w·])`: 不加這條，regex 會從 `xhigh` 的中間切出 `high`（前一個字元是 `x`，繞過了上一條 lookbehind）。

實測樣本: 短名、含子路徑（`repo/src/lib`）、含點的目錄名（`my.project_v2`）都只框出路徑段；一般散文不匹配。

## 殘餘限制

- **只在 iTerm2 上成立**，而且需要使用者手動加一次規則。iTerm2 執行中改 plist 會在它結束時被覆寫，所以沒辦法代設定；
  Dynamic Profiles 能即時載入但會另建 profile，反而更麻煩。
- 規則的 action 是「執行命令」，不是真的超連結: 沒有 hover 下劃線之類的視覺回饋。
- 目標是 `cwd`。路徑段顯示 `專案名/子路徑` 時，點任一段都開最深的那層，不做逐段分區。
- 一般散文若剛好出現 `token · `，cmd+click 也會觸發一次開資料夾。後果無害，且 iTerm2 內建的路徑/URL 規則仍優先。
