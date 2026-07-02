## Why

每一個上色的 segment 都依賴一組調色盤角色(WH/MD/CY/GR/YL/OG/RD/DM/SP/RD_DATA/TRK),但「這些角色從哪個主題來、有哪些主題、亮色主題如何覆蓋、active 主題怎麼解析」完全沒有 spec —— 既有各 spec 只抽象引用角色名。這是跨所有顯示的載重能力。純文件,不改 code。

## What Changes

新增 capability `theme-palette`:
- **`STYLE` 旋鈕**:在五個暗色主題間選擇 —— `claude`(預設)、`tokyo-night`、`tokyo-night-claude`、`catppuccin`、`rose-pine`;每個是一組完整角色映射。
- **亮色覆蓋**:主題名含 `light` 時,一律使用固定的亮色調色盤,不理會 STYLE。
- **主題解析**:active 主題讀自 `~/.claude/.claude.json` 的 `.theme`,退回 `~/.claude/settings.json` 的 `.theme`(預設 `dark`),在不消耗 stdin 的背景 job 中解析;torn/非法讀取以退回鏈降級,僅影響一幀。

## Non-Goals

- 不改任何 code(`load_palette` / `resolve_theme` 早已存在)。
- 不規範各角色的精確 RGB 值(易變的美學細節),只規範角色語意與主題選擇/亮暗覆蓋/解析來源。
- 不涉及哪個 segment 用哪個角色(`display-segments` 等各自的 spec 擁有)。

## Capabilities

### New Capabilities

- `theme-palette`: `STYLE` 主題選擇、五個暗色主題的角色映射、亮色固定覆蓋、以及 active 主題的解析來源與降級。

### Modified Capabilities

(none)

## Impact

- Affected specs: theme-palette (new)
- Affected code: (none — 純文件回溯;行為已存在於 lib/render.sh `load_palette`、lib/collect.sh `resolve_theme`)
