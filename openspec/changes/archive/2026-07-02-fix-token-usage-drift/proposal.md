## Why

`token-usage` spec 有兩處 normative 敘述與實際 code(及 CLAUDE.md 這份權威架構文件)相矛盾 —— 是 spec 錯、code 對。放著不修,未來 `spectra verify` / `spectra drift` 會把正確的 code 判為違反規格,製造假陽性。本 change 純為文件更正,不改任何 code。

## What Changes

- **更正 token 段位置**:spec 的 "Cumulative Session Token Display" 寫「segment 位於 7 天配額之後、last-message 之前」,但 `build_left`(lib/render.sh)實際把 token 段放在 **context meter 之後、rate-limit(5h/7d)之前**;CLAUDE.md 明載「Placed before the rate-limit windows so the line reads '…ctx · tokens · 5h · 7d · time'」。更正為正確順序。
- **更正背景加總機制**:spec 的 "Non-Blocking Background Summation" 寫「經 process substitution 掛到專用 file descriptor 的背景 job」,但實際 `start_tokens_job` → `tokens_update` 是 **detached fire-and-forget** 背景 job(以 `&` 背景化、`</dev/null` 隔離 stdin、stdout/stderr 導向 `/dev/null`),為**下一幀**重算並改寫快取;前景 `read_tokens` 只讀那份小快取,不在本幀經 FD 讀取。更正機制敘述(非阻塞、stdin 隔離的實質意圖不變,只是機制描述先前寫錯)。

## Non-Goals

- 不改任何 code、不改 token-usage 的其他 requirement、不改任何行為。
- 不新增 requirement,只 MODIFY 上述兩條使其與 code 一致。

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `token-usage`: 更正兩條 requirement 的 normative 敘述(段位置、背景 job 機制),使規格與已 shipped 的 code 一致。

## Impact

- Affected specs: token-usage
- Affected code: (none — 純文件更正,code 已正確)
