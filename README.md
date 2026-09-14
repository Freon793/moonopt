# Freon793/moonopt

[![check](https://github.com/Freon793/moonopt/actions/workflows/check.yml/badge.svg)](https://github.com/Freon793/moonopt/actions/workflows/check.yml)

**把 MoonBit 的线性/整数优化从教学级稠密实现，推进到能与工业数据与公开基准对拍的工程内核。**

`moonopt` 的目标能力：标准模型互操作（MPS / LP）、稀疏修正单纯形与对偶单纯形、
presolve/postsolve、可复用的分支切割框架，以及**可被第三方独立校验**的最优性（对偶可行解）、
不可行性（Farkas）与无界（射线）证书。纯 MoonBit 实现，无 FFI 依赖。

> 状态：**v0.1.0-dev**，`M1`（基础层与模型层）、`M2`（标准模型输入）已落地，`M3` 进行中
> （稀疏修正单纯形已接入公开入口；对偶单纯形与 presolve、稀疏基分解、性能优化待完成）：
> 可构建、可测试、CI 全绿，并已在 **MIPLIB 2017 的 33 个真实实例**上跑通解析报告
> （33 成功 / 0 失败，见 [`bench/parse-report.md`](bench/parse-report.md)）与求解报告
> （见 [`bench/solve-report.md`](bench/solve-report.md)）。尚未发布到 mooncakes.io。
> 里程碑划分、范围闸门与明确**不做**的内容见 [`docs/roadmap.md`](docs/roadmap.md)。

## 当前能力（M1、M2 与 M3 进行中）

已经可用并且有测试覆盖的部分：

- `core`：容差感知的数值比较（`approx_eq` / `approx_zero` / `approx_positive`）、
  Neumaier 补偿求和、**CSC 稀疏矩阵**（构造时排序/合并/丢结构零、按列访问、转置、稠密化、矩阵向量乘）；
- `model`：LP/MILP 模型层 —— 变量（上下界、整数标记）、线性表达式、约束（`≤` / `≥` / `=`）、
  目标（min/max）、模型校验（返回人类可读的问题列表）；
- `format`：**MPS 读取器与写出器**（free / fixed 布局、`RANGES` 展开、`MARKER` 整数块、
  free row 语义、`OBJSENSE` 扩展）与 **LP 格式读写**（目标、`Subject To`、`Bounds` 的各种写法、
  `Generals` / `Binary`），读→写→读 幂等；
- `simplex`：**稀疏修正单纯形内核** —— 稀疏 CSC 列存储 + 基逆乘积形式更新 + 周期性重新分解、
  Phase I（人工变量）与 Phase II、Dantzig 定价并在停滞时自动切换到 Bland 规则、
  **Harris 两遍比值检验**、对偶值与检验数、不可行 / 无界 / 迭代上限 / 数值失败四类状态各自区分；
  模型侧的上下界、自由变量（拆成正负两部分）与 `≤` / `≥` / `=` 混合约束都在内核内完成变换；
- `oracle`：**稠密两阶段单纯形参考实现**，作为稀疏内核的差分测试对照基准（不是交付求解器）；
- `moonopt`：公开入口 `solve` / `solve_with`，返回 `SolveStatus` + `Solution`
  （状态、变量取值、目标值、迭代数、失败原因）；非法模型返回 `NotSolved` 并带原因；
- `cmd/parse`：模型文件巡检 CLI（格式判定、规模统计与校验结论、`--manifest` 批量模式、
  `--solve` / `--relax` / `--max-rows` 求解开关、失败返回非零退出码）；
- CLI 与两个可运行示例，`moon test` 72 个测试全绿，CI 覆盖 Linux/macOS/Windows 与 wasm-gc/js 目标。

**当前内核的能力边界（明确写出来，不夸大）**：

| 支持 | 暂不支持（返回 `NotSolved` + 原因，绝不返回可疑解） |
| --- | --- |
| 连续变量、任意有限上下界、自由变量 | 整数 / 0-1 变量（M5；当前可用 `SimplexOptions::relaxed()` 求 LP 松弛） |
| `≤`、`≥`、`=` 任意混合，含负右端项 | 证书与 `verify` 独立校验器（M4） |
| min / max | 对偶单纯形热启动、presolve / postsolve（M3 剩余部分） |
| MPS / LP 文件读入与写出（M2） | MPS 的 `SC`/`SI` 半连续界、完整 `SOS` / `MARKER` 语义 |
| 行数 ≲ 200 的模型（稠密基逆的当前规模上限） | 更大规模需先落地稀疏 LU 基分解（M3 性能部分） |

**内核的一条硬规则**：声明 `Optimal` 之前，内核会用自己的矩阵独立重算行残差与非负性；
只要残差或负值超过容差，就返回 `NumericalFailure` 并给出测得的数值，而不是给出一个看起来合理的解。
求解报告里出现的数值失败正是这条规则生效的结果。

## 为什么需要它

MoonBit 生态已经有一批排产、排班、路由、装箱、约束模型库，但它们几乎全部是启发式或专用实现：
能给出“一个可行解”，给不出“离最优还有多远”，也读不进行业标准的模型文件。
精确组合优化的公共地基是 **LP 松弛 + 对偶界 + 分支定界**，而这块在 MoonBit 里是空的。

`moonopt` 要补的是这个地基：

- **能吃真实模型**：MPS（free / fixed）与 LP 格式读写，可以直接跑 Netlib / MIPLIB 数据集；
- **能解真实规模**：稀疏存储 + 修正单纯形（不是 `O(m·n)` 的整张 tableau）；
- **能给出保证**：对偶解 / Farkas 证书 / 无界射线，并附带独立校验器 —— 解错时校验会失败；
- **能被复用**：`presolve` / 对偶单纯形热启动 / 分支切割框架对外开放，供上层模型库调用。

## 与生态内既有实现的能力边界差异

选型阶段对 MoonBit 生态做过一次全量现状调研（mooncakes.io 已发布模块全集与 GitHub
`topic:moonbit` 全部仓库，方法与原始证据见 [`docs/related-work.md`](docs/related-work.md)）。
结论：**通用 LP/MILP 求解器与标准模型格式支持在该生态中不存在**。两个相关实现的差异如下
（事实性对照，不含评价）：

| 维度 | `Juwan-Hwang/moon-certified` 的 `math/simplex`、`math/ilp` | `Luna-Flow/linear-program` | **moonopt** |
| --- | --- | --- | --- |
| 可表达模型 | 仅 `max cᵀx, Ax ≤ b, x ≥ 0`（561 / 527 行，文件头原文） | 建模 + 标准化，稠密矩阵 | min/max、`≤`/`≥`/`=`、变量上下界、整数/0-1（分里程碑落地） |
| 模型文件输入 | 无（仅内存数组） | 无 | **MPS / LP 读写**（M2） |
| 单纯形 | 稠密 tableau + Bland | 稠密 tableau 两阶段 | **稀疏 CSC + 修正单纯形**（M3）、对偶单纯形（M3） |
| 对偶 / presolve | 无 / 无 | 无 / 无 | 对偶热启动（M3）/ presolve + postsolve（M3） |
| 证书与校验 | 无 | 无 | **最优性、Farkas、无界射线 + 独立 `verify`**（M4） |
| 交付形态 | 30+ 领域合集仓库中的一个模块 | 未发布到 mooncakes.io | 专注单库：CLI + CI + 基准报告 + 文档 + 发布 |
| 生态检索命中 | —— | —— | `MPS` / `revised simplex` / `dual simplex` / `presolve` / `Farkas` / `certificate` 在生态中命中数均为 **0** |

我们不追求广度，只做**窄而深 + 可验证**。与上述实现是互补与可对接关系，而非替换。

## 快速开始

```bash
moon add Freon793/moonopt   # 发布到 mooncakes.io 后可用
```

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

引入需要两个包：`Freon793/moonopt`（求解入口）与 `Freon793/moonopt/model`（模型构造）。

## 可运行示例与 CLI

```bash
moon run examples/production_plan    # 两产品生产计划，最优 21 at (3, 1.5)
moon run examples/transportation     # 产销平衡运输问题（全等式约束，走 Phase I），最优 11
moon run cmd/main                    # 打印两个示例 + 一个“当前不支持”的诚实示例
moon run cmd/parse -- <file.mps>     # 读模型文件，打印规模统计与校验结论
```

巡检与求解真实数据集（MIPLIB 2017，33 个实例）：

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File bench/fetch-instances.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File bench/report-parse.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File bench/report-solve.ps1 -Relax -MaxRows 200
```

`moon run cmd/main` 的实际输出（节选）：

```
moonopt 0.1.0-dev

== production plan
status     : Optimal
iterations : 2
objective  : 21
  x = 3
  y = 1.4999999999999998
```

> `1.4999999999999998` 是浮点表示的真实值（在 `1e-9` 相对容差内等于 1.5）。
> 面向人读的定点格式化属于报表层（M6），当前示例直接打印原始值，不做美化。

`solve` / `verify` / `fmt` / `bench` 等子命令随 M2–M6 落地，见 [`docs/roadmap.md`](docs/roadmap.md)。

## 项目结构

```
moonopt.mbt       公开入口：solve / solve_with、SolveStatus、Solution、SolveOptions
core/             数值与稀疏基础设施（容差比较、补偿求和、CSC 稀疏矩阵）
model/            模型层（变量、线性表达式、约束、目标、模型校验）
format/           MPS 与 LP 格式读写、解析错误定位
oracle/           参考实现：稠密两阶段单纯形（差分测试对照基准，非交付求解器）
simplex/          稀疏修正单纯形内核（M3 进行中：对偶单纯形与 presolve 待补）
presolve/         presolve 与 postsolve（M3）
verify/           证书校验器（M4）
mip/              分支定界与割平面（M5，受范围闸门约束）
cmd/main/         示例 CLI 与演示输出
cmd/parse/        模型文件巡检 CLI（解析报告使用）
examples/         可运行示例
bench/            数据政策、下载与报告脚本、报告
docs/             设计说明、技术路线图、生态现状调研
```

## 依赖

库包（`core` / `model` / `oracle` / `format` / 根包 `moonopt`）**不依赖任何第三方包**。
只有 `cmd/parse` 依赖官方 `moonbitlang/x` 的 `fs` 与 `sys`，用于读文件与取命令行参数。

## 开发

```bash
moon check --deny-warn
moon test --deny-warn
moon fmt && git diff --exit-code
moon info && git diff --exit-code
git config core.hooksPath .githooks   # 启用官方模板自带的 pre-commit（moon check）
```

CI（[`.github/workflows/check.yml`](.github/workflows/check.yml)）在 Linux / macOS / Windows 上执行
`moon check --deny-warn`、`moon fmt` + `git diff --exit-code`、`moon info` + `git diff --exit-code`、
`moon test --deny-warn`，另有两个 wasm-gc / js 目标的测试任务。`.mbti` 是接口合同，必须随代码提交。

## 数值策略（摘要）

- 统一使用**相对容差**比较（`core`），所有“零”判定都显式带容差；
- 求和走 Neumaier 补偿求和，避免规模上去后误差累积；
- 单纯形用 **Bland 规则**保证退化情形终止（M3 起叠加 Harris 两遍比值检验提升稳健性）；
- 求解结果一律如实报告状态：超出能力边界、迭代上限、不可行、无界都各自可区分，
  `NotSolved` 一定带原因，绝不静默返回错解。

## 参考文献（算法来源，代码为原创实现）

- G. B. Dantzig, *Linear Programming and Extensions*, 1963（单纯形法）
- P. M. J. Harris, *Pivot selection methods of the Devex LP code*, 1973（比值检验）
- R. G. Bland, *New finite pivoting rules for the simplex method*, 1977（防循环）
- I. Maros & G. Mitra, *Presolve reductions for LP*, 1996（presolve）
- R. E. Gomory, 1958；H. Marchand & L. A. Wolsey, *Aggregation and mixed integer rounding cuts*, 2001（割平面）
- J. Forrest & J. Tomlin, *Updated triangular factors of the basis*, 1972（基更新）

## 数据与许可

- 本项目以 **Apache-2.0** 发布（见 [`LICENSE`](LICENSE)）。
- 基准数据（MIPLIB 2017）**不由本仓库再分发**：仓库只提供下载脚本、清单与报告，
  具体来源与获取方式见 [`bench/README.md`](bench/README.md)。
  其中也说明了为什么没有直接使用 Netlib LP 测试集（其 `lp/data` 是私有压缩容器，不是 MPS）。
- 算法实现基于公开文献，代码为本项目原创，未移植任何第三方实现。
