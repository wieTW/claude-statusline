> 回溯性 change:以下實作皆已於 commit `e25d8a2`(docs: rewrite README for users + add install.sh)完成並通過行為測試,故全部勾選。本 change 補的是規格與設計,不再改動 code。

## 1. 安裝機制(已於 e25d8a2 shipped)

- [x] 1.1 Requirement: Idempotent settings merge。`install.sh` 以 `jq` 讀整份 `~/.claude/settings.json`、只重指派 `.statusLine = ((.statusLine // {}) + $patch)`,保留其他所有鍵;無既有檔時建立僅含 statusLine 的最小檔。**行為**:安裝後非 statusLine 鍵不變、既有 statusLine 的其他鍵(padding)保留。**驗證**:行為測試 —— 合併後 `.model`/`.permissions`/`.statusLine.padding` 皆保留,`.statusLine.command` 更新。
- [x] 1.2 Requirement: Backup and invalid-JSON refusal。寫入前 `jq empty` 驗證既有檔;非法 → 拒絕、原檔不變、非零退出;合法 → 先複製到 `settings.json.bak.<timestamp>`,再暫存檔 + `mv` 原子寫入。**驗證**:行為測試 —— 對 `{not json` 的檔安裝時印出拒絕訊息且檔內容不變;正常安裝後有 `.bak.*` 備份。
- [x] 1.3 Requirement: Dependency and path resolution。缺 `jq` → 報錯 + 安裝提示 + 非零退出;找不到 statusline 腳本 → 報錯;`command` 由 install.sh 自身位置解析為絕對路徑並 `chmod +x`。**驗證**:行為測試 —— 寫出的 `.statusLine.command` 為可執行的絕對路徑。
- [x] 1.4 Requirement: Refresh interval semantics。預設 60;第一位置引數或 `REFRESH_INTERVAL` 環境變數可覆寫(限非負整數,否則報錯);`0` → 建立時省略該鍵、合併時刪除既有 stale 鍵。**行為**:`./install.sh 30` → ri=30;`REFRESH_INTERVAL=0 ./install.sh` → 無 refreshInterval 鍵。**驗證**:行為測試 —— ri=30 情境與 ri 移除情境皆如預期。
- [x] 1.5 Requirement: Refresh cadence interacts with burn sampling。規格記錄 `refreshInterval` 決定 burn 取樣頻率,預設 60 同時滿足「整分鐘顯示粒度」與「burn 取樣間隔 ≥60s 閘」;<~15s 會餓死 burn 警報,~30s 為安全下限。**驗證**:與 rate-burn-projection spec 的 dt≥60 閘一致(交互記錄於規格,非新增 code)。

## 2. 驗證(已通過)

- [x] 2.1 `bash -n install.sh && shellcheck install.sh` 乾淨;install.sh 六情境行為測試(建立 / 合併保留 / 冪等 / `0` 移除 / 非法 JSON 拒絕 / 絕對可執行路徑 + 備份)皆通過;statusline 測試套件維持 `ALL CHECKS PASSED`。
