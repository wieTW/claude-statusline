## Why

statusline 大部分「使用者實際看到什麼」—— path / model / effort / thinking / git / worktree / session name 這些 base segment 的**內容與顏色** —— 至今沒有任何 spec。既有的 `adaptive-layout` 只規範它們的寬度與降級順序,`context-meter` 只借用 1M 標記,`theme-palette`(另一 change)只定義調色盤角色,但「path 怎麼推導、model 怎麼壓縮、effort 五級怎麼上色、thinking 何時示警、git 分支/髒污/diffstat 怎麼呈現」全無規範。這是 Spectra 導入前的祖傳基線,補上它讓整條線的觀察行為都有主。純文件,不改 code。

## What Changes

新增 capability `display-segments`,規範九個 base segment 的內容與顏色語意:
- **Path**:cwd 在 project_dir 之下時顯示「專案名/相對路徑」,否則 basename,`/` 根目錄原樣;粗體青色。
- **Model**:MD 色;full 形式把 ` (1M context)` 改寫成 `(1M)`,compact 形式取首字。
- **Effort**:五級顏色(low=RD、medium=OG、high/xhigh/max=DM、未知不上色);`effort_mode` 顯示(ultracode→`ultra`、auto→`auto·<level>`),且 mode 由 transcript 的 `<local-command-stdout>` `/effort` 輸出經 `effort_scan` 回復(stdin JSON 只帶已解析的 level)。
- **Thinking**:僅異常才顯示 —— `NORM_THINKING=true` 時只在關閉時紅字 `no-think`;`false` 時只在開啟時灰字 `thinking`;缺值靜默。
- **Git branch**:分支名(detached HEAD 退回 short sha)+ 髒污 `*`(tracked 有變更 OR 有 untracked 新檔);WH 色;分支字串繞過 jq,經再清理。
- **Git diffstat**:`+N`(GR)/`-N`(RD_DATA)以 `/`(SP)相接,排除 untracked 新檔。
- **Worktree**:`[wt:NAME]`,DM 色。
- **Session name**:DM 色,最右。
- **Segment 分隔**:各段以 ` │ `(SEP,SP/DM 結構灰)相接。
涵蓋 `NORM_THINKING` config 旋鈕。

## Non-Goals

- 不改任何 code(這些行為早已存在於 `build_left`/`build_right`/`collect_status`/`effort_scan`)。
- 不涉及寬度/降級(`adaptive-layout` 擁有)、調色盤 RGB 值(`theme-palette` 擁有)、rate-limit 段內容(`rate-limit-display`/`rate-limit-sync`/`rate-burn-projection` 擁有)、context 段(`context-meter` 擁有)。

## Capabilities

### New Capabilities

- `display-segments`: 左右兩半 base segment(path/model/effort/thinking/git/worktree/session + 段分隔)的內容與顏色語意,含 `NORM_THINKING` 旋鈕。

### Modified Capabilities

(none)

## Impact

- Affected specs: display-segments (new)
- Affected code: (none — 純文件回溯;行為已存在於 lib/render.sh、lib/collect.sh)
