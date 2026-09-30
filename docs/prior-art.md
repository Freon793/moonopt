# 生态调研：有没有同类实现、借什么标准、不碰什么

本文件记录选型期做的调研与它的限度，回答三个问题：MoonBit 生态里有没有通用 LP/MILP 求解器（会不会
重复造轮子）、生态外有哪些**公开标准**值得对齐、哪些东西只能读不能拿。

## 生态内的检索

| 步骤 | 做法 | 结果 |
| --- | --- | --- |
| 1 | 枚举 mooncakes.io 已发布模块全集（本机 registry 索引 `~/.moon/registry/index/user/*.index`） | 2470 个模块（含描述、关键词、发布时间） |
| 2 | 枚举 GitHub 全站 `topic:moonbit` 仓库 | 304 个仓库 |
| 3 | `moon search` 关键词核验 | `milp` → 无结果；`simplex` → 只有图形学噪声与一个零和博弈专用实现 |
| 4 | GitHub 仓库检索 | `moonbit+simplex` = 0；`moonbit+MPS+solver` = 0；`moonbit+linear programming` = 1 |
| 5 | 生态源码与描述全文关键词命中 | `revised simplex`、`sparse simplex`、`dual simplex`、`bounded variable simplex`、`Farkas`、`optimality certificate`、`infeasibility certificate`、`MPS format`、`presolve`、`branch-and-cut`、`LU factorization`、`interior point` 命中数均为 **0** |

**结论：通用 LP/MILP 求解器与标准模型格式支持在该生态中此前不存在。**

`moon search` 的模糊匹配要注意口径：搜 `simplex` 会命中一批图形学的"单纯形噪声"，搜 `mip` 会命中与本领域
无关的合集模块；判断"是否重合"要看**包级 API**，而不是模块名或关键词命中数。

### 两个最相关的既有实现

| 维度 | `Juwan-Hwang/moon-certified` 的 `math/simplex`、`math/ilp` | `Luna-Flow/linear-program` | **moonopt** |
| --- | --- | --- | --- |
| 可表达模型 | 仅 `max cᵀx, Ax ≤ b, x ≥ 0`（561 / 527 行，文件头原文） | 建模 + 标准化，稠密矩阵 | `min`/`max`、`≤`/`≥`/`=`、变量上下界、整数 / 0-1 |
| 模型文件输入 | 无（只在内存里传数组） | 无 | MPS / LP 读写 |
| 单纯形 | 稠密 tableau + Bland 规则 | 稠密 tableau 两阶段 | 稀疏 CSC + 修正单纯形、稀疏 LU、对偶单纯形热启动 |
| 对偶 / presolve | 无 / 无 | 无 / 无 | 对偶热启动 / presolve + postsolve |
| 证书与校验 | 无 | 无 | 最优性、Farkas、无界射线，加独立 `verify`；分支定界对每个节点松弛都过校验 |
| 交付形态 | 30+ 领域合集仓库里的一个模块 | 未发布到 mooncakes.io（`moon view` 返回 404） | 单库：CLI + CI + 基准报告 + 文档 + 发布 |

`Juwan-Hwang/moon-certified` 的公开 API 是 `solve(c, A, b)` 加
`SimplexResult { Optimal(Array[Double], Double) | Infeasible | Unbounded }`。它不能表达等式或 `≥` 约束、
变量上下界、自由变量与最小化（要使用者自己变换），也没有模型文件输入、对偶、presolve 与证书。

本项目与它们是互补与可对接关系，不是替换：补的是**内核与外层契约**——标准模型互操作、稀疏修正单纯形
与稀疏 LU、presolve / postsolve、可独立校验的证书、分支定界与带证明的割。

## 生态外：谁做内核、谁定标准

C/C++ 做内核，其它语言基本只做建模层与绑定：内核主战场是 HiGHS、SCIP、CBC/Clp、GLPK，商用天花板是
Gurobi / CPLEX / Xpress / Mosek（只读公开文档，不作性能对标），Python 生态（PuLP、Pyomo、CVXPY、
`scipy.optimize`、OR-Tools）是胶水与建模层。纯语言实现是少数派，Rust 的 Clarabel 是"纯语言内核能被主流
生态采纳"的先例。

值得对齐的是**标准**而不是代码：

1. **MathOptInterface 的状态码体系**（JuMP 生态）把"一个求解结果到底处于什么状态"分类清楚。本项目自创了
   公开 `SolveStatus`（5 类）、内核 `SimplexStatus`（6 类）与 `MipStatus`（6 类），逐条对照的结论写在
   [`api.md`](api.md)：只有一条是实质差异（MOI 有 `ITERATION_LIMIT`，本项目没有把它单列成公开状态），
   其余要么同义、要么对应"功能不存在"，要么是刻意的合并。**只记录审计结论，不擅自改公开枚举**。
2. **VIPR**（ZIB 为整数规划结果定的证书格式，带独立检查器）。公开材料：证书规范
   [`cert_spec_v1_1.md`](https://github.com/ambros-gleixner/VIPR) 与
   [scipopt/vipr 参考实现](https://github.com/scipopt/vipr)。读原文（247 行）之后的三条结论：
   - **映射关系**：VIPR 文件由 `VAR` / `INT` / `OBJ` / `CON` / `RTP` / `SOL` / `DER` 七节组成，`RTP` 二选一
     （`RTP infeas` 证不可行，或 `RTP range lb ub` 证最优值落在区间内）。本项目的最优性证书对应
     `RTP range` + `SOL` + `DER`，Farkas 不可行对应 `RTP infeas` + `DER`；**无界射线在规范里没有对应部分**
     （全文 `unbounded` 出现 0 次）——它只回答"最优值区间"或"不可行"两种结论。
   - **导出的真正卡点是有理算术，不是割的来源**：1.1 版的 `DER` 节带 `reason` 关键字（`asm` / `lin` /
     `rnd` / `uns`），线性组合有符号要求，**与本项目的乘子符号约定同形**，割也能按"由哪一行舍入而来"
     导出成 `rnd` 派生约束。卡住的是算术域：VIPR 的检查器按精确有理数工作，而本项目的证书是浮点 JSON 加
     带容差的判据；有理化会把证书变成另一份主张，必须重新论证它成立。
   - **代价与收益**：代价是一套有理数算术子系统加导出映射，收益是第三方能用现成工具复验。要动之前先把
     有理化的论证做出来。
3. **建模层与求解层分离**（JuMP/MOI 的长期参照）：本项目的包边界（`core` / `model` / `simplex` /
   `presolve` / `verify` / `mip`，根包只做编排）已经在这个方向上。

## 许可证与红线

**红线（与许可证是否逐条核对无关）**：本项目**不移植任何第三方代码**，只走三条路——读公开论文与算法
描述然后自己实现、读公开标准与格式（MPS、证书格式、状态码约定）、用公开数据集与官方最优值表对拍。
GPL 类传染性许可证的代码一律不并入（本项目是 Apache-2.0）。

调研时的许可证信息来自公开页面与检索片段，**没有逐条读到 LICENSE 原文**（当时本机 `raw.githubusercontent.com`
解析失败），因此这里不复述具体条款：反正结论不依赖它们——没有任何外部依赖被引入架构（纯 MoonBit、
零 FFI），这些许可证只有在"将来要与某个工具对拍、或借用某个公开格式"时才需要再核对一次。

## 这份调研改变了什么

没有改变任何一行代码。它改变的是判断依据：状态码与证书格式**有标准可循**（先审计、先回答可行性与代价，
而不是先写代码）；外部求解器只作设计参考与对拍参照，不得变成运行时依赖；现有的外部对拍只用公开数据集
与官方最优值表，见 [`../bench/README.md`](../bench/README.md)。
