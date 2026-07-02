> 純文件更正:移除兩處 model 範例的空格使其與 code/Z2 測試一致,不改 code。

## 1. 更正範例間距(MODIFY)

- [x] 1.1 Requirement: Fixed sacrifice order(step 9 範例 `Opus 4.8(1M)` 無空格)。**驗證**:與 `${model/ (1M context)/(1M)}` 及 Z2 一致。
- [x] 1.2 Requirement: Shrink and truncate preferred over drop(example `Opus 4.8(1M)` 無空格)。**驗證**:與 Z2 一致。

## 2. 驗證

- [x] 2.1 `spectra validate fix-model-example-spacing` 通過;`bash tests/run-tests.sh` 維持 `ALL CHECKS PASSED`。
