> 純文件更正:6 處 spec 敘述改為與 code 一致,不改任何 code。由 9-agent 最終驗證找出,code 為權威。所有任務已完成。

## 1. 更正 6 處 spec 不準(MODIFY)

- [x] 1.1 Requirement: Background Theme Resolution From Config(空/非 light 主題依 STYLE 分支選色,非一律 claude;附帶 Purpose 路徑筆誤更正)。**驗證**:與 `resolve_theme`/`load_palette` case-on-STYLE 一致(預設 STYLE=tokyo-night-claude)。
- [x] 1.2 Requirement: Conditional display of the burn alarm(120m example 改為:兩閘產出 burn_tte,顯示另受 BURN_SENS 上限,balanced 下 120m 隱藏)。**驗證**:與 `build_burn` ceil=6300 及本 spec sensitivity 表一致。
- [x] 1.3 Requirement: Core always remains(唯一永不丟為 ctx%;path best-effort,極窄可犧牲)。**驗證**:與 `render_core_only` pbudget<2 丟 path、CLAUDE.md 一致。
- [x] 1.4 Requirement: Drawable-width invariant(數值上界僅約束正可繪寬;term_cols≤EDGE_PAD 只保證不換行)。**驗證**:與 Z1 測試(不對 ≤0 寬斷言數值上界)一致。
- [x] 1.5 Requirement: Per-segment priority and forms(model 範例 `Opus 4.8(1M)` 無空格)。**驗證**:與 `${model/ (1M context)/(1M)}` 及 Z2 測試一致。
- [x] 1.6 Requirement: Cross-day timestamps include the date(跨日日期前綴補 Δ≥60s 限定)。**驗證**:與 `build_left` 日期分支 gate 在 lm_delta(Δ≥60)一致。

## 2. 驗證

- [x] 2.1 `spectra validate fix-spec-accuracy` 通過(6 條 MODIFIED header 與既有 requirement 逐字相符);`bash tests/run-tests.sh` 維持 `ALL CHECKS PASSED`(未改 code)。
