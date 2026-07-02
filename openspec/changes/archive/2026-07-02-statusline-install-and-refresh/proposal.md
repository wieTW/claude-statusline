## Why

statusline 至今沒有規範「如何被安裝進 Claude Code」與「idle 時如何保持更新」。commit `e25d8a2`(docs: rewrite README for users + add install.sh)新增了 `install.sh`(把 statusline 冪等地併入 `~/.claude/settings.json`)並引入 `refreshInterval` 設定,但兩者只以 install.sh 註解與 README 存在,無 proposal / design / tasks / spec。

`refreshInterval` 尤其值得規範:它的取值直接餵給 burn-projection 的取樣序列 —— rate-burn-projection spec 已規定「兩取樣點間隔須 ≥60 秒」這道防守閘,而 `refreshInterval` 正是決定取樣頻率的旋鈕。刷太快(<~15s)會讓 5 個取樣點全擠進一分鐘、使 burn 警報永久熄火。這個跨 capability 的交互目前無規格記錄,一次未來的「把預設調成 5 秒」會悄悄破壞已規範的警報,而無守門。

本 change 為安裝機制與 idle 刷新節奏補上單一擁有它們的 capability:`installation`。純屬回溯性文件化,不改任何 code。

## What Changes

- **記錄安裝機制(e25d8a2)**:`install.sh` 以 `jq` 合併方式把 `statusLine`(type=command、command=腳本絕對路徑、refreshInterval)寫入 `~/.claude/settings.json`,並:合併保留其他既有設定、寫入前先時間戳備份、遇非法 JSON 拒絕改動、缺 `jq` 相依時明確報錯、對腳本 `chmod +x`、以自身位置解析出腳本絕對路徑。冪等,可重跑。
- **記錄 refreshInterval 節奏(e25d8a2)**:預設 60 秒,並記錄「為何是 60」的理由 —— 顯示粒度為整分鐘、且 60s 讓 burn 取樣序列維持有效;<~15s 會餓死 burn 警報,~30s 是不改 code 的安全下限。支援以第一位置引數或 `REFRESH_INTERVAL` 環境變數覆寫;值為 `0` 時:建立情境省略該鍵、合併情境刪除既有的 stale 鍵。
- **記錄與 rate-burn-projection 的交互**:`refreshInterval` 決定取樣頻率,故其下限與 burn spec 的「≥60s 取樣間隔閘」互相依存;預設 60 是同時滿足兩者的值。

## Non-Goals

- 不改任何 code。`install.sh` 與 `refreshInterval` 已於 `e25d8a2` shipped 且行為測試全綠;本 change 僅回溯補規格,tasks 皆已完成勾選。
- 不規範 `~/.claude/settings.json` 中 statusLine 以外的任何鍵。
- 不把 `refreshInterval` 的下限硬編進 code(維持使用者可自行承擔風險地設更小值);只在規格記錄其與 burn 取樣的交互與建議下限。
- 不涵蓋 statusline 顯示旋鈕(STYLE / CTX_BAR / …)的契約(另議)。

## Capabilities

### New Capabilities

- `installation`: 把 statusline 冪等地接進 `~/.claude/settings.json` 的安裝機制,以及 `refreshInterval` idle 刷新節奏及其與 burn 取樣的交互。

### Modified Capabilities

(none)

## Impact

- Affected specs: installation (new)
- Affected code(已於 e25d8a2 shipped,本 change 不再改動):
  - Modified: README.md
  - New: install.sh
  - Removed: (none)
