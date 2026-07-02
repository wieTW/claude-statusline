> 回溯性文件 change:主題調色盤為既有行為(lib/render.sh `load_palette`、lib/collect.sh `resolve_theme`/`start_theme_job`/`read_theme`),本 change 只補規格,不改 code。所有任務已完成。

## 1. 規格化主題系統

- [x] 1.1 Requirement: Dark Theme Style Selection(`STYLE` 在五個暗色主題間選擇,各為完整角色映射)。**驗證**:與 `load_palette` case 分支一致。
- [x] 1.2 Requirement: Colour Role Semantics(WH/MD/CY/GR/YL/OG/RD/DM/SP/RD_DATA/TRK 各角色語意)。**驗證**:與 `load_palette` 角色指派一致。
- [x] 1.3 Requirement: Light Theme Fixed Palette(主題名含 `light` → 固定亮色調色盤,不理會 STYLE)。**驗證**:與 `load_palette` `*light*` 分支一致。
- [x] 1.4 Requirement: Background Theme Resolution From Config(`~/.claude/.claude.json` → `settings.json` .theme、背景 job、不消耗 stdin、torn 降級)。**驗證**:與 `resolve_theme`/`start_theme_job`/`read_theme` 一致。

## 2. 驗證

- [x] 2.1 `spectra validate statusline-theme-palette` 通過;`bash tests/run-tests.sh` 維持 `ALL CHECKS PASSED`(未改 code)。
