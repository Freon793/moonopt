# 验收对照：要求 ↔ 证据

本文件把**赛事验收要求**逐条对上可复核的证据，并给出评审可以在本地执行的验证步骤。

两条证据轴分工不同，别混用：

- **本文件**回答"验收要求是否满足"（要求来自赛事的《代码仓库及验收要求》）；
- [`../README.md`](../README.md) 的能力表与 [`roadmap.md`](roadmap.md) 的完成标准回答"项目声明的能力
  有没有实现"。

两条轴的证据都指向同一批可复现对象：`bench/*.md`（报告）、`moon test`（测试）、`cmd/parse`（CLI 复现命令）。

## 1. 逐条对照

| # | 验收要求 | 证据 | 复核方式 |
| --- | --- | --- | --- |
| 1 | 以 MoonBit 为主要实现语言（`moonc` 不低于 **0.10.16**） | 非测试 MoonBit 实现 **48 个文件 / 18 761 行**（测试另 30 文件 / 8 493 行，合计 78 文件 / 27 254 行）；仓库里**没有**任何非 MoonBit 的实现文件；零 FFI、零第三方运行期依赖（库包不引任何第三方包，仅 `cmd/parse` 引官方 `moonbitlang/x` 的 `fs`/`sys`）；工具链 **moonc v0.10.16+b1a0e846e**（本机 `moon version --all` 与 CI 当次日志逐字一致） | `moon check --deny-warn`；`moon version --all`；`git ls-files '*.mbt'` 后按 `_(wb)?test\.mbt$` 分流、用 `[IO.File]::ReadAllLines` 计行（**不能用 `Measure-Object -Line`：它不数空行**，会少算约 800 行；本行数字随每次代码改动重算）；`simplex/moon.pkg` 等包配置 |
| 2 | GitHub 仓库公开可访问、提交记录清晰 | 公开仓库 `Freon793/moonopt`（默认分支 `main`，Apache-2.0 被 GitHub 识别）；**209 个提交**（复核时 HEAD 为 `4e48746`，2026-10-27；项目自 2026-09-14 起），唯一作者与仓库所有者一致；其中 **192 个提交信息带正文**（写明"做了什么 / 为什么 / 证据"） | `git log --oneline`；GitHub 仓库页；`git rev-list --count HEAD`；"带正文"的口径是 `git log -1 --format=%b <rev>` 非空，逐条数（`%b` 为空的只有一句话提交） |
| 3 | 源代码结构清晰，能完成声明的核心功能 | **15 个 `moon.pkg`**：库 8 个包（`core`/`model`/`format`/`simplex`/`presolve`/`verify`/`mip`/`oracle`）+ 2 个 CLI（`cmd/parse`、`cmd/main`）+ 4 个示例（`production_plan`/`transportation`/`schedule_bound`/`unbounded`）+ 根包，包边界与依赖规则写在 [`design.md`](design.md)；核心功能有基准报告 | [`design.md`](design.md)；`bench/parse-report.md`、`bench/solve-report.md`、`bench/mip-report.md`、`bench/mip-report-small.md` |
| 4 | 提供 README，说明目标 / 安装 / 使用 / 示例，且可复现 | [`../README.md`](../README.md) 的四要素齐备（定位与"为什么需要它"、`moon add` 安装、CLI 与 API 用法、可运行示例）；本文件第 2 节给出评审可执行的最短复现路径 | 见下方"五分钟复现" |
| 5 | 使用持续集成工具并覆盖**检查、构建、测试**流程 | [`.github/workflows/check.yml`](../.github/workflows/check.yml)：`check` 任务在 Linux / macOS / Windows 上按序跑 `moon check --deny-warn` → `moon build` → `format diff` → `info check` → `moon test --deny-warn` → 报告陈旧性；`targets` 任务在 wasm-gc / js 上跑 `moon build --target <t>` → `moon test --target <t>`。发布 `0.4.0` 之后的那次运行（提交 `048201b`，[run `40464862139`](https://github.com/Freon793/moonopt/actions/runs/40464862139)）与提交 `8077092` 的那次运行（[run `40860507765`](https://github.com/Freon793/moonopt/actions/runs/40860507765)）都是五个任务全绿（3 个 OS 的 `check` + wasm-gc / js 的 `test target`）；前者的注解记着测试数 **224** 与 `4 report(s), 0 stale`，与本机同一批命令的输出逐项一致 | GitHub Actions 运行页；每个任务都在注解里写出本次使用的工具链版本 |
| 6 | 提供至少一个可运行示例或最小使用样例 | `examples/production_plan`（最优 21）、`examples/transportation`（最优 11）、**`examples/schedule_bound`（手上已有一份方案时算它的 gap：LP 界 7.5、最优 11、这份方案 12 ⇒ gap ≤ 4.5）**、**`examples/unbounded`（整数模型无界性的证明：点 `x0 = (0, 0)` + 射线 `d = (0, 1)`，两者在整数变量上都取整数值 ⇒ 公开状态 `unbounded`，逐行打印这两半）**、`cmd/main`（含一个"当前不支持"的诚实案例），README 另给最小 API 片段 | `moon run examples/production_plan` / `examples/transportation` / `examples/schedule_bound` / `examples/unbounded` |
| 7 | 提供完整测试，覆盖核心功能路径 | **240 个测试 / 30 个测试文件**在 native / wasm-gc / js 三目标全绿（本机三目标各 **240/240**；CI 的 `check` 任务跑的是同一条 `moon test --deny-warn`，提交 `048201b` 的运行五任务全绿），覆盖：与 `oracle` 的随机 LP 差分、presolve/postsolve 还原一致性、证书"故意做坏必须被拒"、无效割必须被拒、`verified == nodes` 不变量、CLI 文本与 JSON 两条路径、"不可行主张必须能被人工和解释"这条内核自检判据、cutoff 收紧节点盒子的四种情形、`box_minimum` 在真实实例量级上的带内行为与"内核量与校验器量是同一个数"、变量界自检、Farkas 射线的三条测量与无界射线的四条测量都与校验器同尺（含"零向量与走错方向"两种失败模式）、整数行强化"原模型与强化后的模型在整个盒子上接受完全相同的整点"（含变量界与向下的界）、`relaxation` "两种优化方向下都是合法界且调用方的点仍在同一空间"、整数无界性的两条路径（点与射线都整数时报 `Unbounded`；点或射线分数时保守回退 `UnboundedRelaxation`）、以及"没有结论的节点仍把它的界留在开集里" | `moon test`（及 `--target wasm-gc` / `--target js`） |
| 8 | 发布到 mooncakes.io | `Freon793/moonopt` 已发布（`0.1.0`、`0.1.1`、`0.1.2`、`0.2.0`、`0.3.0`、`0.4.0`、`0.5.0`、**`0.6.0`**），注册表可解析、可安装；发布物自包含且不含第三方数据。**最新一版 `0.6.0` 的发布动作与消费都实测过**：`moon publish` 返回 `Server status: 200 OK`；空白工程里 `moon add Freon793/moonopt@0.6.0` 能装、`moon check --deny-warn` 退出 0、**十项公开契约全部 PASS**（本轮 2026-10-31 重跑：线性最优 `21.00000000002238`、整数最优 `20`、矛盾模型 `infeasible`、预算 1 报 `node-limit` 且开界就是松弛最优 `21.00000000002238`、`relaxation` 链为 bound `7.500000000008999` 对最优 `11`、手上方案 `12` ⇒ gap `4.499999999991001`、列支配在四列两对覆盖模型上删 2 列且点回到调用方空间、等式模型 `columns_compared: 0`；输出 `contracts: 10 checked, 10 passed, FAILURES: 0`）。所以"从注册表装的这一版有没有申报书列的能力"这件事现在是**当次实测可核对**的 | 见下方第 3 节的两条命令 |
| 9 | 采用 OSI 认可的开源许可证；参考/移植需符合原项目许可证 | **Apache-2.0**（`LICENSE` + `moon.mod` 的 `license`）；项目为**原创实现**，未移植任何第三方代码；基准数据（MIPLIB 2017）只下载、不入库、且被 `.moonignore` 排除在发布归档之外 | `LICENSE`；`bench/README.md` 的数据政策；`.moonignore` |

### 1.1 申报书核心功能清单 ⇄ 证据

上面的九条是**赛事要求**；**申报书里承诺的核心功能**是另一条轴，验收会同时看（验收反馈里"申报核心列表中的
某项未实现"指的就是这条轴）。下表把申报书列出的每一项对上实现位置与可复核的证据——每一行都能在当次提交里
指认、能跑；没做到的部分不写在这里，而是单列在 [`roadmap.md`](roadmap.md) 与本文第 5 节。

| 申报书条目 | 实现位置 | 证据（命令 / 测试名） | 实测或限度 |
| --- | --- | --- | --- |
| 模型层（变量上下界与整数标记、约束、目标、模型校验） | `model/model.mbt`（含 `extends.mbt`） | `moon test`：`model_test.mbt`、`model_wbtest.mbt`；`moon run cmd/parse -- <file>` 打印 `OK … int=… validation_issues=0` | 模型校验失败一律映射成 `NotSolved` / `Invalid`，从不当成"不可行" |
| 容差数值与 CSC 稀疏矩阵 | `core/numerics.mbt`、`core/sparse.mbt` | `core/numerics_wbtest.mbt`、`core/sparse_wbtest.mbt` | 不变量：稀疏矩阵不存结构零、列内行号升序 |
| MPS（free/fixed）与 LP 格式读写，含 RANGES 展开、整数标记块、free row 语义，读→写→读 幂等 | `format/mps.mbt`、`format/mps_writer.mbt`、`format/lp.mbt` | 测试 `mps reads a small model`、`mps honours the OBJSENSE extension`、`mps integer markers mark the columns inside the block`、`mps applies every bound type it claims to support`、`mps ranges expand a row into two inequalities`、`mps accepts the Fortran style exponent marker`、`mps ignores coefficients of extra free rows`、`mps round trips through the writer`（含 `write_mps(parsed) == text` 的**定点**断言）、`lp round trips through the writer`、`lp bounds section covers every documented spelling`、`lp binary section gives 0/1 integer variables` | `bench/parse-report.md`：32 个实例 **32 解析成功 / 0 失败** |
| 稠密两阶段单纯形参考实现，作为稀疏内核的差分测试基准 | `oracle/dense_tableau.mbt` | `simplex/differential_test.mbt`（随机 LP 与 oracle 逐点差分）、`mip/mip_test.mbt` 的 `the search agrees with enumeration on a random corpus` | 只出现在测试依赖里（`simplex/moon.pkg` 的 `for "test"`），不是出货实现 |
| 稀疏 CSC 修正单纯形：Phase I/II、**Dantzig 与 DeVex 定价**、Harris 两遍比值检验 + Bland 兜底、基逆更新（product-form / eta）、对偶值与检验数、无界射线 | `simplex/revised.mbt`（`State`、Phase I/II、`Eta`、Harris、Bland 闩死）、`simplex/lu.mbt`、`simplex/result.mbt`（`Pricing::{Dantzig, Gain, Devex}`） | `moon run cmd/parse -- <file> --solve [--pricing dantzig\|gain\|devex]`；`bench/solve-report.md`；`docs/algorithms.md` 第 2 节三条规则的表 | solved to optimality **28/32**、总枢轴 **36 010**、最大已解模型 **4 497 行（归约后 2 402）**（行数上限挡住的 4 个实例抬到 `--max-rows 20000` 后**没有一个达到最优**：一条是数值失败（`mod011`，矩阵系数跨 3e+05）、两条是 Phase I 的枢轴成本、一条是 17 013 行本身的枢轴成本；另做了行/列均衡的实测，同样救不回任何一个，逐条见 `bench/README.md`。**等式 doubleton 代入落地后** `mod011` 在同一 20 000 行口径下 **solve=optimal**（−62121982.55190222，10 177 枢轴），其余三个没有等式 doubleton 猎物；随后行上限挪到 presolve 之后、口径 2 500，`mod011` 以归约后 2 402 行进入报告，其余两个仍被挡）；同清单三规则 **gain 12 361 / devex 15 045 / dantzig 15 779**（表见 `docs/algorithms.md` 第 2 节，测于 1000 行口径；默认 gain，Devex 由 `SimplexOptions::with_pricing` 选） |
| 对偶单纯形热启动 | `simplex/dual.mbt`（`solve_from_basis`）、`SimplexBasis` | `simplex/dual_test.mbt`：`a warm start reaches the same answer as a cold solve`、`a warm start detects infeasibility after a bound is tightened`、`a basis from another problem is refused rather than trusted`、`warm and cold agree on a random corpus of tightened models` | 不变量"基保持对偶可行"在末尾检查一次，违反即交回冷启动；`mip` 的每个子节点都走这条路 |
| presolve / postsolve（空行/列、singleton、系数强化、对偶固定、界收紧与解还原） | `presolve/presolve.mbt`（各归约 + `PresolveStats` 逐项计数 + `reconstruct`、整数路径的 `strengthen_integer_rows`） | `presolve_wbtest.mbt`：`presolve drops a satisfied empty row and rejects an impossible one`、`presolve consumes a singleton row as a bound`、`presolve drops a row the bounds already imply`、`presolve eliminates a fixed variable and keeps its objective contribution`、`dual fixing fires only when the improving direction relaxes every row`、`presolve tightens a bound implied by the other terms`、`presolve finds an upper bound through a negative coefficient`、`presolve invents no bound when the other terms are unbounded`、`row strengthening keeps exactly the integer points of a row`、`a row tightens an integer bound downwards too`；`presolve_test.mbt` 的 `presolve and the direct solve agree on random models` | `bench/solve-report.md`：`reduced=29 / checked=28`（化简解逐项复核回原模型；报告口径 2500）；`30n20b8` 消掉 7282 个变量（内核行 18956 → 11591）；整数路径的**隐含整数界**在 15 个实例里触发 81 次 / 4 个实例，**系数抬高那一半在本语料不触发**（原因与实验见 [`algorithms.md`](algorithms.md#4-presolve-与-postsolve)） |
| 整数路径的**列支配**归约（0/1 集覆盖模型上删列，再把解映回原变量空间） | `presolve/dominance.mbt`（`remove_dominated_columns` + `DominationStats`）、`mip/search.mbt`（`restore_removed_columns`）、`mip/mip.mbt`（`MipOptions::column_dominance` / `MipResult::domination`） | `moon test` 的 15 个用例：`a cheaper column on the same cover removes the other`、`a right hand side no single column settles protects every column`、`a smaller coefficient on the same cover is not a dominator`、`a larger coefficient on the same cover removes the other`、`a cover that contains another removes it`、`identical columns keep exactly one representative`、`a dearer column does not remove a cheaper one`、`an equality model is outside the class`、`an integer variable above one is outside the class`、`a continuous variable is outside the class`、`a model with nothing to give reports a comparison count`、`a dominated column comes back as zero and the optimum does not move`、`the mapping puts the kept values in the right slots`、`a model outside the class reports no columns compared`、`column dominance is on by default and has a switch` | 前提四条（每行 `≥`、系数全正、0/1 整数、无负成本）任一不满足就**整条不启动**，`columns_compared` 报 0 以区别于"看了没删"；语料 32 个实例里只有 `fast0507` 属于这一类，删 **36 670/63 009 列（58.2%）**；四份报告的数字**不变**（LP 报告跑的是松弛、宽口径 MIP 报告按行数上限跳过它），收益落在使用者手上的集覆盖模型（列数减半时同实例 LP 墙钟 327 s → 263.6 s）。**缺第四条判据的实测代价**：`markshare1` 被判 `infeasible`、`pk1` 报出 `optimal 726`（见 [`algorithms.md`](algorithms.md#4-presolve-与-postsolve)） |
| 分支定界（整数 / 0-1 模型）：节点松弛全部过独立校验、根割、原始启发式、**整数无界性证明** | `mip/mip.mbt`（`MipStatus` / `MipResult`）、`mip/search.mbt`（搜索与 `integral_on_integers`）、`mip/cuts.mbt`、`mip/rounding.mbt` | `moon run cmd/parse -- <file> --mip --max-rows 300 --max-nodes 600`；`bench/mip-report.md`、`bench/mip-report-small.md`；`docs/algorithms.md` 第 6 节；测试 `an unbounded relaxation with an integral ray is an unbounded model`、`an unbounded relaxation with a fractional point stays unbounded-relaxation`、`integral_on_integers reads only the integer variables, against the tolerance` | 宽口径（32 实例 / 600 节点）**5 证到最优**、10 到节点预算、17 超行数跳过、`relaxations verified` **7 081**、割 **345** 条全部经 `verify_cut` 复核；小规模（10 实例 / 30 000 节点）**6 证到公开最优**、`check-mip-objectives.ps1` 对 6 项取等；树顶的分支**按实测选**（`strong_branching_depth`：默认候选的两个子节点先各解一次，只有当它抬不动界时才把测量扩到另外最多 4 个候选，测得的松弛计入节点预算并逐个过校验），`gt2` 因此从 `node-limit` 变成 331 个松弛证到最优；整数无界性在"点与射线（分数时按最小整数倍缩放）在整数变量上都整数"时报 `MipStatus::Unbounded`，否则仍报 `UnboundedRelaxation`（点本身分数时无法证） |
| 证书与独立校验器：最优性对偶解、Farkas 不可行证书、无界射线；**校验器不复用求解器内部中间量** | `verify/verify.mbt`（三种 claim）、`verify/checks.mbt`、`verify/cuts.mbt` | `moon run cmd/parse -- <file> --verify [--certificate <path>]`；`verify_test.mbt`：`an optimality certificate is accepted`、`a farkas certificate proves infeasibility`、`an unboundedness certificate is accepted`、`plausible but wrong multipliers are rejected`、`rays that are not rays are rejected`、`a deliberately broken solver's answer is rejected`、`certificates survive a json round trip`；**`verify/moon.pkg` 不 import `simplex`**——"不复用中间量"的证据就是那个文件本身 | `bench/check-mip-objectives.ps1` 把报告里每个 `optimal` 与 MIPLIB 官方最优表**取等**（本机 `checked 5`（宽口径报告）/ `checked 6`（小规模报告），两份都是 `violations 0, not in the table 0, unverified nodes 0`）；三种主张的生产端各自把校验器的测量
先做一遍（最优性：残差、乘子符号、对偶间隙；不可行：射线符号、盒吸收、边际；无界：点的行与变量界、射线的
四项），任一不成立就**不发证书**（本文第 5 节） |

另外三条跨条目的声明，同样可核：

- **库包零第三方依赖、可编译到 native / wasm-gc / js**：每个库包的 `moon.pkg` 只 import `moonbitlang/core/*`，
  唯一引第三方的是 CLI `cmd/parse`（官方 `moonbitlang/x` 的 `fs` / `sys`）；CI 的 `targets` job 在
  wasm-gc / js 上 build + test，本机 `moon test --target wasm` / `--target wasm-gc` / `--target js` 各
  **224/224**（三个目标逐个跑，每次都打印 `Total tests: 224, passed: 224`）。
- **结果能与 MIPLIB、GLPK / HiGHS 等外部工具和公开基准直接对拍**：输入输出是 MPS / LP，`bench/fetch-instances.ps1`
  取 MIPLIB 2017 实例，`bench/check-mip-objectives.ps1` 与官方最优值取等，`bench/check-relaxation-bounds.ps1`
  把松弛界与官方最优值对拍（本机 `checked 28 / violations 0 / not in the table 0`）。
- **"上层启发式产出方案 → 用 moonopt 解 LP 松弛得到下界 → 给出 gap ≤ X%"**（申报书"预期使用场景"的第一条）：
  由 `relaxation`（顶层包）+ `solve` + `presolve::objective_value` / `max_row_violation` 三个公开函数组成，
  `examples/schedule_bound` 是可运行的一整条链路（本机实测：界 7.5、最优 11、手上方案 12 ⇒ gap ≤ 4.5；
  同时打印界自身离最优 3.5 的相对量，避免读者把界当成答案）。

### 1.2 本期新增工作（评审关心的"这一期做了什么"）

项目动工于 9 月中，**9 月末的基线是提交 [`0632534`](https://github.com/Freon793/moonopt/commit/0632534)
（`0.2.0` 发布、验收对照表落成，2026-09-30）**；本期工作以它为起点，到 `0.4.0`（`4c2946a`）共
**59 个提交**、82 文件 **+5 862 / −864 行**、测试 198 → 224（提交数与行数用
`git rev-list --count 0632534..4c2946a` 与 `git diff --shortstat 0632534 4c2946a` 重算；补上本轮这个
docs-only 提交之后 HEAD 的提交总数见第 1 节第 2 行）。分三批独立的能力增量与一个真缺陷修复，每一批都有
前后实测数字（全部可由四份报告与对拍脚本复核）：

| 批 | 内容 | 基线 → 本期末 |
| --- | --- | --- |
| 一（10-15） | 申报书清单里"列了而树里没有"的三件：**Devex 定价、对偶固定、系数强化**；隐含整数界；`relaxation` 公开入口与 `examples/schedule_bound`（申报书"预期使用场景"第一条的可运行链路） | 申报书核心清单全部落地 |
| 二（10-16 ~ 10-18） | **整数无界性证明**（`MipStatus::Unbounded`，点与射线都整数才主张）；**树顶分支按实测选**；`0.3.0` 发布并通过注册表消费验收 | MIP 证明 **3/32 → 5/32、5/10 → 6/10**；`gt2` 从 2 万节点界不动的 node-limit 变成 331 个松弛证到最优 |
| 三（10-23 ~ 10-25） | **邻域启发**（预算尾部 fix-and-optimize：`markshare1` 当前解 99 → 80）；**等式 doubleton 代入**（超出申报书清单的归约）；**热启动布局指纹修复**（单运行 155 次装坏基 → 0）；行上限挪到 presolve 之后、口径 2 500 | **LP 最优 20/32 → 28/32**（`mod011` 从"数值失败"到入报告 optimal）；`markshare1`/`markshare2` 当前解 257/192 → 105/192（宽）、99/122 → 80/103（小） |

四份报告的全部数字、每批的前后对比与被否决的路线，见 [`history.md`](history.md)；使用者可见的变化
逐条在 [`CHANGELOG.md`](../CHANGELOG.md) 的 `0.3.0` / `0.4.0` 两节。

## 2. 五分钟复现（评审可执行）

```bash
moon version --all                    # 本仓库验证于 moonc v0.10.16（要求不低于 0.10.16）
git clone https://github.com/Freon793/moonopt && cd moonopt

# ① 检查 / 构建 / 测试（与 CI 相同的三步）
moon check --deny-warn
moon build
moon test                             # 224 个测试

# ② 可运行示例
moon run examples/production_plan     # 最优 21 at (3, 1.5)
moon run examples/schedule_bound      # 已有一份方案时它值多少：界 7.5、最优 11、这份 12 ⇒ gap ≤ 4.5
moon run cmd/main                     # 三个模型的状态报告（含一个诚实的失败案例）

# ③ 用真实实例走一遍"求解 + 独立校验"
powershell -NoProfile -ExecutionPolicy Bypass -File bench/fetch-instances.ps1
moon run cmd/parse -- bench/data/instances/22433 --mip --max-nodes 2000
moon run cmd/parse -- verify bench/data/instances/22433 --relax   # 求解并用独立校验器复核证书

# ④ 报告是否仍被当前代码支持（机械判定，含工具链比对）
powershell -NoProfile -ExecutionPolicy Bypass -File bench/report.ps1
```

四份报告可由脚本一键重跑（`bench/report-parse.ps1` / `report-solve.ps1` / `report-mip.ps1`），
每条命令与其口径（行数上限、枢轴上限、节点预算）都记录在 [`../bench/report.md`](../bench/report.md)
与各报告头部；**上限是结果的一部分**，不同上限下的计数不能互相比较。

上面 ② ③ 六条命令的**期望输出**（本轮逐条跑过，退出码均为 0）：

| 命令 | 期望的一行 |
| --- | --- |
| `moon run examples/production_plan` | `objective = 21.00000000002238`（2 次枢轴） |
| `moon run examples/transportation` | `objective = 11` |
| `moon run examples/schedule_bound` | `LP bound (relaxation) : optimal 7.500000000008999`、`proven optimum : 11`、`gap of that plan : 4.499999999991001` |
| `moon run cmd/main` | 首行 `moonopt 0.4.0`，随后三段模型状态报告（含一个诚实的失败案例） |
| `moon run cmd/parse -- …/22433 --mip --max-nodes 2000` | `mip=optimal nodes=39 verified=39 cuts=20 obj=21477.000000017408`，并有 `point: worst row violation …/bound violation 0/integrality violation 0` |
| `moon run cmd/parse -- verify …/22433 --relax` | `solve=optimal obj=21240.526170816112 iters=1035`，随后打印 `certificate={…}` 与独立复核的结论 |

最后一条就是"求解 + 独立校验"的样子：证书由内核给出，复核由 `verify` 包做，而 `verify/moon.pkg`
**不 import `simplex`**——这条边界是本项目"校验器不复用求解器中间量"的可核对证据。

## 3. 发布物验收

```bash
# 在一个空工程里装发布版（而不是仓库源码）
moon new consumer && cd consumer
moon add Freon793/moonopt
```

发布归档本身的三个事实（做法记录在 [`history.md`](history.md) 的 M6 条目里；下面是 `0.5.0` 这一版实测的）：

- **自包含**：归档解到仓库外当模块根，`moon check --deny-warn` 退出 0（58 tasks）、`moon test` **240/240**
  （`0.6.0` 的归档口径是 240/240；`0.5.0` 与 `0.4.0` 都是 224/224；`0.3.0` 当时是 207/207、`0.2.0` 是 198/198、
  `0.1.2` 是 180/180）；
- **不含第三方数据**：`0.6.0` 归档 **136 个条目（解压后 1 729 211 字节）**
  （`0.5.0` 是 133 条目 / 591 928 字节 / 解压 1 683 676，`0.4.0` 是 133 条目 / 582 498 字节，`0.3.0` 是
  130 条目 / 507 455 字节），`bench/data` 只剩本项目自己写的清单 `small.txt`，没有 `.mps` / `.gz` /
  `.solu` / `.lp` 条目，排除规则在 `.moonignore`；
- **公开面可被陌生人使用**：一个只 import `Freon793/moonopt`（及 `mip` / `model` / `presolve`）的外部工程能
  编译并按**十项**契约运行 —— 线性模型最优 `21.00000000002238`、整数模型最优 `20`、矛盾模型 `infeasible`、
  "预算 1 时必须报 `node-limit` 而不是假装最优"（开界就是松弛最优值 `21.00000000002238`）、
  `relaxation` 那条链路（松弛界 `7.500000000008999` 对最优 `11`；手上方案 `(2, 0)` cost `12`、行违反
  `0` ⇒ gap `4.499999999991001`）、以及列支配的两项（四列两对 0/1 覆盖模型删掉 2 列、点回到调用方变量空间
  且被删处为 0、最优值与未归约的运行相同；等式模型报 `columns_compared: 0`），实测
  `contracts: 10 checked, 10 passed, FAILURES: 0`。这一条是**本轮（2026-10-31）对 `0.6.0` 重跑的**：
  空白工程 `moon new consumer06` + `moon add Freon793/moonopt@0.6.0`（从注册表装，不是仓库源码），
  程序只用 `@moonopt` / `@mip` / `@model` / `@presolve` 四个公开包、逐条打印。
  注册表本身同轮重新核过：`https://mooncakes.io/api/v0/modules/Freon793/moonopt` 返回
  `latest_version = 0.6.0`、`build_status = success`、未 yanked，八个版本
  （`0.1.0`/`0.1.1`/`0.1.2`/`0.2.0`/`0.3.0`/`0.4.0`/`0.5.0`/`0.6.0`）都在。

## 4. 与生态内既有实现的差异（为什么不是重复项目）

选型期用 `moon search` 与 mooncakes.io 做过检索（方法、命中数与逐项能力对照见
[`prior-art.md`](prior-art.md)）：生态内**没有**通用 LP/MILP 求解器与标准模型格式支持。最相关的两个
既有实现是 `Juwan-Hwang/moon-certified` 的 `math/simplex` / `math/ilp`（合集仓库里的稠密数组接口
`solve(c, A, b)`，没有模型对象与文件输入、没有对偶 / 证书、没有 presolve 与分支定界）与
`Luna-Flow/linear-program`（未发布到注册表的建模 + 标准化实现）。

本项目补的是**内核与外层契约**：标准模型互操作、稀疏修正单纯形与稀疏 LU、presolve / postsolve、
可独立校验的证书、分支定界与带证明的割、以及可复现的公开基准报告。

## 5. 已知限度

- 割只有**单行**舍入，且只在**根**节点做：五条选择规则、多行 MIR 聚合族与节点上的割都已实测、均无净收益
  并回退；cutoff 传播已落地（形态是收紧节点盒子，而不是加一行），它之外的更强节点归约（如域传播）未做；
- **无界射线**同样先量后发，且量的是校验器读它的四项：行不阻挡该方向（`≤` 行要 `aᵢ·d ≤ 0`、`≥` 行要
  `≥ 0`、`=` 行要 `= 0`，按 `1 + |aᵢ·d|` 缩放）、变量自己的界不阻挡（两端都有界的变量一步也走不了、只有一端
  的只能朝有空间的那一侧走，按 `1 + |dⱼ|` 缩放）、它不是零向量（`max|dⱼ|` 要超过容差）、以及**目标沿它严格
  改善**（`c·d / (1 + Σ|cⱼdⱼ|) < 0`，成本按校验器的最小化口径读，所以最大化模型的改善方向也算负）。此前的
  无界主张只量了**点**可行，这四项一项没量：在只量了一项的情况下宣布"目标无界"是一个带着自信状态的错误
  答案，而在分支定界里它会走得比它来自的那个节点更远；
- **Farkas 射线**仍是 Phase I 的最优对偶解，但内核在发证书前把校验器关于射线的三条测量自己做一遍——
  符号约定（**按射线自己的尺度**，不可行证书的尺度是地板值 1）、盒吸收、以及边际**严格为正**，
  另加一条关于算术自洽的代理判据（人工和必须能吸收它要解释的违反量）；任一不成立就**不发证书**、
  报 `NumericalFailure`，搜索按"没有结论的松弛"继续。限度：射线的**构造**仍是 Phase I 的最优对偶解，
  不是显式导出的射线；
- **整数无界性已能证明，但只覆盖"点与射线在整数变量上都取整数值"的情形**：内核报松弛无界时，若证书里的点与
  改善射线在整数变量上都是整数，`x⁰ + k·d` 对每个整数 `k ≥ 0` 保持整数且可行，于是报 `MipStatus::Unbounded`
  （`MipResult::values` + `ray` 是证明的两半）；任一不是整数则仍报 `UnboundedRelaxation`（松弛无界、模型未知）。
  没覆盖的是"内核射线本身是分数"的情形——把它按分母缩放到整数需要额外一步；而"找整数可行点"那半边仍归搜索。
  `fast0507` 在报告的枢轴上限（20 000）内跑不完；
  精确 steepest-edge 与行 / 列的支配检测等 presolve 归约未做（Dantzig / 实测增益 / Devex 三条定价规则、
  对偶固定、整数路径的**隐含整数界**都已落地并附实测；整数路径的另一半——**系数抬高**——在本语料上一次也不
  触发，原因与那次被回退的放宽实验见 [`algorithms.md`](algorithms.md#4-presolve-与-postsolve)）；
- `bench/mip-report-small.md` 口径下 10 个实例中 **6 个证到公开已知最优值、4 个到节点预算**
  （`check-mip-objectives.ps1` 对 6 项取等）；该口径的**节点预算 30 000 与求解报告的枢轴上限 20 000
  都是实测定的**（见 [`history.md`](history.md)），换一个上限就是另一场实验，不能互相比较。
