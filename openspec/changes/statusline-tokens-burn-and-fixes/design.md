## Context

Claude Code 透過 stdin 餵一段 status JSON 給 `statusline-command.sh`,腳本在 stdout 印出**單行**著色狀態列。架構為入口 `statusline-command.sh`(只放 config 與主流程),它 source 兩個模組:`lib/collect.sh`(stdin JSON 解析 + 以 process substitution 開 FD 跑的併發背景 job:theme / width / git / effort,以及 `reconcile_rates` 跨 session rate-limit 同步)與 `lib/render.sh`(調色盤 + 右對齊單行組裝,`render_line` 內含依寬度分級降級)。整條流程的設計目標是**永不超過可繪寬度**、**每幀 wall-clock ≈ 最慢的單一 job(約 20ms)**,並維持 collect→render 之間的全域變數契約。

本變更要在不違反任何硬規則的前提下,補齊兩個對重度使用者最關鍵的可見度缺口(累計 token 消耗、額度燃燒見底預警),並修正三個既有正確性問題(跨 session rate-limit 同步的 lost-update 競態、context 警示沿用寫死 80% 門檻、跨日「上次訊息」時鐘),外加數項無觀感變化的內部強化(parse_input 位移防呆、reconcile 背景化、去重重構)。

必須尊重的硬規則(本設計與其互動關係逐項標註於下方各決策):**絕不 `set -e`**;**每個背景 job 都從 `/dev/null` 導入 stdin**(只有 `parse_input` 的 jq 可消費 stdin JSON);**`LC_ALL=C` 釘住**(同時修 `%.0f` 小數格式並讓 `${#x}` 按 byte 計數,`vis_width` 的 cell 數學依賴此);**`parse_input` 是唯一的外部字串消毒入口**,其 `read` 順序與 jq 陣列**位置一一對位**;**256 codepoint 上限是承重設計**(`vis_width` 的 ASCII strip 在 bash 3.2 下為 O(n²),無上限的多 KB 欄位會卡死每一幀);**jq 控制字元過濾用 `explode`/`implode` 而非 regex**;**目標 bash 3.2**,不得用 bash-4+ 特性。

驗收門檻(acceptance gate,沿用既有 verify gate):三個 `.sh` 檔各自 `bash -n` 通過 + `shellcheck -x statusline-command.sh` 通過(會跟著 `. ` source) + `bash tests/run-tests.sh` 印出 `ALL CHECKS PASSED`。

實測佐證(本設計撰寫前在本機量得):transcript usage 物件確含 `input_tokens` / `output_tokens` 與獨立的 `cache_creation_input_tokens` / `cache_read_input_tokens` / `cache_creation`;主 transcript 與 subagent 的對位關係為 `projects/<encoded-cwd>/<sid>.jsonl` 與其同層 `projects/<encoded-cwd>/<sid>/subagents/agent-*.jsonl`;對約 3MB(主 1.7MB + 11 個 subagent 共 1.3MB)做一次 in+out 全量加總約 28ms,線性外推 ~6MB 約 60ms。

## Goals / Non-Goals

**Goals**

- 在左側顯示本 session 的 input+output 累計 token(不含 cache),有 subagent 時追加 subagent 累計;加總在背景跑、前景只讀快取,**永不阻塞單幀**。
- 新增 rate-limit 燃燒投影警報:依近期消耗速度,僅在「正在消耗且會在 reset 前見底」時於 quota 旁顯示倒數警報,平時隱形。
- 為 `render_line` 既有的分級階梯**擴充**出更細的固定犧牲順序(先縮短/截斷,後依優先級丟棄,核心永遠保留),而非取代它。
- 修正 `reconcile_rates` 在多 session 併發 render 下的 lost-update 競態,並讓空 session_id 不做破壞性整檔改寫;同時把 reconcile 背景化以省去每幀的序列成本。
- context 警示改用 `context_window_size` / `exceeds_200k_tokens` 判斷,取代寫死的 80% 門檻。
- 跨本地日曆日時於「上次訊息」時間前補上日期。
- parse_input 位移耦合防呆(欄位編號註解 + sentinel 測試)、抽出重複的時間格式化與溢位保護邏輯(behavior-preserving)。

**Non-Goals**

- 不改 collect→render 的全域變數契約形態(仍以 `WRITES:` / `READS:` header 為真實來源);只新增欄位,不重排既有讀取順序的觀感語意。
- 不引入 wcwidth 表;`vis_width` 的過估方向(只會讓 gap 縮、不會撐爆換行)仍是可接受限制。
- 不改 rate-limit 同步的「最新 session 為權威」核心規則(只修競態與空 session 與背景化)。
- 不放寬 256 codepoint 上限、不引入 bash-4+ 特性、不在任何地方加 `set -e`。
- 不解析 CC 真正的 cache 狀態(無此欄位可達);last-message 顏色仍只是依 Δ 的快取新鮮度推測。
- token 數不嘗試還原「真正花的錢」(cache 寫入成本不計入,見下方決策的取捨)。

## Decisions

### Token 加總背景化與快取格式

新增一個背景 FD job(沿用既有併發模型:`exec N< <( … </dev/null )`,read 即 sync point),對主 transcript(來自 stdin 解析出的 `transcript_path`)與其同層 `subagents/agent-*.jsonl` 做 in+out 加總,結果寫入使用者 `.claude` 目錄下的快取檔(仿 `sl-ratelimit-cache`),**前景只讀快取**。為避免每幀都重算,以**檔案 size/mtime 為 gate**:只有當主 transcript 或 subagents 目錄的 size/mtime 與快取記錄不同時,背景才真正重跑全量加總;沒變化就直接沿用快取數字,前景零等待。

快取行格式(單檔,行為純文字、欄位空白分隔,與 rate-limit 快取同風格):

```
T <sid> <session_tokens> <subagent_tokens> <main_size> <main_mtime> <sub_size> <sub_mtime>
```

- `<sid>` = 本 session id(快取對應的 session;不同 session 各一行,torn/old-format 行於重寫時不帶過)。
- `<session_tokens>` / `<subagent_tokens>` = 兩個整數累計值(見下一決策定義)。
- `<main_size>/<main_mtime>` 與 `<sub_size>/<sub_mtime>` = gate 用的尺寸/時間戳;subagents 目錄以「該目錄下 agent-*.jsonl 的總 size + 最新 mtime」表示,兩者任一改變即觸發重算。

**Rationale**:size/mtime gate 讓全量加總(實測 ~60ms over ~6MB)只在內容真的變動時於背景發生,平時前景讀一行快取即可,完全不進熱路徑。沿用 rate-limit 快取的純文字單檔風格,維護一致、好除錯、parse 零相依。

**Alternatives**:(a) 每幀現算 — 直接違反「永不阻塞單幀」與 60ms 成本,否決;(b) 用 SQLite / 結構化格式 — 對 bash 3.2 過重且增加相依,否決;(c) 只記偏移量做增量加總 — JSONL 可能被壓縮重寫使偏移失效,size/mtime gate 已足夠且更穩,列為後續優化(見 Risks 的 per-file memoize)。

### Token 數定義(in+out,不含 cache)

`session_tokens = sum(input_tokens + output_tokens)`,逐行掃主 transcript 的 `usage` 物件相加;`subagent_tokens` 對所有 `agent-*.jsonl` 同法加總。顯示時:本 session 累計恆顯示;subagent 累計**僅在 `subagent_tokens > 0` 時**以 `⊂` 形式追加(零 subagent 不佔版面)。

關鍵:**in+out 刻意排除 cache 欄位**(`cache_creation_input_tokens` / `cache_read_input_tokens` / `cache_creation`)。這使得數字在 prompt cache 過期/重寫時**穩定**——cache churn 落在 `cache_creation`,不會灌進 `input_tokens`,所以同一段對話的 in+out 不會因為 cache 到期被重新計算而忽高忽低。

**Rationale**:重度使用者要看的是「這場對話實際送進/吐出的內容量」這個穩定指標,in+out 正是不受 cache 生命週期干擾的那條線;實測 usage 物件確實把 cache 與 in/out 分開存放,定義可直接落地。

**Alternatives**:(a) 計入 cache_read 以反映「總 context 規模」 — 數字會隨 cache 命中劇烈跳動,對「我打了多少」的直覺反而失真,否決;(b) 計入 cache_creation 以反映真實花費 — 見下方取捨,本設計選擇穩定性優先,把成本可見度列為已知 trade-off。

### 燃燒投影取樣與斜率

在 rate-limit 快取中**追加有界的取樣行**,每幀記下 `(timestamp, 採用後的 used%)`(採用後 = 經 reconcile 同步後的權威值,見下方「取樣 reconciled 值」的理由)。投影以 2 點或平滑後斜率估算:取最舊與最新取樣求斜率,或對近 N 點做平滑以抑制抖動。**警報條件**:`slope > 0`(正在消耗)**且**依該斜率外推會在 `resets_at` 之前見底(used% 達 100)。緊迫度以「距見底時間」著色,`<= 30m` 視為緊迫(紅);敏感度旋鈕預設取平衡值(balanced),可調鬆/緊。

取樣行格式(同檔追加,有界保留;舊/torn 行重寫時丟棄):

```
P <resets_at> <timestamp> <used>
```

每個 reset window 各自保留一小段最近取樣(超量則丟最舊),供斜率計算。

**Rationale**:把取樣寄生在既有 rate-limit 快取裡,複用其原子 mv 與 prune 機制,零新檔、零新 job;只在「真的會在 reset 前見底」才出聲,平時隱形,符合本狀態列「異常才顯示」的一貫語意。

**Alternatives**:(a) 用 CC 直接給的 used% 瞬時值 — 凍結問題下根本不動,投不出斜率,否決;(b) 線性回歸全歷史 — bash/awk 實作過重且對近期突發消耗反應遲鈍,2 點/平滑斜率已足夠且便宜;(c) 固定門檻警報(如 used>90 才喊) — 無法回答「來不來得及」,被燃燒投影取代。

### 壓縮排版犧牲順序

定義一條**固定 14 步**的降級順序,擴充(而非取代)`render_line` 既有的 tier ladder(roomy whitespace gap → 插 `│` junction → head-truncate 右半 → 丟右半並截左半)。原則:**先縮短/截斷,再丟棄**;依優先級丟棄是最後手段;**核心(path + ctx%)永遠保留**。各區段定義「緊湊/完整」兩形態與優先級,終端變窄時自最低優先級開始,先把可縮的縮(如 token 段切緊湊、收掉 junction、截 session name 尾),都不夠才依優先級丟整段,最末才動到核心的截斷。

**Rationale**:既有 render_line 已是分級階梯且帶完整的寬度安全性(perl 截斷 + 純 bash 退化、UTF-8 邊界處理、`avail` 負值容錯);本決策只是把「新增的 token / burn 段」掛進同一條階梯並把粒度做細,沿用既有的 `vis_width` / `trunc_head` 與「永不超過可繪寬度」的不變式,風險最低。

**Alternatives**:(a) 重寫一套排版引擎 — 丟棄既有久經測試的寬度安全性,風險高,否決;(b) 新段固定不參與降級(永遠顯示或永遠先丟) — 與「核心優先、漸進犧牲」的目標相悖,否決。

### reconcile 併發鎖與空 session 跳過

在 reconcile 的「讀 + awk + mv」整段外加一把 **`mkdir` 自旋鎖**(stock macOS 無 `flock`,`mkdir` 是 POSIX 原子建目錄,做鎖最穩),帶**有界重試**;若鎖目錄的 mtime 過舊(持鎖者已死)則**偷鎖**(staleness steal)。**取鎖失敗 → `return 0`**(degrade safe:保留本幀自身值,不寫快取)。**空 session_id → 跳過 mv**(read-only adopt:仍可讀快取採用既有權威值,但不做破壞性整檔重寫,因為無法被排名、寫回只會徒增競態風險)。

**Rationale**:現況「讀→awk→mv」非原子,多 session 同幀重寫會 lost update;`mkdir` 鎖把臨界區序列化,有界重試 + 偷鎖避免死鎖。`return 0` 而非報錯,完全契合「絕不 `set -e`、退化即可」的硬規則。空 session 本就無法當權威,跳過寫入既修了破壞性改寫又少一個競態來源。

**Alternatives**:(a) `flock` — macOS 系統無此工具,否決;(b) 樂觀重試/CAS by 比對檔內容 — 在多寫者下仍可能交錯,且 bash 實作繁瑣,`mkdir` 鎖更簡潔可靠;(c) 直接 `O_APPEND` 追加不重寫 — 無法 prune 過期行、檔案無限增長,否決。

### reconcile 背景化(效能)

把 reconcile 改成一個**背景 FD job**,與 git 階段重疊執行,移除其每幀約 3ms 的序列成本;結果經 FD read 取回後再覆寫 `five_h` / `seven_d`。job 內仍嚴格遵守 **`</dev/null` 硬規則**(reconcile 不讀 stdin JSON,只讀寫快取檔),避免偷走 stdin 管線。

**Rationale**:reconcile 是純檔案 I/O + awk,天生適合丟進既有併發模型與 git×3 重疊;wall-clock 仍 ≈ 最慢 job,等於把這 3ms 藏進既有空檔。與上一決策的 `mkdir` 鎖正交——鎖保證臨界區安全,背景化只是把它移出主執行緒。

**Alternatives**:(a) 維持前景序列 — 白付 3ms/幀,否決;(b) 完全非同步、不等結果本幀顯示 — 會讓本幀顯示落後一拍且打亂 read-order 契約,選擇「背景跑、本幀仍 read 回」以維持確定性。

### context 門檻改用 context_window_size / exceeds_200k_tokens

把 ctx% 警示由寫死的 `> 80%` 紅字,改成依 JSON 提供的 `context_window_size`(視窗大小)/ `exceeds_200k_tokens` 旗標判斷。對 200k 與 1M context 模型都能給出合理的接近上限警示,而非對 1M 模型在 80% 處就誤報。此欄位經 `parse_input` 解析(新增欄位,見下方位移防呆決策),fmt_pct 與 ctx bar 邏輯沿用。

**Rationale**:寫死 80% 是對固定 200k 視窗的假設;1M 模型下 80% 仍有極大餘裕,誤報破壞信任。改用視窗大小/旗標讓門檻隨模型自適應。

**Alternatives**:(a) 依 model display name 推視窗大小 — 字串脆弱、易隨命名變動失準,否決;(b) 維持 80% 並只對 1M 模型特判 — 仍是寫死,擴充性差,改用 CC 已提供的結構化欄位最穩。

### 跨日時鐘修正

「上次訊息」目前只存/顯示 `HH:MM`,昨天的 prompt 會被當成今天。修正:當 last-message 的本地日曆日與當前本地日曆日**不同**時,於時間前補上日期前綴(如 `MM-DD HH:MM`)。判跨日用 `date -r <epoch>` 直接把 UTC epoch 格式化成**本地日曆日**比對(BSD/macOS,免手動 offset、DST 正確);此 fork **gated 在 Δ ≥ 60s** 之後才執行,確保 sub-minute(必為同日)情境**零 fork**。

**Rationale**:跨日誤導是真實正確性 bug;每幀多一個 `date` fork 不可接受,故用 Δ 當廉價前置條件。**門檻是 Δ ≥ 60s,不是 Δ ≥ 1h**——因為比的是「本地日曆日是否相異」而非固定 24h 年齡(spec 已明訂),23:50→00:10 的跨午夜情境 Δ 僅 20m 卻必須補日期前綴(見 spec last-message-age 的 normative scenario「cross-midnight prompt under one hour」)。只有 sub-minute 訊息可確定同日 → 維持熱路徑對該常見情境零 fork。

**Alternatives**:(a) 每幀都取 offset 判跨日 — 多餘 fork,否決;(b) 讓 hook 直接寫完整日期 — 需改 hook 且對既有未重寫的 last-msg 檔不相容,本設計在 statusline 端處理並保留對舊格式的向後相容。

### parse_input 位移防呆

`parse_input` 的 jq 陣列順序與下方 `read` 區塊**位置一一對位**,新增欄位(context_window_size / exceeds_200k_tokens 等)極易因錯位引入難察 bug。防呆做法:在 jq 陣列與 read 區塊兩側鏡像加上**編號註解 `# NN field`**(同號對齊),並加一個 **sentinel 測試**作為真正的守門員——餵入每個欄位各帶**獨特可辨識值**的 JSON,斷言每個全域變數確實落在對應欄位。**無任何可觀察行為變化**。

**Rationale**:註解是給人看的對位提示,但唯一能在 CI 擋住錯位的是 sentinel 測試(實際斷言 landing)。兩者並用:註解降低犯錯率,測試保證錯了會被抓。

**Alternatives**:(a) 改用 jq 輸出 key=value 再按名解析 — 打破既有「位置對位、零額外解析」的精簡設計且增成本,否決;(b) 只加註解不加測試 — 註解會腐化,無強制力,故以 sentinel 測試為真正守門。

### 去重重構

抽出兩段共用邏輯,皆 behavior-preserving:(1) **共用時長格式化器**——`ttl()`(reset 倒數)與 last-message 的 Δ 格式化目前各有一份幾乎相同的 `D/H/m` 換算,合併為單一 formatter;(2) **共用有界輸出 helper**——`render_line` 內兩段 byte-identical 的溢位安全區塊(left-only 與 right-empty 的「量寬→放得下直接印、放不下 head-truncate」)抽成一個 helper。

**Rationale**:重複碼是位移/不一致 bug 的溫床(兩份格式化器哪天只改一份就分歧);抽共用後單點維護。嚴格 behavior-preserving,輸出 byte 不變,由既有測試 + 對拍守住。

**Alternatives**:(a) 維持重複 — 持續累積分歧風險,否決;(b) 過度泛化成通用 lib — 違反 bash 3.2 的精簡與零相依取向,只抽這兩處明確重複即可。

## Implementation Contract

**可觀察行為(observable behaviors)**

- 左側新增 token 段:恆顯示本 session in+out 累計;`subagent_tokens > 0` 時追加 `⊂<subagent_tokens>` 形式;零 subagent 不顯示該追加。
- quota 旁的燃燒警報:僅在 `slope > 0` 且外推會在 `resets_at` 前見底時出現,顯示見底倒數;`<= 30m` 著紅;否則隱形。
- ctx% 警示門檻隨 `context_window_size` / `exceeds_200k_tokens` 自適應,不再固定 80%。
- 跨本地日曆日的 last-message 顯示日期前綴;同日維持 `HH:MM`/`HH:MM (Δ)` 不變。
- 終端變窄時依固定 14 步順序漸進降級;核心(path + ctx%)永遠保留;整行永不超過可繪寬度。
- 內部強化(reconcile 競態修正/背景化、位移防呆、去重)**無任何可觀察行為變化**。

**快取檔格式 / 資料形態(data shapes)**

- token 加總快取(使用者 `.claude` 目錄,仿 `sl-ratelimit-cache`),每 session 一行:
  `T <sid> <session_tokens> <subagent_tokens> <main_size> <main_mtime> <sub_size> <sub_mtime>`
- rate-limit 快取沿用既有兩種行(`S …` 註冊、`W …` 視窗權威),**新增**燃燒取樣行:
  `P <resets_at> <timestamp> <used>`(每 window 有界保留最近數點)
- subagent 來源:`<transcript_path 所在目錄>/<sid>/subagents/agent-*.jsonl`(已實測對位)。
- token 定義:`session_tokens = Σ(input_tokens+output_tokens)` over 主 transcript;`subagent_tokens` 同法 over 所有 agent-*.jsonl;**皆不含 cache 欄位**。

**失敗模式(failure modes)**

- 鎖取得失敗(reconcile 的 `mkdir` 鎖):有界重試後仍失敗 → `return 0`,保留本幀自身 rate 值,不寫快取(degrade safe)。
- 快取缺失 / torn(寫到一半):缺檔當首次 run(從本幀 seed);torn / old-format / 非數值行於下次重寫時不帶過,單幀沿用既有或自身值,不報錯。
- `current_usage` / rate 欄位為 null 或非數值:既有 guard(`case … *[!0-9.]*`)維持本幀不更新;燃燒投影在無有效 used% 時不取樣、不警報。
- 空 session_id:跳過破壞性 mv(read-only adopt);last-msg 路徑仍走既有 traversal 檢查(`''|*/*|*..*` → skip)。
- perl 缺席:`trunc_head` 走既有純 bash 過估退化路徑,寬度仍安全(只縮不爆);新排版段不依賴 perl 才能保證不溢出。
- token 加總:`transcript_path` 空 / 檔不存在 / jq 失敗 → 該段不顯示(空字串),不阻塞、不報錯。

**驗收(acceptance)= verify gate**

三檔 `bash -n` 全過 + `shellcheck -x statusline-command.sh` 過(跟隨 `. ` source)+ `bash tests/run-tests.sh` 印出 `ALL CHECKS PASSED`。新增功能須各自有對應測項(token 段、燃燒投影條件、排版降級順序、reconcile 併發/空 session、context 門檻、跨日時鐘、parse_input sentinel)。

**In-scope**

- `statusline-command.sh`(config 旋鈕、主流程新增 token job 與 reconcile 背景化、過時註解更新)、`lib/collect.sh`(token 加總 job、reconcile 鎖/空 session/背景化、parse_input 新欄位 + 編號註解)、`lib/render.sh`(token 段、燃燒警報、14 步降級、context 門檻、跨日前綴、去重 helper)、`tests/run-tests.sh`(新測項)、`CLAUDE.md`(架構/旋鈕/硬規則文件更新)。
- 新增 token 加總快取檔;rate-limit 快取新增 `P` 取樣行。
- 更新 `statusline-command.sh` 中那則過時的 "no such field exists" cache 註解(現在 ctx 改用 `context_window_size`/`exceeds_200k_tokens` 等已可達欄位,該註解需修正)。

**Out-of-scope**

- 不改 rate-limit 同步「最新 session 為權威」核心規則。
- 不還原真實花費(cache 寫入成本不計入 token 段)。
- 不修改 UserPromptSubmit hook 的 last-msg 寫入格式(跨日在 statusline 端處理,向後相容舊檔)。
- 不引入 wcwidth 表、不引入新外部相依、不放寬 256 上限、不加 `set -e`、不使用 bash-4+ 特性。
- repo root 的 `preview-*.html` 草稿不屬規格範圍(實作後清除)。

## Risks / Trade-offs

- [subagent 目錄隨多場 workflow 增長,全量 re-sum 成本上升] -> 以 size/mtime gate 讓重算只在內容變動時於背景發生;後續可做 per-file memoize(各 agent-*.jsonl 各記 size/mtime 與其分項和,只重算變動的檔),把成本降到正比於新增量而非總量。
- [in+out 定義隱藏了 cache 重寫的真實成本(數字看不出 cache 花費)] -> 為刻意取捨,換取數字跨 cache 過期/重寫的穩定性;於 CLAUDE.md 與旋鈕註解明文記載「token 段為 in+out、不含 cache,不等於花費」,避免誤讀。
- [燃燒投影準度受限於 CC 凍結的 rate_limits 瞬時值] -> 取樣的是**經 reconcile 採用後(reconciled / 權威)的 used%**,而非本 session 凍結值,使斜率反映跨 session 的真實爬升;無有效 used% 時不警報而非亂報。
- [警報在見底邊界附近抖動(flicker)] -> 以平滑斜率 + 遲滯(hysteresis,進入/退出警報用不同門檻)抑制;敏感度旋鈕預設 balanced,讓使用者可調鬆以進一步減少邊界抖動。
