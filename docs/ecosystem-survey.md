# 外部生态横评与可借鉴项（调研于 2026-09-20）

`docs/related-work.md` 调研的是 **MoonBit 生态内部**（有没有人做过、能不能对接）；这一份是它的对外补充：
本项目**之外**谁在做内核、谁在定标准、哪些东西只能读不能拿。目的只有三件事 ——
**借什么（标准）、读什么（公开文档与论文）、不碰什么（代码与依赖）**。

## 调研方法（以及它的限度）

| 步骤 | 做法 | 结果 |
| --- | --- | --- |
| 1 | 公开检索生态构成与许可证线索（搜索片段，非原文） | 见"生态形态"与"许可证"两节 |
| 2 | 读公开论文/标准页面（VIPR 证书规范、MOI 状态码文档的公开条目） | 见"★ 最值钱的借鉴"一节 |
| 3 | **读许可证原文** | **本轮没做到**：本机 `raw.githubusercontent.com` 域名解析失败（`The remote name could not be resolved`），只能拿到检索片段与第三方索引页 —— 因此下表的许可证一列**除已注明出处者外一律标"待核对"** |

**限度本身要写下来**：本轮**没有为任何结论引入外部依赖**（架构决策：纯 MoonBit、零 FFI、
wasm / wasm-gc / js / native 四目标），所以没有任何一条许可证结论被用于实际决策 ——
它们只在"将来若要对拍、或要借用某个公开格式"时才有意义。
本项目现有的外部对拍用的是**公开数据集与官方最优值表**（MIPLIB 2017），见 `bench/README.md`。

## 生态形态：一句话

**C/C++ 做内核，其它语言基本只做建模层与绑定。**

| 层 | 代表 | 说明 |
| --- | --- | --- |
| 内核主战场（C/C++） | HiGHS、SCIP、CBC/Clp、GLPK | 数值稳定性的积累都在这一层 |
| 商用天花板 | Gurobi / CPLEX / Xpress / Mosek | 只看公开文档与白皮书，不作性能对标 |
| Python 生态 | PuLP / Pyomo / CVXPY / `scipy.optimize` / OR-Tools / PySCIPOpt | **胶水 + 建模层**，自己不写内核；`scipy.optimize` 的 `linprog`/`milp` 默认后端已是 HiGHS |
| 接口标准 | Julia 的 JuMP + MathOptInterface | 一个模型换任意求解器的典范 |
| **纯语言内核（少数派）** | Rust：Clarabel（锥优化，已进 CVXPY 生态）、microlp（MILP）；Java：ojAlgo | Clarabel 是"纯语言内核能被主流生态采纳"的先例，对本项目路线的可行性是外部背书 |
| 几乎没有 | JavaScript / TypeScript（多为 wasm 绑定）、Go、.NET | 没有原生 LP/MILP 内核 |

## ★ 最值钱的借鉴不是代码，是标准

1. **MathOptInterface 的状态码体系**（队列 7）。MOI 用十来年把"一个求解结果到底处于什么状态"
   分类清楚：`OPTIMAL` / `INFEASIBLE` / `INFEASIBLE_OR_UNBOUNDED` / `DUAL_INFEASIBLE` /
   `ALMOST_OPTIMAL` / `NODE_LIMIT` / `SOLUTION_LIMIT` / `INTERRUPTED` / `NUMERICAL_ERROR` …
   本项目自创了公开 `SolveStatus`（5 类）、内核 `SimplexStatus`（6 类）与 `MipStatus`（若干）。
   **做法：逐条对照、只写审计结论，不擅自改公开枚举**（公开面是契约，`.mbti` 的任何变化都要在提交信息里说明）。
2. **VIPR（ZIB 的整数规划证书格式 + 独立检查器）**（队列 8）。本项目最核心的卖点是"可被第三方
   独立校验"，而对齐公开标准是把这件事从"自证"升级为"标准背书"的唯一路径。公开材料：
   [证书规范 `cert_spec_v1_1.md`](https://github.com/ambros-gleixner/VIPR)、
   [scipopt/vipr 参考实现](https://github.com/scipopt/vipr)。
   **做法：先回答三个问题**（三类证书各对应 VIPR 的哪一部分、能否在不削弱自检纪律的前提下导出、
   代价与收益），**本轮不实现**。
3. **JuMP/MOI 的"建模层 ↔ 求解层"分离**（长期参考）。上层 MoonBit 排产/排班/路由库要接本项目，
   需要一个稳定的求解器接口而不是绑死内部类型。本项目的包边界（`core` / `model` / `simplex` /
   `presolve` / `verify` / `mip`，根包只做编排）已经在这个方向上，**可作为设计审查的参照系，本轮不动**。

## 许可证与可读性（逐条标注）

| 项目 | 本轮根据什么写 | 状态 |
| --- | --- | --- |
| HiGHS | 公开页面与检索片段普遍记 **MIT**；文档/架构/基准纪律可读 | **待核对**（未读到 LICENSE 原文） |
| GLPK | 普遍记 **GPL-3.0**（**传染性**） | **待核对**，但**不读代码**这条不依赖它是否核对 —— 见"红线" |
| SCIP | 普遍记 **ZIB Academic License**（商用受限）；论文、算法描述与 VIPR 格式是公开的 | **待核对**（论文与格式可读不受影响） |
| CBC / Clp（COIN-OR） | 普遍记 EPL 系（**具体版本未核**） | **待核对** |
| OR-Tools | 普遍记 **Apache-2.0** | **待核对** |
| JuMP / MathOptInterface | 普遍记 **MPL-2.0** | **待核对** |
| PaPILO | 未核；有一条第三方发行版审查页线索（Debian DFSG review） | **待核对** |
| VIPR | 未核（**格式与规范文档的公开可读性**是本项目关心的那一条，与代码许可证分开） | **待核对** |
| microlp / Clarabel / ojAlgo | 未核 | **待核对** |

**红线（与许可证是否核对无关，先写在前面）**：本项目**不移植任何第三方代码**，
三条路只走 —— ①读公开论文与算法描述、自己实现；②读公开标准与格式（MPS 规范、证书格式、状态码约定）；
③用公开数据集与官方最优值表对拍。**GPL 类传染性许可证的代码一律不并入**（本项目是 Apache-2.0），
学术许可的求解器代码同样不抄（论文与格式公开可读）。

## ◇ 与当前卡点的对应关系（文献里已有答案的，别自己摸）

| 卡点 | 已知做法 | 本项目这一轮的状态 |
| --- | --- | --- |
| Farkas 射线构造（队列 4） | 从 Phase I 状态显式导出满足乘子符号约定的射线；或从对偶单纯形状态取对偶射线 | 未做（M4 唯一未验证项，仍需"自带自检"的构造 + 一个退化用例） |
| 割的价值与用法（队列 2） | "把界抬得最高的割不是证明最快的割"在该族实现里是**已被记录的已知张力**，解法在**用法层**（割池、老化与清除、根分离轮次、节点分离触发） | 本项目第十六~十八轮实测出同一条张力，选择规则这条线已关闭；下一步按用法层设计 |
| 定价（队列 9） | DeVex = Harris (1973)；steepest-edge = Forrest & Goldfarb (1992) | 未做（本项目已有增益定价，两者可按实例规模对比后决定） |
| presolve 归约族（队列 9） | Andersen & Andersen (1995) 是 LP presolve 归约清单的经典来源 | 未做（现有：空行/列、冗余行、singleton、隐式界、固定变量消元） |
| 精度自检放在哪里 | MINOS 的 `Check Frequency`（默认 60，见 [Aimms 的 MINOS 参数文档](https://github.com/aimms/user-guide/blob/master/aimms-ide/Solvers/MINOS/Advanced/MINOS_Advanced_-_Check_Frequen.rst)）与 NAG `e04mf` 的 "every i-th minor iteration after the most recent basis factorization, a numerical test is made to see if the current solution x is feasible"（[NAG 手册](https://support.nag.com/numeric/cl/nagdoc_cl26.0/nagdoc_cl26.pdf)）：**周期性检查 + 其余迭代靠便宜的局部判据** | **已用本轮实测否掉"照搬降频"**：本项目已有局部判据（主元元素相对阈值），而降频方向残差自检的收益是 −0.05%（噪声内）⇒ 不引入检查频率选项；见 `CHANGELOG.md` |

## VIPR：三个问题的答案（队列 8；**已核对原文 `cert_spec_v1_1.md`**）

VIPR 是 ZIB 为**整数规划结果**定的公开证书格式，带独立检查器；公开材料是证书规范
[`cert_spec_v1_1.md`](https://github.com/ambros-gleixner/VIPR) 与
[scipopt/vipr 参考实现](https://github.com/scipopt/vipr)。**本轮读到了原文**（经 GitHub API 取下
`cert_spec_v1_1.md`，247 行；本仓库不分发副本），下面三条按原文结论，并**更正**此前的一处记录：

1. **三类证书的映射（已核对）**：VIPR 文件由 `VAR` / `INT` / `OBJ` / `CON` / `RTP` / `SOL` / `DER` 七节组成，
   其中 `RTP` 二选一 —— `RTP infeas`（证不可行）或 `RTP range lb ub`（证最优值落在给定区间）。于是：
   本项目的**最优性**证书对应 `RTP range lb ub` + `SOL`（可行解；最小化下至少一个解的目标值不超过 `ub`）
   + `DER`（最后一条必须是**假设集为空**且支配 `OBJ ≥ lb` 的约束）；
   **Farkas 不可行**对应 `RTP infeas` + `DER`（最后一条必须是**假设集为空的矛盾式**，即 `0 ≥ β, β > 0` 这类）；
   而**无界射线在规范里没有对应部分** —— 全文 `unbounded` 出现 **0 次**，这与此前的猜测一致：
   VIPR 只回答"最优值区间"或"不可行"两种结论。
2. **能否在不削弱自检纪律的前提下导出（已核对，其中一条要更正）**：**更正**此前记的
   "VIPR 只要求解与界、不要求割的来源，所以导出会比本项目自检更弱" —— 1.1 版的 `DER` 节带
   `reason` 关键字：`asm`（假设）、`lin`（约束的**合适线性组合**）、`rnd`（**舍入**）、`uns`（假设消去），
   且对线性组合有符号要求（`λⱼ·s(Cⱼ) ≥ 0` 全线一致或全线 ≤ 0，`s(C)` 由 `≥`/`=`/`≤` 取 `1`/`0`/`−1`）——
   **这与本项目的乘子符号约定同形，割也能按"由哪一行舍入而来"导出成一条 `rnd` 派生约束**。
   真正卡住导出的是**算术域**：VIPR 的数是**有理数**（有限小数或分数），检查器按精确算术工作，
   而本项目的证书是**浮点 JSON + 带容差的判据**（乘子符号、互补松弛、对偶间隙都按尺度量）。
   要导出就得先决定"有理化还是带区间"，而**有理化会把浮点证书变成另一份主张**，必须重新论证它成立 ——
   这正撞上本项目最硬的那条纪律（*自检的尺度必须与它所替代的检查一致*）。另一处语义差异是
   `RTP` 证的是**最优值区间**，而不是"某个基的对偶解"。
3. **代价与收益（已核对）**：代价是一个**有理数算术子系统**（纯 MoonBit 可做，但不是小工程）+ 导出映射 +
   对"有理化后仍然成立"的重新论证；收益是第三方可以用**现成工具**复验，即把"可被独立校验"
   从自证升级为标准背书。**本轮不改任何代码**：先把第 2 条的有理化论证做出来，再决定是否导出；
   这条留在 `docs/roadmap.md` 的"尚未完成"里。

## 与生态内既有实现的差异

选型期做过一次全量现状调研（mooncakes.io 已发布模块全集与 GitHub `topic:moonbit` 全部仓库，
方法与原始证据见 [`related-work.md`](related-work.md)）。结论：**通用 LP/MILP 求解器与标准模型格式支持
在该生态中不存在**。2026-09-21 用 `moon search` 与 `moon view` 复核过一次，两个最相关的实现如下
（事实性对照，不含评价；复核结论：`Luna-Flow/linear-program` **未发布到注册表**，
`moon view` 返回 404，`Juwan-Hwang/moon-certified` 的 `math/simplex` 公开 API 为
`SimplexResult { Optimal(Array[Double], Double) | Infeasible | Unbounded }` + `solve(c, A, b)`）：

| 维度 | `Juwan-Hwang/moon-certified` 的 `math/simplex`、`math/ilp` | `Luna-Flow/linear-program` | **moonopt** |
| --- | --- | --- | --- |
| 可表达模型 | 仅 `max cᵀx, Ax ≤ b, x ≥ 0`（561 / 527 行，文件头原文） | 建模 + 标准化，稠密矩阵 | min/max、`≤`/`≥`/`=`、变量上下界、整数/0-1 |
| 模型文件输入 | 无（仅内存数组） | 无 | **MPS / LP 读写** |
| 单纯形 | 稠密 tableau + Bland | 稠密 tableau 两阶段 | **稀疏 CSC + 修正单纯形**、对偶单纯形热启动 |
| 对偶 / presolve | 无 / 无 | 无 / 无 | 对偶热启动 / presolve + postsolve |
| 证书与校验 | 无 | 无 | **最优性、Farkas、无界射线 + 独立 `verify`**；分支定界对**每个节点松弛**都过校验 |
| 交付形态 | 30+ 领域合集仓库中的一个模块 | 未发布到 mooncakes.io | 专注单库：CLI + CI + 基准报告 + 文档 + 发布 |
| 生态检索命中 | —— | —— | `MPS` / `revised simplex` / `dual simplex` / `presolve` / `Farkas` / `certificate` 在生态中命中数均为 **0** |

`moon search` 的**模糊匹配**要注意口径：搜 `simplex` 会命中一批**单纯形噪声**（图形学）库，
搜 `mip` 会命中与本领域无关的合集模块；判断"是否重合"要看**包级 API**，而不是模块名或关键词命中数
（`milp`、`presolve` 两个关键词的命中数各为 1，就是本项目自己）。

我们不追求广度，只做**窄而深 + 可验证**：与上述实现是互补与可对接关系，而非替换。

## ⊗ 反面教材 / 谨慎借鉴

- GLPK 的全局状态与单文件风格不适合现代项目（**只读论文与文档**）；
- **LP 格式没有正式规范**（CPLEX 是事实标准），各家对边角情况的处理不同 ——
  可以对照 HiGHS/CBC 的解析器处理边界，但**别把某一家的怪癖当标准**；
- 不要用商用求解器的性能作为本项目的目标：本项目的定位是"**生态内的精确内核 + 可独立校验**"，
  不是性能对标。

## 这份调研改变了什么

**没有改变任何一行代码**。它改变的是三件事的判断依据：①队列 7/8 的做法有标准可循（先审计/先回答三个问题，
而不是先写代码）；②队列 2/4/9 的下一步应该按文献的分层（用法层、Phase I 状态导出、归约族清单）走，
而不是在"选择规则"这一层再打转；③**依赖边界不动** —— 外部求解器只作设计参考与对拍参照，
不得变成运行时依赖（见 `AGENTS.md` 的架构约束与 `docs/design.md`）。

**2026-09-21 复核对齐**：VIPR 一节从"待核对"改成"已核对"（原文 `cert_spec_v1_1.md` 已读，并更正一处：
1.1 版有 `rnd` / `lin` reason，割的推导有对应表达，真正的卡点是**有理算术域**而不是"不要求割的来源"）；
生态内两个相关实现的现状也复核过（一个的公开 API 已取到，另一个确认未发布到注册表）。
**这一轮同样没有改变任何一行代码** —— 需要精确算术的导出属于路线图上的候选，不在本轮范围内。
