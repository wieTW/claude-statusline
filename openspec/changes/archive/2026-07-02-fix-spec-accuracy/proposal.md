## Why

補完顯示基線後,一輪 9-agent 的最終 adversarial 驗證(逐份 archived spec 對照 code 試圖證偽)找出 6 處 spec 敘述與 code 不符 —— 全部是 spec 錯、code 對。其一是本 session 的 fix pass 自己引入的(theme 空值→claude palette 的過度斷言);其餘五處是 Spectra 導入前原始 spec 的潛在不準,被這次完整化順帶照出。放著會讓 `spectra verify` 把正確 code 判為違規。本 change 修正這 6 處使規格與 code 一致,純文件、不改 code。

## What Changes

- **`theme-palette` / Background Theme Resolution From Config**:空/非 `light` 主題並非「一律 claude palette」,而是依 `STYLE` 分支(預設 `tokyo-night-claude`);僅 STYLE 未設/不認得時 catch-all 才是 claude。改為委派 STYLE 選色。(附帶:Purpose 內 `~/.claude/.claude.json` 筆誤已直接更正為 `~/.claude.json`。)
- **`rate-burn-projection` / Conditional display of the burn alarm**:某 example 宣稱 120m 投影「兩閘通過 → 顯示」,但 balanced 預設上限 6300s(105m)會隱藏 120m,且與本 spec 的 sensitivity 表(balanced|120m|hidden)自相矛盾。改為:兩道強制閘只保證產出 burn_tte,最終顯示另受 BURN_SENS 上限管制,balanced 下 120m 隱藏。
- **`adaptive-layout` / Core always remains**:誤保證 path basename 與 ctx% 皆永不丟;實際 `render_core_only` 在極窄寬度會丟掉 path、只留 ctx%(CLAUDE.md 亦然)。改為:唯一永不丟的是 ctx%,path 為 best-effort、極窄時可被完全犧牲以保住 %。
- **`adaptive-layout` / Drawable-width invariant**:數值上界「不超過 term_cols−EDGE_PAD,含 1–2 欄」在 term_cols ≤ EDGE_PAD(可繪寬 ≤0)時不可能成立(最小字符 `…` 佔 1 格)。改為:數值上界僅約束正可繪寬;term_cols ≤ EDGE_PAD 時只保證單行不換行。
- **`adaptive-layout` / Per-segment priority and forms**:model full 形式範例 `Opus 4.8 (1M)`(paren 前有空格)與 code(`${model/ (1M context)/(1M)}` 吃掉空格→`Opus 4.8(1M)`)及 Z2 測試不符。改為無空格。
- **`last-message-age` / Cross-day timestamps include the date**:跨日日期前綴的斷言無 Δ 條件,但 code 把日期分支 gate 在 Δ≥60s;跨午夜但 <60s 不加前綴。補上「僅當 Δ 顯示(lm_age≥60s)」限定。

## Non-Goals

- 不改任何 code(6 處皆 spec 錯 code 對)。
- 不新增/移除 requirement,只 MODIFY 上述 6 條使其與 code 一致。

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `theme-palette`: 更正主題解析的 palette 選擇敘述(委派 STYLE)。
- `rate-burn-projection`: 更正 burn 顯示 example 的 sensitivity 上限矛盾。
- `adaptive-layout`: 更正 core 保證(僅 ctx%)、drawable-width 上界(僅正寬)、model 範例空格。
- `last-message-age`: 補跨日日期前綴的 Δ≥60s 限定。

## Impact

- Affected specs: theme-palette, rate-burn-projection, adaptive-layout, last-message-age
- Affected code: (none)
