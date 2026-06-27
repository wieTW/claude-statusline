## Context

statusline 是高度優化的 bash 3.2 腳本。跨 session 速率同步(reconcile)與燃燒投影(burn)邏輯集中在 `lib/collect.sh` 的 `_reconcile_core`(含一段內嵌 awk),設定旋鈕在 `statusline-command.sh` 頂部。本 change 在不改既有規則、不加延遲、不做重構的前提下,補三個會導致「顯示錯數字」的守衛。硬約束:bash 3.2、禁用 set -e、背景 job 一律保留 `</dev/null`、`LC_ALL=C` 釘住、`parse_input` 位置對應 read 順序不得更動。

## Goals / Non-Goals

**Goals:**

- 三個守衛:reconcile 覆寫前需非空暫存檔、burn 投影需 `dt>=60`、`RL_REG_TTL` 載入時 clamp 至下限。
- 三項各自的回歸測試,完整 gate 全綠。

**Non-Goals:**

- 任何速度/延遲優化(git overlap、theme jq 合併、token-job 移位)。
- 任何大型重構(parse_input key-keyed、抽 reconcile awk、degrade 命名常數等)。
- 改動既有規則:reconcile「最新 session 為權威」、burn 既有兩道閘(slope 為正、投影耗盡早於 reset)、`RL_REG_TTL` 預設值 604800。

## Decisions

- **mv 守衛用 `[ -s "$tmpfile" ]`,不用 `[ -n "$out" ]`**:直接驗證即將上線的檔案本身非空,同時涵蓋「awk crash 留下空檔」與「只寫半截」;`$out` 非空不保證 tmpfile 完整。守衛只 gate `mv`,既有的 lock + 非空 session_id 條件保留(疊加而非取代);read-only frame(無鎖或空 sid)本就走 `rm` 分支,不受影響。
- **burn 閘放在 awk 內(`dp>0 && dt>=60`),不放 render 端**:既有兩道閘都在同一段 awk END,`dt` 在那裡才有 `pt0/pt1` 可算;放 render 端需多傳一個值並破壞單一真相。閾值取 inclusive 60,因為現有 Y4 row 6 是合法的 `dt` 約等於 60 秒紅警報,`>60` 或 `>=120` 會誤殺它。
- **`RL_REG_TTL` clamp 放在 config 區塊之後、source lib 之前**:一次性 `[ ]` builtin、零 fork;floor-only(大於 604800 者保留)讓未來更長視窗仍可設定;非數值一律歸 604800,順手擋掉「awk 收到非數值 regttl 時把所有 S 行判為過期而全部剪除」的更糟路徑。

## Implementation Contract

- **行為**:(a) awk 不成功的 frame 不再清掉 `~/.claude/sl-ratelimit-cache`,且該 frame 仍顯示其讀到的權威值;(b) 兩取樣點實際間隔小於 60 秒時不顯示 `↘`,大於等於 60 秒且既有閘通過時行為不變;(c) `RL_REG_TTL` 生效值恆不小於 604800。
- **介面/資料形狀**:`_reconcile_core` 仍輸出 `<five>|<seven>|<burn_tte>`;快取行 S/W/P 格式不變;旋鈕名稱 `RL_REG_TTL` 不變。三守衛皆不改任何對外契約。
- **失敗模式**:三守衛皆為靜默安全降級 — 無鎖、awk 失敗、空檔、非數值設定皆保留現況、不報錯、不 set -e。
- **驗收**:`tests/run-tests.sh` 中 T/T2 段(空檔不蓋快取)、Y 段(2 秒爆發無警報 + dt=60 仍警報)、T 段(undersized 與非數值 TTL 皆 clamp)斷言皆印出 OK;`bash -n statusline-command.sh && bash -n lib/collect.sh && bash -n lib/render.sh`、`shellcheck -x statusline-command.sh`、`bash tests/run-tests.sh` 皆 exit 0,末行 `ALL CHECKS PASSED`。
- **範圍邊界**:in scope = `lib/collect.sh`、`statusline-command.sh`、`tests/run-tests.sh` 三檔上述守衛與測試;out of scope = 其餘所有行為、效能與重構。

## Risks / Trade-offs

- [閾值 60 被改或誤設] → spec 與 task 皆標註「load-bearing、inclusive 60」,以 Y4 row 6 作為回歸守門。
- [mv 守衛在正常空快取情境誤判] → 正常 frame 的 awk 必至少輸出自身 S/W 行,tmpfile 不會為空;唯一的空檔來源是 awk 失敗,正是要擋的對象。
- [clamp 改變使用者顯式設定] → 僅向上 clamp 至視窗長度(footgun 區間),大於 604800 不動;於 CLAUDE.md 與 spec 記錄此 floor 語意。
