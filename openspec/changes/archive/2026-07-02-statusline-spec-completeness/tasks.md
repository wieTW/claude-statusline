> 回溯性文件 change:六份 spec 補描述既有且已測試的行為,不改任何 code。所有任務已完成。

## 1. adaptive-layout(ADD)

- [x] 1.1 Requirement: Right-alignment mode and fallback join (RIGHT_ALIGN)(true→右對齊 term_cols−EDGE_PAD;false 或寬度不可得→ ` │ ` join)。**驗證**:與 `render_line` 一致。
- [x] 1.2 Requirement: EDGE_PAD and JGAP tunable knobs(可調旋鈕語意,交叉引用既有 drawable-width / gap→junction 規則)。**驗證**:與 `render_line` / config 區塊一致。

## 2. last-message-age(MODIFY + ADD)

- [x] 2.1 Requirement: Last-message timestamp with cache-freshness-colored delta(MODIFY:時長主文字條件收緊為 `dur_ms>0`,0/負退回時鐘)。**驗證**:與 `build_left` `[ dur_ms -gt 0 ]` 一致。
- [x] 2.2 Requirement: Time segment omitted when no timestamp inputs are available(ADD:both-empty 省略,唯一擁有此 SHALL)。**驗證**:與段外層 `[ -n last_msg ] || [ -n dur_str ]` 一致。

## 3. context-meter(ADD + MODIFY)

- [x] 3.1 Requirement: CTX_BAR gradient context bar(12 格、四區、TRK 軌、`_pct*12/100` 填格)。**驗證**:與 `build_left` bar 迴圈一致。
- [x] 3.2 Requirement: Context meter text and compact forms(`ctx:N%` full、裸 `N%` compact、`⚑` 附加於全部形式)。**驗證**:與 `build_left` seg_ctx_full/compact 一致。
- [x] 3.3 Requirement: Context segment suppression on absent or non-numeric usage(used% 空/非數值 → 整段含 `⚑` 靜默)。**驗證**:與 `[ -n "$_pct" ]` gate 一致。
- [x] 3.4 Requirement: CTX_BAR configuration knob。**驗證**:與 `CTX_BAR` 分支一致。
- [x] 3.5 Requirement: 200k cost/cache cliff marker(MODIFY:條件加上「present 且 numeric used%」以與 suppression 一致)。**驗證**:與 `ctx_cliff` 在 `_pct` gate 內一致。

## 4. rate-burn-projection(ADD + MODIFY)

- [x] 4.1 Requirement: Burn alarm disabled outright when cross-session sync is off(`RL_SYNC=false` → burn_tte 空、reconcile_read 早退)。**驗證**:與 `reconcile_start`/`reconcile_read` 一致。
- [x] 4.2 Requirement: Sampling and projection are five-hour-window only(7d 從不取樣)。**驗證**:與 `_reconcile_core` awk P-sample(僅 r5)一致。
- [x] 4.3 Requirement: Configurable sensitivity knob(MODIFY:balanced=6300s/105m、conservative=1800s/30m、sensitive 無額外上限)。**驗證**:與 `build_burn` ceil 常數一致。
- [x] 4.4 Requirement: Burn projection end-to-end result matrix(MODIFY:精確常數對齊)。**驗證**:與 `build_burn` 門檻一致。

## 5. rate-limit-sync(ADD)

- [x] 5.1 Requirement: Burn-projection sample series persists as a third cache line type(`P <resets_at> <ts> <used>`、≤5/窗、~10800s;read-only 路徑保留 P 行)。**驗證**:與 `_reconcile_core` awk P 處理一致。
- [x] 5.2 Requirement: RL_SYNC master toggle gates the entire reconciliation。**驗證**:與 `reconcile_start`/`reconcile_read` 早退一致。
- [x] 5.3 Requirement: A stale reconcile lock is stolen and re-acquired(> RL_LOCK_STALE)。**驗證**:與 `_reconcile_core` mkdir-lock steal 一致。
- [x] 5.4 Requirement: Expired reset windows are pruned on rewrite(resets_at ≤ now 的 W/P 丟棄)。**驗證**:與 awk 剪除一致。
- [x] 5.5 Requirement: Malformed and old-format cache lines are silently dropped。**驗證**:與 awk 只保留合法 S/W/P 一致。

## 6. token-usage(ADD)

- [x] 6.1 Requirement: Per-Message Deduplicated Summation(依 `.message.id` 去重,避免 ~10x 超計)。**驗證**:與 `_sum_inout` 一致。
- [x] 6.2 Requirement: On-Disk Token Cache Schema And Atomic Rewrite(`T <sid> ...` 行、temp+mv)。**驗證**:與 `tokens_update`/`read_tokens` 一致。
- [x] 6.3 Requirement: Single-Flight Background Recompute(mkdir 鎖、30s stale-steal)。**驗證**:與 `tokens_update` 鎖一致。
- [x] 6.4 Requirement: Cross-Session Cache Pruning(依 `RL_REG_TTL` 剪 `T` 行)。**驗證**:與 `tokens_update` awk prune 一致。
- [x] 6.5 Requirement: Token Segment Colouring(session WH / subagent YL / `⊂` DM)。**驗證**:與 `build_left` token 段一致。

## 7. 驗證

- [x] 7.1 `spectra validate statusline-spec-completeness` 通過(MODIFIED header 與既有 requirement 逐字相符);`bash tests/run-tests.sh` 維持 `ALL CHECKS PASSED`(未改 code)。
