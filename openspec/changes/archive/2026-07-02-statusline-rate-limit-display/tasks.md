> 回溯性文件 change:rate-limit base 顯示為既有行為(lib/render.sh `build_rate`/`ttl`/`fmt_dur`),本 change 只補規格,不改 code。所有任務已完成。

## 1. 規格化 rate-limit base 顯示

- [x] 1.1 Requirement: Rate-Limit Window Segment Content(倒數前綴 `fmt_dur(resets−now)`、已過 `0m`、剩餘% `100−used` 夾 ≥0,5h/7d 皆適用,由 `build_left` inline append)。**驗證**:與 `build_rate`/`ttl` 一致。
- [x] 1.2 Requirement: Remaining-Percentage Colour Ladder(>75 GR / >50 YL / >25 OG / else RD)。**驗證**:與 `build_rate` color 分支一致。
- [x] 1.3 Requirement: Empty Segment On Non-Numeric Used Percentage(used% 空/非數值 → 整段不顯示)。**驗證**:與 `build_rate` `_pct` 空值早退一致。
- [x] 1.4 Requirement: Compact Form Without Countdown(丟倒數、留剩餘% + 任何 burn 警報)。**驗證**:與 `_rate_compact` 一致。

## 2. 驗證

- [x] 2.1 `spectra validate statusline-rate-limit-display` 通過;`bash tests/run-tests.sh` 維持 `ALL CHECKS PASSED`(未改 code)。
