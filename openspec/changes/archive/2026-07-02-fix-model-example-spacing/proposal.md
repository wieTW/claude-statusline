## Why

`adaptive-layout` 另有兩處 model full-form 範例仍寫 `Opus 4.8 (1M)`(paren 前有空格),與 code(`${model/ (1M context)/(1M)}` 吃掉空格 → `Opus 4.8(1M)`)及 Z2 測試不符。與 fix-spec-accuracy 已修正的同類缺陷一致,補齊剩餘兩處(在 Fixed sacrifice order 與 Shrink and truncate preferred over drop 兩條 requirement 內)。純文件、不改 code。

## What Changes

- **`adaptive-layout` / Fixed sacrifice order**:step 9 範例 `Opus 4.8 (1M)` → `Opus 4.8(1M)`。
- **`adaptive-layout` / Shrink and truncate preferred over drop**:example GIVEN `Opus 4.8 (1M)` → `Opus 4.8(1M)`。

## Non-Goals

- 不改 code、不改其他任何內容(僅移除範例中的一個空格,兩處)。

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `adaptive-layout`: 更正兩條 requirement 內的 model full-form 範例間距。

## Impact

- Affected specs: adaptive-layout
- Affected code: (none)
