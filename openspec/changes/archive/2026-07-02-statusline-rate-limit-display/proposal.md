## Why

有兩份 spec 分別規範 rate-limit 的**值**(`rate-limit-sync`,跨 session 同步)與**警報**(`rate-burn-projection`,`↘` 投影),但實際畫在螢幕上的 rate-limit 段本身 —— 倒數 + 剩餘% + 顏色階 —— 卻無主。`adaptive-layout` 只提到丟棄/收合它。純文件,不改 code。

## What Changes

新增 capability `rate-limit-display`,規範 5h 與 7d 兩個窗口的 base 顯示:
- **倒數前綴**:`fmt_dur(resets_at − now)`,已過則 `0m`。
- **剩餘%**:`100 − used%`,夾為不小於 0。
- **顏色階**:剩餘 >75 GR、>50 YL、>25 OG、其餘 RD。
- **空值**:used% 非數值/空 → 整段不顯示。
- **compact 形式**:丟掉倒數前綴、保留剩餘%(供降級步驟 13;burn 警報內容仍由 `rate-burn-projection` 擁有,此處僅註記它騎在 5h 段內)。

## Non-Goals

- 不改任何 code(`build_rate`/`add_rate`/`ttl` 早已存在)。
- 不重述 burn 警報內容(`rate-burn-projection` 擁有)或跨 session 值同步(`rate-limit-sync` 擁有)。
- 不涉及寬度/降級順序(`adaptive-layout` 擁有)。

## Capabilities

### New Capabilities

- `rate-limit-display`: 5h/7d 窗口的 base 顯示 —— 倒數前綴 + 剩餘%(夾 ≥0)+ 四級顏色階 + 空值靜默 + compact 形式。

### Modified Capabilities

(none)

## Impact

- Affected specs: rate-limit-display (new)
- Affected code: (none — 純文件回溯;行為已存在於 lib/render.sh `build_rate`/`add_rate`/`ttl`)
