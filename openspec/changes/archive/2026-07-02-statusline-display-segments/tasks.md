> 回溯性文件 change:九個 base segment 的內容與顏色皆為既有行為(lib/render.sh `build_left`/`build_right`、lib/collect.sh `collect_status`/`effort_scan`),本 change 只補規格,不改 code。所有任務已完成。

## 1. 規格化 base segment 的內容與顏色

- [x] 1.1 Requirement: Path Segment Content and Colour(專案相對名 / basename / `/` 根、CY+BOLD)。**驗證**:與 `build_left` display_dir 推導一致。
- [x] 1.2 Requirement: Model Name Segment Content and Colour(MD 色、`(1M context)`→`(1M)`、首字 compact)。**驗證**:與 `build_left` model 段一致。
- [x] 1.3 Requirement: Effort Segment Content, Mode Recovery, and Colour(五級顏色、ultra/auto、`effort_scan` 回復 mode)。**驗證**:與 `build_left` effort 段 + `effort_scan` 一致。
- [x] 1.4 Requirement: Thinking Indicator Segment(僅異常顯示、`NORM_THINKING` 反轉、缺值靜默)。**驗證**:與 `build_left` thinking 段一致。
- [x] 1.5 Requirement: Git Branch Segment(detached short sha、`*` tracked OR untracked、WH、再清理)。**驗證**:與 `collect_status`/`collect_all` + `build_right` 一致。
- [x] 1.6 Requirement: Git Diffstat Segment(`+N` GR / `-N` RD_DATA / `/` SP、排除 untracked)。**驗證**:與 `build_right` git_seg 一致。
- [x] 1.7 Requirement: Worktree Segment(`[wt:NAME]`、DM)。**驗證**:與 `build_right` worktree 段一致。
- [x] 1.8 Requirement: Session Name Segment(DM、最右)。**驗證**:與 `build_right` session 段一致。
- [x] 1.9 Requirement: Inter-Segment Separator(` │ ` SEP、SP/DM 結構灰)。**驗證**:與 `render_line` SEP / `join_parts` 一致。

## 2. 驗證

- [x] 2.1 `spectra validate statusline-display-segments` 通過;`bash tests/run-tests.sh` 維持 `ALL CHECKS PASSED`(未改 code)。
