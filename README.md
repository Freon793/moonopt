# Freon793/moonopt

[![check](https://github.com/Freon793/moonopt/actions/workflows/check.yml/badge.svg)](https://github.com/Freon793/moonopt/actions/workflows/check.yml)

**把 MoonBit 的线性 / 整数优化从教学级稠密实现，推进到能与工业数据与公开基准对拍的工程内核。**

`moonopt` 提供标准模型互操作（MPS / LP）、稀疏修正单纯形与对偶单纯形、presolve / postsolve、
分支定界与**带证明的割**，以及**可被第三方独立校验**的最优性、Farkas 不可行性与无界性证书。
纯 MoonBit 实现，**无 FFI 依赖**。

> **状态**：`0.1.2`，已发布到 mooncakes.io（`moon add Freon793/moonopt`）。M1–M6 的完成标准全部达成：
> 解析、求解、证书校验、分支定界四条路径都有可复现的基准报告与测试覆盖（182 个测试，native / wasm-gc / js
> 三目标全绿）。CI 在 Linux / macOS / Windows 上执行**检查 / 构建 / 测试**三步，另有两个目标平台的测试任务。
> **本文件只做入口**：逐版变化见 [`CHANGELOG.md`](CHANGELOG.md)，逐轮技术决策与实测数字见
> [`docs/roadmap.md`](docs/roadmap.md)，各文档的职责见下面的[文档导航](#文档导航)。

## 快速开始

```bash
moon add Freon793/moonopt
```

最小可用例子（用到两个包：`Freon793/moonopt` 是求解入口，`Freon793/moonopt/model` 是模型构造）：

```moonbit
///|
/// max 5x + 4y  s.t.  6x + 4y <= 24,  x + 2y <= 6,  x, y >= 0   ->  21 at (3, 1.5)
fn demo() -> Unit {
  let m = @model.Model::new(@model.Sense::Maximize)
  let x = m.add_var("x")
  let y = m.add_var("y")
  m.set_objective([(x, 5.0), (y, 4.0)])
  m.add_named_constraint([(x, 6.0), (y, 4.0)], @model.Rel::LessEqual, 24.0, "machine_hours")
  m.add_named_constraint([(x, 1.0), (y, 2.0)], @model.Rel::LessEqual, 6.0, "labour_hours")
  let sol = @moonopt.solve(m)
  match sol.status {
    @moonopt.SolveStatus::Optimal => println("objective = " + sol.objective.to_string())
    _ => println("not solved: " + sol.message)
  }
}
```

### 五分钟从零复现

```bash
moon version --all                   # 需要 MoonBit 0.10.7 以上
git clone https://github.com/Freon793/moonopt && cd moonopt
moon run examples/production_plan    # 两产品生产计划：最优 21 at (3, 1.5)
moon run cmd/main                    # 打印三个模型的状态报告（含一个"当前不支持"的诚实案例）
moon check --deny-warn && moon test  # 182 个测试
```

真实实例（MIPLIB 2017，仓库**不再分发**数据，用脚本下载）：

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File bench/fetch-instances.ps1
moon run cmd/parse -- bench/data/instances/22433 --mip --max-nodes 2000
powershell -NoProfile -ExecutionPolicy Bypass -File bench/report.ps1   # 四份报告是否仍被当前代码支持
```

> 输出里的末位偏差（`21.00000000002238`）是**退化扰动**留下的脚印（`degeneracy_perturbation`，默认 1e-12）：
> 求解用的右端项加了一个远小于可行性容差的确定性微扰来打破退化平局，而残差自检始终对**未扰动**右端项测量，
> 因此解对调用方写下的模型仍然可行。面向人读的定点格式化属于报表层，示例直接打印原始值。

## 可运行示例与 CLI

```bash
moon run examples/production_plan    # 生产计划（最优 21）
moon run examples/transportation     # 产销平衡运输问题（全等式约束，走 Phase I；最优 11）
moon run cmd/main                    # 两个示例 + 一个"当前不支持"的诚实案例
moon run cmd/parse -- <file.mps>     # 模型文件巡检：格式、规模、校验结论
```

`cmd/parse` 的五个子命令（首参数是这五个名字之一时按子命令解释，否则就是旗标形式，两者都支持）：

```bash
moon run cmd/parse -- solve <file.mps> --relax --presolve       # 求解（LP；--mip 走分支定界）
moon run cmd/parse -- solve <file.mps> --mip --max-nodes 2000   # 分支定界，每个松弛过 verify
moon run cmd/parse -- verify <file.mps> --relax                 # 求解并用独立校验器复核证书
moon run cmd/parse -- verify <file.mps> --certificate cert.json # 只校验证书，不重解
moon run cmd/parse -- fmt <file.mps> --format lp -o out.lp      # 读→写（用库自己的 writer）
moon run cmd/parse -- bench --manifest bench/data/instances/small.txt --mip --max-nodes 300
moon run cmd/parse -- solve <file.mps> --relax --json           # 机器可读输出
```

`--json` 输出一份 `{"tool","command","files":[...],"summary":{...}}` 文档：**没跑出来的字段不出现**
（而不是填 0）；数字是**最短往返表示、不取整**，下游副本与报告逐位一致；文本输出保持原样，`bench/` 的脚本与
四份报告都依赖它。`fmt` 不给 `-o` 时只打印不落盘；`--json` 与 `--reoptimize` 的组合被**显式拒绝**并说明原因。

## 能力与边界

**支持的模型类别**：`min` / `max`、`≤` / `≥` / `=` 任意混合（含负右端项）、任意有限上下界、自由变量、
整数与 0-1 变量。**越界一律返回 `NotSolved` 并带原因，绝不返回可疑解。**

| 支持 | 暂不支持（返回 `NotSolved` + 原因，或明确标注限度） |
| --- | --- |
| 连续变量、任意有限上下界、自由变量、`≤`/`≥`/`=` 混合、min/max | — |
| **整数 / 0-1 变量**（`mip` 分支定界，每个松弛过 `verify`；公开入口 `Model::solve` 与 `cmd/parse --mip` 都走它；**incumbent 的 cutoff 用来收紧节点盒子**，第二十四轮；实测**四个** MIPLIB 实例证到官方最优值） | **节点上的割**、整数无界性的证明（需要整数射线，松弛无界当前只报 `NotSolved` / `UnboundedRelaxation`）；割只在根节点做（`--cut-rounds`，默认 2 轮）；内核不为一组写不出符号约定的乘子另找一份证明，而是把该松弛记成"无结论"（因此丢掉它的界，见 `CHANGELOG.md` 第十五轮） |
| **带证明的割**（根松弛的表行按混合整数舍入成割，每条割附"由哪一行舍入而来"的证明，`verify_cut` 独立**重新推导**后才允许进入模型；拒绝即停成 `Unverified`；`MipResult::cuts` 与报告的 `cuts` 列可追溯） | 割族目前只有对**单行**的舍入，且**只在根节点**做：多行 MIR 聚合（第十六、二十一轮）与**节点上的割**（第二十二轮）都实测**净收益为负、已回退**（节点割：4 个可证最优实例里 3 个证明成本变差、墙钟 3–24 倍，只有 `khb05250` 305 → 92 节点）；割轮次不改善根松弛时整轮丢弃；一轮里各候选割的违背量**完全并列**，上限在候选多于它时实际是按行序截断 —— 第十六~十八轮量了五种选择/规模规则，**没有一种在"界"与"证明成本"两个轴上同时赢过行序取满上限**（`CHANGELOG.md`、`docs/roadmap.md`） |
| **对偶单纯形热启动**：`SimplexBasis` + `solve_model_with_basis`，改界后重解不再重建 Phase I（实测真实实例枢轴数 1–49 vs 冷启 21–1008） | 化简模型上的热启动（基必须与化简后模型同构） |
| **证书与独立校验器**（`verify`）：最优性（原始/对偶可行性、互补松弛、对偶间隙）、Farkas 不可行射线、无界射线 + 可行起点、证书 JSON、`cmd/parse --verify` / `--certificate` | 化简模型的乘子回映（证书只对**内核收到的模型**成立，故 `--verify` 走不化简的路径）；**Farkas 射线仍是 Phase I 的最优对偶解**，但内核现在先按必需条件自检 —— 人工和必须能吸收它要解释的违反量（`Σ a ≥ max v`），不成立就**不发证书**、报 `NumericalFailure`（第二十三轮；实测 `noswot` 节点 1558 上两者相差 5 个数量级） |
| MPS / LP 文件读入与写出 | MPS 的 `SC` / `SI` 半连续界、完整 `SOS` / `MARKER` 语义 |
| presolve：空行/列消元、冗余行、singleton 转界、隐式界收紧、固定变量消元 + 解还原（`solve` 默认开启） | 系数强化、对偶固定、变量/行的重复与支配检测；整数模型**不经化简**（答案不能取决于化简碰巧定住了什么） |
| 内核行数 ≤ 200000（`SimplexOptions::max_kernel_rows`；基用**稀疏 LU**，内存 `O(nnz + fill)`） | 填充量由 `max_factor_entries` 预算约束；再往上真正的限制是枢轴数与每次枢轴的实际增益（见 `bench/README.md`） |

**两个"行数上限"不要混淆**：`cmd/parse --max-rows N` 限制的是**模型约束数**（超过即 `solve=skipped`）；
内核自己的门禁 `max_kernel_rows` 限制的是**内核行数**。有限上界**不再**占行（有界变量枢轴把上下界当界用），
所以两者通常相等；唯一还会放大内核行数的是"下界无界的自由变量 + 有限上界"（`p − n ≤ ub` 是两个列之差，
没有单列界可用）。实测极端例子 `fast0507`：507 条约束、上界还是行的年代内核规模 **63516 行**（稠密基逆时代
约 30.8 GB），现在 **489 行**。

## 承诺 ↔ 证据

本项目的规矩是"每条承诺都要有可复核证据"（M6 完成标准之一）：下表把可检验的说法逐条指到证据上——报告的
具体列、一条能重跑的命令，或一个测试文件。**没有证据的说法不写进来**，有限度的地方在最后一列写清楚限度。
对赛事验收要求的逐条对照（另一条轴）见 [`docs/acceptance.md`](docs/acceptance.md)。

| 承诺 | 证据 | 限度 / 备注 |
| --- | --- | --- |
| 能读真实模型文件（MPS / LP） | `bench/parse-report.md`：manifest 全部实例 `parsed`、`failed 0`；重跑 `bench/report-parse.ps1` | 不支持 MPS 的 `SC`/`SI` 与完整 `SOS`/`MARKER`（解析器明确报错） |
| 能求解真实规模 LP（presolve + 稀疏 LU + 增益定价） | `bench/solve-report.md` 的各项计数；`bench/README.md` 的单实例量级（`30n20b8` 化简后 11591 行 16 秒最优） | 当前报告口径（`bench/report.md` 标 `current`）：32 实例中 **18 个求到最优、11 个超行数上限跳过、3 个到 1200 枢轴上限**。**枢轴上限是基准口径的一部分**（报告头部写明）：同一条命令把上限放到 20000，同一清单是 **20 个最优 / 11 跳过 / 1 到上限**、总枢轴 12 336、373 秒 —— 两个上限是**两场实验**，不可互相比较 |
| **每个松弛都经过独立校验器** | `bench/mip-report.md` 与 `bench/mip-report-small.md` 的 `verified` 列；`mip/mip_test.mbt` 断言 `verified == nodes` | `verified < nodes` 的差额是"到达不了结论的松弛"（迭代上限或写不出符号约定的证书），按**开着的活**计 |
| 小规模整数实例证到**公开已知最优值** | `bench/mip-report-small.md`（4/10）+ `bench/check-mip-objectives.ps1` 对 4 项**取等**通过 | 另外 6 个到节点预算（`markshare1`/`markshare2`/`pk1` 界贴下界） |
| 证书可被第三方独立复核（含 JSON） | `verify/verify_test.mbt`（含"故意做坏的解必须被拒"）；`cmd/parse -- verify <file> --certificate <json>` | 证书只对**内核收到的模型**成立，故校验路径不化简；Farkas 射线由 `Σ a ≥ max v` 这条必需条件把门（不成立就不发证书，第二十三轮），校验端对每一份证书仍独立复核 |
| 每条割都能被独立**再推导** | `verify/cuts_test.mbt`（穷举小模型所有整数点、确认无效割确实砍掉一个可行整点）；`mip/cuts_test.mbt`（做坏的割被拒且运行停 `Unverified`） | 割族只有单行舍入；选择规则五条、多行 MIR 聚合一族与**节点上的割**均已实测无净收益（`CHANGELOG.md`） |
| 公开入口的取舍口径（`NodeLimit` / `NotSolved`） | `docs/api.md` 的契约表；`moonopt_test.mbt` | 整数模型**不做化简** |
| 不可行 / 无界 / 预算到顶各有明确状态 | `mip/mip_test.mbt`（松弛无界报 `UnboundedRelaxation`、非法模型报 `Invalid`） | 整数无界性证明（整数射线）未做 |
| 规模门禁：行数上限与填充预算 | `bench/README.md` 的两张表；`simplex` 的 `TooLarge` / `max_factor_entries` | 行数上限是粗闸门，真正的界是枢轴数与每次枢轴增益 |
| CLI 文本输出稳定（`bench/` 脚本解析它） | `bench/report.md` 的一键复现命令；改动后实测同一调用逐位不变 | `--json` 是同一批运行的另一份渲染，不替代文本 |
| 报告是证据：脚本拒绝写不可靠报告 | 四个脚本各自的拒绝条件（退出码非零 / 条目数不符 / 出现被拒证书 / 点未通过复核），`bench/README.md` 逐条写出 | 拒绝即非零退出且**不落盘** |
| 报告是否仍被当前代码支持，有机械化判定 | `bench/report.md` 的 `generated at` 与 `code behind it` 两列（`STALE (N changed since)`） | 判据保守：改注释也算改 |
| 依赖边界（可被审阅的架构事实） | `verify/moon.pkg` 不 import `simplex`；库包不引 `moonbitlang/x`（只有 `cmd/parse` 引） | 这是"校验器与求解器不共享状态"的可检查形式 |
| 三目标全绿 | `moon test --deny-warn`、`--target wasm-gc`、`--target js`（当前 182 个测试） | CI 每次运行重跑 |
| 已发布（mooncakes.io 的 `Freon793/moonopt`，当前 `0.1.2`） | `moon.mod` 的 `version`；注册表页面；发布物的自包含与公开面四项契约的验收见 `docs/roadmap.md` 的 M6 轮次 | 语义版本从 `0.1.0` 起，之后按 SemVer 递增（`0.1.1` 是元数据与文档修正、`0.1.2` 修的是校验器算错的一个量） |

## 生态位

选型阶段对 MoonBit 生态做过一次横评（mooncakes.io 已发布模块与 GitHub `topic:moonbit` 仓库，方法与原始证据见
[`docs/related-work.md`](docs/related-work.md) 与 [`docs/ecosystem-survey.md`](docs/ecosystem-survey.md)）。
结论：**通用 LP/MILP 求解器与标准模型格式支持在该生态中此前不存在**；两个最相关的既有实现是
`Juwan-Hwang/moon-certified` 的 `math/simplex` / `math/ilp`（合集仓库里的稠密数组接口）与
`Luna-Flow/linear-program`（未发布到注册表）。逐项能力对照表见
[`docs/ecosystem-survey.md`](docs/ecosystem-survey.md#与生态内既有实现的差异)。

我们不追求广度，只做**窄而深 + 可验证**：与上述实现是互补与可对接关系，而非替换。

## 项目结构

```
moonopt.mbt       公开入口：solve / solve_with、SolveStatus、Solution、SolveOptions（默认开启 presolve）
core/             数值与稀疏基础设施（容差比较、补偿求和、CSC 稀疏矩阵）
model/            模型层（变量、线性表达式、约束、目标、模型校验）
format/           MPS 与 LP 格式读写、解析错误定位
oracle/           参考实现：稠密两阶段单纯形（差分测试对照基准，非交付求解器）
simplex/          稀疏修正单纯形内核（含对偶单纯形热启动）
presolve/         模型化简与解还原（公开接口可单独使用）
verify/           独立校验器：最优性、Farkas、无界射线 + 证书 JSON（不依赖 simplex）
mip/              分支定界与根割（每个松弛过 verify）
cmd/main/         示例 CLI 与演示输出
cmd/parse/        模型巡检 / 求解 / 校验证书 / 格式化 / 批量基准 CLI（子命令 + --json）
examples/         可运行示例
bench/            数据政策、下载与报告脚本、报告（入口 bench/report.md）
docs/             设计、算法、API 契约、路线图、生态调研、验收对照
```

## 文档导航

每个文档只负责一件事：

| 文档 | 负责什么 |
| --- | --- |
| [`README.md`](README.md)（本文件） | 入口：定位、安装与最小例子、能力与边界、承诺 ↔ 证据、生态位 |
| [`CHANGELOG.md`](CHANGELOG.md) | 逐版变化；每一轮实测数字与**被否掉**的方案（含否决理由） |
| [`docs/roadmap.md`](docs/roadmap.md) | 里程碑与完成标准、每轮技术决策、明确不做（非目标） |
| [`docs/design.md`](docs/design.md) | 架构：目标与非目标、包边界与依赖规则、数据表示、证书约定 |
| [`docs/algorithms.md`](docs/algorithms.md) | 实现里**真正在跑**的算法，每段以一条可复核数字结尾 |
| [`docs/api.md`](docs/api.md) | 公开 API 契约：每个包承诺什么、什么情况下返回哪个状态 |
| [`docs/acceptance.md`](docs/acceptance.md) | 赛事验收要求 ↔ 证据的逐条对照，以及评审可执行的验证步骤 |
| [`docs/ecosystem-survey.md`](docs/ecosystem-survey.md) | 生态横评、可借鉴项、与既有实现的差异、证书标准的对照 |
| [`docs/related-work.md`](docs/related-work.md) | 选型期的生态检索证据（命中数、仓库清单、方法限度） |
| [`bench/README.md`](bench/README.md) | 基准数据政策、实例量级、四份报告的复现步骤与上限口径 |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | 本地环境、提交前必须全绿的检查、代码规范与数据许可约定 |
| [`AGENTS.md`](AGENTS.md) | 给 AI/协作者的仓库地图与不变量清单 |

## 依赖

库包（`core` / `model` / `oracle` / `format` / 根包 `moonopt`）**不依赖任何第三方包**；
只有 `cmd/parse` 依赖官方 `moonbitlang/x` 的 `fs` 与 `sys`（读文件与取命令行参数）。

## 开发与贡献

常用命令见 [`CONTRIBUTING.md`](CONTRIBUTING.md)；提交前必须全绿的四条是 `moon check --deny-warn`、
`moon test --deny-warn`、`moon fmt && git diff --exit-code`、`moon info && git diff --exit-code`。
`.mbti` 是接口合同，必须随代码提交。CI（[`.github/workflows/check.yml`](.github/workflows/check.yml)）
在 Linux / macOS / Windows 上跑**检查 / 构建 / 测试**三步，另有 wasm-gc / js 两个测试任务。

## 数据与许可

- 本项目以 **Apache-2.0** 发布（见 [`LICENSE`](LICENSE)）。
- 基准数据（MIPLIB 2017）**不由本仓库再分发**：只提供下载脚本、清单与报告，来源与获取方式见
  [`bench/README.md`](bench/README.md)（其中也说明了为什么没有直接用 Netlib LP 测试集）。
- 算法实现基于公开文献，代码为本项目**原创**，未移植任何第三方实现；算法来源见
  [`docs/algorithms.md`](docs/algorithms.md) 与 [`docs/design.md`](docs/design.md)。
