> 純文件更正:code 早已正確,本 change 只把 token-usage spec 兩處與 code 矛盾的敘述改對,不動任何 code。

## 1. 更正 token-usage 兩處 drift

- [x] 1.1 MODIFY "Cumulative Session Token Display":把段位置由「7 天配額之後、last-message 之前」改為「context meter 之後、5h/7d rate-limit 之前」,並新增一條 scenario 釘住 context→tokens→5h→7d 順序。**驗證**:與 `build_left`(lib/render.sh,ctx→tokens→5h→7d→last-msg)及 CLAUDE.md「Placed before the rate-limit windows」一致。
- [x] 1.2 MODIFY "Non-Blocking Background Summation":把機制由「process substitution 掛專用 FD」改為「detached fire-and-forget 背景 job(`&` + `</dev/null` + stdout/stderr→`/dev/null`),為下一幀重算並改寫快取;前景只讀小快取」,並新增一條 scenario 釘住「detached、非本幀 FD 讀取」。**驗證**:與 `start_tokens_job`/`tokens_update`/`read_tokens`(lib/collect.sh)及 CLAUDE.md「detached background job … rewrites the cache for the next frame」一致。

## 2. 驗證

- [x] 2.1 `spectra validate fix-token-usage-drift` 通過;MODIFIED 兩條 requirement 的 header 與 `openspec/specs/token-usage/spec.md` 逐字相符,archive 時可正確套用。
