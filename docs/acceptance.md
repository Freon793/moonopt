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
| 1 | 以 MoonBit 为主要实现语言（`moonc` 不低于 0.10.14） | 非测试 MoonBit 实现 **46 个文件 / 17 270 行**（测试另 28 文件 / 7 714 行，合计 74 文件 / 24 984 行）；仓库里**没有**任何非 MoonBit 的实现文件；零 FFI、零第三方运行期依赖（库包不引任何第三方包，仅 `cmd/parse` 引官方 `moonbitlang/x` 的 `fs`/`sys`）；工具链 **moonc v0.10.15+943464bfa**（本机 `moon version --all` 与 CI 当次日志逐字一致） | `moon check --deny-warn`；`moon version --all`；`git ls-files '*.mbt'` 后按 `_(wb)?test\.mbt$` 分流、用 `[IO.File]::ReadAllLines` 计行（**不能用 `Measure-Object -Line`：它不数空行**，会少算约 800 行；本行数字随每次代码改动重算）；`simplex/moon.pkg` 等包配置 |
| 2 | GitHub 仓库公开可访问、提交记录清晰 | 公开仓库 `Freon793/moonopt`（默认分支 `main`，Apache-2.0 被 GitHub 识别）；**159 个提交**，唯一作者与仓库所有者一致，全部落在 2026-09-14 ~ 10-15；其中 **143 个提交信息带正文**（写明"做了什么 / 为什么 / 证据"） | `git log --oneline`；GitHub 仓库页；`git rev-list --count HEAD` |
| 3 | 源代码结构清晰，能完成声明的核心功能 | 10 个包各司其职（`core`/`model`/`format`/`simplex`/`presolve`/`verify`/`mip`/`oracle`/`cmd/*`），包边界与依赖规则写在 [`design.md`](design.md)；核心功能有基准报告 | [`design.md`](design.md)；`bench/parse-report.md`、`bench/solve-report.md`、`bench/mip-report.md`、`bench/mip-report-small.md` |
| 4 | 提供 README，说明目标 / 安装 / 使用 / 示例，且可复现 | [`../README.md`](../README.md) 的四要素齐备（定位与"为什么需要它"、`moon add` 安装、CLI 与 API 用法、可运行示例）；本文件第 2 节给出评审可执行的最短复现路径 | 见下方"五分钟复现" |
| 5 | 使用持续集成工具并覆盖**检查、构建、测试**流程 | [`.github/workflows/check.yml`](../.github/workflows/check.yml)：`check` 任务在 Linux / macOS / Windows 上按序跑 `moon check --deny-warn` → `moon build` → `format diff` → `info check` → `moon test --deny-warn` → 报告陈旧性；`targets` 任务在 wasm-gc / js 上跑 `moon build --target <t>` → `moon test --target <t>`。发布 `0.2.0` 的那次运行五个任务全绿，日志里 `Total tests: 198, passed: 198, failed: 0` 与 `4 report(s), 0 stale` | GitHub Actions 运行页；每个任务都在注解里写出本次使用的工具链版本 |
| 6 | 提供至少一个可运行示例或最小使用样例 | `examples/production_plan`（最优 21）、`examples/transportation`（最优 11）、**`examples/schedule_bound`（手上已有一份方案时算它的 gap：LP 界 7.5、最优 11、这份方案 12 ⇒ gap ≤ 4.5）**、`cmd/main`（含一个"当前不支持"的诚实案例），README 另给最小 API 片段 | `moon run examples/production_plan` / `examples/transportation` / `examples/schedule_bound` |
| 7 | 提供完整测试，覆盖核心功能路径 | **210 个测试 / 28 个测试文件**在 native / wasm-gc / js 三目标全绿（本机 210/210；CI 下一次运行会显示同样的数），覆盖：与 `oracle` 的随机 LP 差分、presolve/postsolve 还原一致性、证书"故意做坏必须被拒"、无效割必须被拒、`verified == nodes` 不变量、CLI 文本与 JSON 两条路径、"不可行主张必须能被人工和解释"这条内核自检判据、cutoff 收紧节点盒子的四种情形、`box_minimum` 在真实实例量级上的带内行为与"内核量与校验器量是同一个数"、变量界自检、Farkas 射线的三条测量与无界射线的四条测量都与校验器同尺（含"零向量与走错方向"两种失败模式）、整数行强化"原模型与强化后的模型在整个盒子上接受完全相同的整点"（含变量界与向下的界）、`relaxation` "两种优化方向下都是合法界且调用方的点仍在同一空间"、整数无界性的两条路径（点与射线都整数时报 `Unbounded`；点或射线分数时保守回退 `UnboundedRelaxation`）、以及"没有结论的节点仍把它的界留在开集里" | `moon test`（及 `--target wasm-gc` / `--target js`） |
| 8 | 发布到 mooncakes.io | `Freon793/moonopt` 已发布（`0.1.0`、`0.1.1`、`0.1.2`、`0.2.0`、**`0.3.0`**），注册表可解析、可安装；发布物自包含且不含第三方数据。**最新一版 `0.3.0` 的发布动作与消费都实测过**：`moon publish` 返回 `Server status: 200 OK`；空白工程里 `moon add Freon793/moonopt@0.3.0` 下载成功、`moon check --deny-warn` 退出 0、**七项公开契约实测 `FAILURES: 0`**（`0.2.0` 当时是四项）。`0.3.0` 补齐的正是申报书核心清单里 `0.2.0` 缺的那几项（Devex 定价、对偶固定、整数行强化、`relaxation`），所以"从注册表装的这一版有没有申报书列的能力"这件事现在是**可核对**的 | `moon add Freon793/moonopt@0.3.0`（见下方第 3 节） |
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
| 稀疏 CSC 修正单纯形：Phase I/II、**Dantzig 与 DeVex 定价**、Harris 两遍比值检验 + Bland 兜底、基逆更新（product-form / eta）、对偶值与检验数、无界射线 | `simplex/revised.mbt`（`State`、Phase I/II、`Eta`、Harris、Bland 闩死）、`simplex/lu.mbt`、`simplex/result.mbt`（`Pricing::{Dantzig, Gain, Devex}`） | `moon run cmd/parse -- <file> --solve [--pricing dantzig\|gain\|devex]`；`bench/solve-report.md`；`docs/algorithms.md` 第 2 节三条规则的表 | solved to optimality **27/32**、总枢轴 **25 918**、最大已解模型 **2176 行**；同清单三规则 **gain 12 361 / devex 15 045 / dantzig 15 779**（表见 `docs/algorithms.md` 第 2 节，测于 1000 行口径；默认 gain，Devex 由 `SimplexOptions::with_pricing` 选） |
| 对偶单纯形热启动 | `simplex/dual.mbt`（`solve_from_basis`）、`SimplexBasis` | `simplex/dual_test.mbt`：`a warm start reaches the same answer as a cold solve`、`a warm start detects infeasibility after a bound is tightened`、`a basis from another problem is refused rather than trusted`、`warm and cold agree on a random corpus of tightened models` | 不变量"基保持对偶可行"在末尾检查一次，违反即交回冷启动；`mip` 的每个子节点都走这条路 |
| presolve / postsolve（空行/列、singleton、系数强化、对偶固定、界收紧与解还原） | `presolve/presolve.mbt`（各归约 + `PresolveStats` 逐项计数 + `reconstruct`、整数路径的 `strengthen_integer_rows`） | `presolve_wbtest.mbt`：`presolve drops a satisfied empty row and rejects an impossible one`、`presolve consumes a singleton row as a bound`、`presolve drops a row the bounds already imply`、`presolve eliminates a fixed variable and keeps its objective contribution`、`dual fixing fires only when the improving direction relaxes every row`、`presolve tightens a bound implied by the other terms`、`presolve finds an upper bound through a negative coefficient`、`presolve invents no bound when the other terms are unbounded`、`row strengthening keeps exactly the integer points of a row`、`a row tightens an integer bound downwards too`；`presolve_test.mbt` 的 `presolve and the direct solve agree on random models` | `bench/solve-report.md`：`reduced=21 / checked=20`（化简解逐项复核回原模型）；`30n20b8` 消掉 7282 个变量（内核行 18956 → 11591）；整数路径的**隐含整数界**在 15 个实例里触发 81 次 / 4 个实例，**系数抬高那一半在本语料不触发**（原因与实验见 [`algorithms.md`](algorithms.md#4-presolve-与-postsolve)） |
| 分支定界（整数 / 0-1 模型）：节点松弛全部过独立校验、根割、原始启发式、**整数无界性证明** | `mip/mip.mbt`（`MipStatus` / `MipResult`）、`mip/search.mbt`（搜索与 `integral_on_integers`）、`mip/cuts.mbt`、`mip/rounding.mbt` | `moon run cmd/parse -- <file> --mip --max-rows 300 --max-nodes 600`；`bench/mip-report.md`、`bench/mip-report-small.md`；`docs/algorithms.md` 第 6 节；测试 `an unbounded relaxation with an integral ray is an unbounded model`、`an unbounded relaxation with a fractional point stays unbounded-relaxation`、`integral_on_integers reads only the integer variables, against the tolerance` | 宽口径（32 实例 / 600 节点）**4 证到最优**、17 超行数跳过、`relaxations verified` **7 326**、割 **345** 条全部经 `verify_cut` 复核；小规模（10 实例 / 30 000 节点）**5 证到公开最优**、`check-mip-objectives.ps1` 对 5 项取等；整数无界性只在"点与射线在整数变量上都整数"时报 `MipStatus::Unbounded`，否则仍报 `UnboundedRelaxation` |
| 证书与独立校验器：最优性对偶解、Farkas 不可行证书、无界射线；**校验器不复用求解器内部中间量** | `verify/verify.mbt`（三种 claim）、`verify/checks.mbt`、`verify/cuts.mbt` | `moon run cmd/parse -- <file> --verify [--certificate <path>]`；`verify_test.mbt`：`an optimality certificate is accepted`、`a farkas certificate proves infeasibility`、`an unboundedness certificate is accepted`、`plausible but wrong multipliers are rejected`、`rays that are not rays are rejected`、`a deliberately broken solver's answer is rejected`、`certificates survive a json round trip`；**`verify/moon.pkg` 不 import `simplex`**——"不复用中间量"的证据就是那个文件本身 | `bench/check-mip-objectives.ps1` 把报告里每个 `optimal` 与 MIPLIB 官方最优表**取等**（本机 `checked 3, violations 0, not in the table 0, unverified nodes 0`）；三种主张的生产端各自把校验器的测量
先做一遍（最优性：残差、乘子符号、对偶间隙；不可行：射线符号、盒吸收、边际；无界：点的行与变量界、射线的
四项），任一不成立就**不发证书**（本文第 5 节） |

另外三条跨条目的声明，同样可核：

- **库包零第三方依赖、可编译到 native / wasm-gc / js**：每个库包的 `moon.pkg` 只 import `moonbitlang/core/*`，
  唯一引第三方的是 CLI `cmd/parse`（官方 `moonbitlang/x` 的 `fs` / `sys`）；CI 的 `targets` job 在
  wasm-gc / js 上 build + test，本机 `moon test --target wasm` / `--target wasm-gc` / `--target js` 各
  **210/210**。
- **结果能与 MIPLIB、GLPK / HiGHS 等外部工具和公开基准直接对拍**：输入输出是 MPS / LP，`bench/fetch-instances.ps1`
  取 MIPLIB 2017 实例，`bench/check-mip-objectives.ps1` 与官方最优值取等，`bench/check-relaxation-bounds.ps1`
  把松弛界与官方最优值对拍（本机 `checked 27 / violations 0 / not in the table 0`）。
- **"上层启发式产出方案 → 用 moonopt 解 LP 松弛得到下界 → 给出 gap ≤ X%"**（申报书"预期使用场景"的第一条）：
  由 `relaxation`（顶层包）+ `solve` + `presolve::objective_value` / `max_row_violation` 三个公开函数组成，
  `examples/schedule_bound` 是可运行的一整条链路（本机实测：界 7.5、最优 11、手上方案 12 ⇒ gap ≤ 4.5；
  同时打印界自身离最优 3.5 的相对量，避免读者把界当成答案）。

## 2. 五分钟复现（评审可执行）

```bash
moon version --all                    # 本仓库验证于 moonc v0.10.15（要求不低于 0.10.14）
git clone https://github.com/Freon793/moonopt && cd moonopt

# ① 检查 / 构建 / 测试（与 CI 相同的三步）
moon check --deny-warn
moon build
moon test                             # 210 个测试

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

## 3. 发布物验收

```bash
# 在一个空工程里装发布版（而不是仓库源码）
moon new consumer && cd consumer
moon add Freon793/moonopt
```

发布归档本身的三个事实（做法记录在 [`history.md`](history.md) 的 M6 条目里；下面是 `0.3.0` 这一版实测的）：

- **自包含**：归档解到仓库外当模块根，`moon check --deny-warn` 干净、`moon test` **207/207**
  （`0.3.0` 归档口径；`0.2.0` 当时是 198/198、`0.1.2` 是 180/180）；
- **不含第三方数据**：`0.3.0` 归档 **130 个条目 / 507 455 字节**（`0.2.0` 是 127 / 474 636），
  `bench/data` 只剩本项目自己写的清单 `small.txt`，没有 `.mps` / `.gz` / `.solu` / `.lp` 条目，
  排除规则在 `.moonignore`；
- **公开面可被陌生人使用**：一个只 import `Freon793/moonopt`（及 `model` / `core` / `presolve`）的外部工程
  能编译并按**七项**契约运行 —— 线性模型最优 `21.00000000002238`、整数模型最优 `20`、矛盾模型
  `infeasible`、"预算 1 时必须报 `node-limit` 而不是假装最优"（开界就是松弛最优值 `21.00000000002238`）、
  以及 `relaxation` 那条链路（手上方案 cost `20` 对界 `21.00000000002238`、行违反 `0`、gap `1.0000000000223785`），
  实测 `FAILURES: 0`（`0.3.0` 的注册表消费验收就是这次运行；`0.2.0` 时是四项契约）。

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
- `bench/mip-report-small.md` 口径下 10 个实例中 **5 个证到公开已知最优值、5 个到节点预算**
  （`check-mip-objectives.ps1` 对 5 项取等）；该口径的**节点预算 30 000 与求解报告的枢轴上限 20 000
  都是实测定的**（见 [`history.md`](history.md)），换一个上限就是另一场实验，不能互相比较。
