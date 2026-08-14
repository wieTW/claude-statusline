## Why

statusline 的 ctx% 目前直接顯示上游 `context_window.used_percentage`: 分子只算 input 加 cache token、分母是完整 context window。Claude Code 自己的「Context low (N% remaining)」警示卻是另一套口徑: 分子含 output tokens、分母扣掉 20000 token 的輸出保留區（CC 2.1.232 binary 常數，2026-08-14 靜態實證）。兩套口徑在接近滿載時相差約 2 個百分點: 實例是 statusline 顯示 96%（剩 4%）的同一時刻，系統跳出「Context low (2% remaining)」，使用者對讀數失去信任。上游已把同型回報判 closed as not planned，不會修，只能在 statusline 端對齊。

## What Changes

- ctx% 的數值來源從「直接顯示 `used_percentage`」改為「本地計算警示口徑百分比」: 分子 = `current_usage` 的 input_tokens 加 cache_creation_input_tokens 加 cache_read_input_tokens 加 output_tokens；分母 = `context_window_size` 減 20000（輸出保留區）；顯示值與警示的 remaining% 恰為 100 互補，並 clamp 到 0 至 100。顯示語意仍為 used%。
- `parse_input` 新增五個數值欄位（current_usage 的四個 token 數與 context_window_size），照既有 positional read 契約附加。
- 新欄位缺席或非數值（舊版 CC、分母非正值）時 fallback 回既有 `used_percentage` 行為；整段 suppression 規則（兩來源皆無數值才整段隱藏）維持原設計精神。
- 輸出保留常數 20000 以具名常數置於 statusline-command.sh 頂部設定區並附來源註解（CC 2.1.232 binary 實證值，隨 CC 版本可能漂移），不做 README 級 config knob。
- 80% 與 92% 的 budget-aware 紅色門檻數值不變，僅輸入值改為對齊口徑後的百分比。
- tests/run-tests.sh 的 CTX 節補上對齊口徑計算與 fallback 路徑的測試；README.md、CLAUDE.md 的 context meter 說明與 README 截圖（assets/generate.sh 產物）同步更新。

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `context-meter`: 百分比的取值來源從上游 `used_percentage` 原值改為警示口徑的本地計算值（含 fallback 與 suppression 的輸入定義修改）；紅色門檻與 cliff marker 的既有 requirement 僅輸入值語意連動、門檻數值與獨立性不變。

## Impact

- Affected specs: openspec/specs/context-meter/spec.md（delta: 新增百分比來源 requirement、連動修改 suppression 的數值在場判準）
- Affected code:
  - Modified:
    - statusline-command.sh
    - lib/collect.sh
    - lib/render.sh
    - tests/run-tests.sh
    - README.md
    - CLAUDE.md
  - New: 無
  - Removed: 無
- 產物同步: assets/generate.sh 重產 README 截圖 SVG（顯示會變的變更照 repo 慣例必重產）。
