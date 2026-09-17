# Freon793/moonopt

[![check](https://github.com/Freon793/moonopt/actions/workflows/check.yml/badge.svg)](https://github.com/Freon793/moonopt/actions/workflows/check.yml)

**把 MoonBit 的线性/整数优化从教学级稠密实现，推进到能与工业数据与公开基准对拍的工程内核。**

`moonopt` 的目标能力：标准模型互操作（MPS / LP）、稀疏修正单纯形与对偶单纯形、
presolve/postsolve、可复用的分支切割框架，以及**可被第三方独立校验**的最优性（对偶可行解）、
不可行性（Farkas）与无界（射线）证书。纯 MoonBit 实现，无 FFI 依赖。

> 状态：**v0.1.0-dev**，`M1`（基础层与模型层）、`M2`（标准模型输入）已落地，`M3` 进行中（完成标准已满足），`M4`（证书与独立校验器）已完成，
> `M5`（整数规划）进行中：分支定界骨架 + **每个松弛都由独立校验器复核**。这条复核先后拦下六次被拒证书，
> 每一次查下去都发现**内核**错了 —— 第二轮是两例假的"不可行"判定（Phase I 的容差边际判定、对偶单纯形的
> 越界结论），第三轮是 `noswot` 上的三处：对偶解在病态基上丢了精度（迭代精化修掉）、方向求解没有自检
> （会枢轴在一个连 `A·d = aⱼ` 都不满足的方向上，最后把一个有界节点报成无界）、非负性自检的尺度与校验器
> 不一致。三处都修完且 `noswot` 5000 节点 0 拒签，`noswot` 不再阻塞分支定界报告（见 CHANGELOG 与
> `docs/roadmap.md`）
> （稀疏修正单纯形、**稀疏 LU 基分解**、性能测量与优化、比值检验的可行性守卫、退化扰动、
> 内核规模与填充预算门禁、presolve/postsolve 与公开契约的默认化简路径均已完成；
> 对偶单纯形与 DeVex 定价待完成）：
> 可构建、可测试、CI 全绿，并已在 **MIPLIB 2017 的 32 个真实实例**上跑通解析报告
> （33 成功 / 0 失败，见 [`bench/parse-report.md`](bench/parse-report.md)）与求解报告
> （**20 个 LP 松弛求到最优、11 个超规模跳过、规模拒绝归零、0 个数值失败**；
> 基准口径**开启 presolve**，行数上限 1000、迭代上限 1200 —— 报告里另有 1 个 `iteration-limit`
> 是 `fast0507`，它在 507 条约束下需要上万次枢轴；
> 20 个重建解全部在原模型上通过行、界与目标值三项检查，20 项松弛值经 MIPLIB 官方最优值表
> 交叉校验、**0 违反**，见 [`bench/solve-report.md`](bench/solve-report.md)）。
> 尚未发布到 mooncakes.io。
> 里程碑划分、范围闸门与明确**不做**的内容见 [`docs/roadmap.md`](docs/roadmap.md)。

## 当前能力（M1、M2 已落地；M3 完成标准已满足；M4 已完成；M5 第一轮已落地）

已经可用并且有测试覆盖的部分：

- `core`：容差感知的数值比较（`approx_eq` / `approx_zero` / `approx_positive`）、
  Neumaier 补偿求和、**CSC 稀疏矩阵**（构造时排序/合并/丢结构零、按列访问、转置、稠密化、矩阵向量乘）；
- `model`：LP/MILP 模型层 —— 变量（上下界、整数标记）、线性表达式、约束（`≤` / `≥` / `=`）、
  目标（min/max）、模型校验（返回人类可读的问题列表）；
- `format`：**MPS 读取器与写出器**（free / fixed 布局、`RANGES` 展开、`MARKER` 整数块、
  free row 语义、`OBJSENSE` 扩展）与 **LP 格式读写**（目标、`Subject To`、`Bounds` 的各种写法、
  `Generals` / `Binary`），读→写→读 幂等；
- `simplex`：**稀疏修正单纯形内核** —— 稀疏 CSC 列存储、**稀疏 LU 基分解**
  （`P·B = L·U`，行主元相对阈值；`B x = b` 与 `Bᵀ y = c` 走三角求解，内存 `O(nnz + fill)`）、
  **乘积形式（eta）基更新**（每枢轴只追加一个稀疏 eta，因子仅在重新分解时重建）、
  Phase I（人工变量 + 驱逐）与 Phase II、**增益型定价**（按实测增益 `|r| · step` 选进入列，
  而不是只按检验数——检验数是改进的速率，不是改进本身）与 Bland 回退、
  **Harris 两遍比值检验**（带可行性守卫）、退化扰动、对偶值与检验数、
  不可行 / 无界 / 迭代上限 / 数值失败 / 超出规模各成一类状态；
  模型侧的上下界、自由变量（拆成正负两部分）与 `≤` / `≥` / `=` 混合约束都在内核内完成变换；
  迭代循环内不分配内存（对偶值、方向、基本成本都用共享 scratch buffer）；
- `presolve`：**模型化简与解还原** —— 空行/列消元、被界推定的冗余行、singleton 行转界、
  隐式界收紧、固定变量消元（目标贡献进 offset），以及把解还原回**原变量**并对照原模型检查
  （行、界、目标值三项）；证明不可行/无界时直接返回该判定而不调用内核；
- `oracle`：**稠密两阶段单纯形参考实现**，作为稀疏内核的差分测试对照基准（不是交付求解器）；
- `moonopt`：公开入口 `solve` / `solve_with`，返回 `SolveStatus` + `Solution`
  （状态、变量取值、目标值、迭代数、失败原因）；非法模型返回 `NotSolved` 并带原因；
  **默认先化简再求解并把解还原回原变量**（`SolveOptions { presolve: false }` 可关掉）；
- `verify`：**独立于求解路径的校验器** —— 原始可行性、对偶可行性、互补松弛、对偶间隙，
  以及 Farkas 不可行射线与无界射线（+ 可行起点）；只依赖 `core`/`model`，
  证书可序列化为 JSON 再从文件独立复核；
- `mip`：**分支定界**（M5 第一轮）—— 节点 = 父节点 + 一条收紧的界（沿链重建，不逐节点复制模型）、
  best-bound 排序、按最优值剪枝、对最分数整数变量二分；子节点**热启动**自父节点留下的基
  （界改动不动检验数，所以父基对偶可行，对偶单纯形只需修回可行性）；
  **每个松弛都在分支之前过一遍 `verify`**（被拒即停为 `Unverified`，绝不拿未被证实的答案去分支）；
  只有树穷尽才报 `Optimal`，节点预算到顶报 `NodeLimit` 并给出当前最优解与仍在界的下界，
  松弛无界报 `UnboundedRelaxation`（松弛的改善射线不含整数性，因此不声称模型无界），
  模型非法报 `Invalid`（不写成 `Infeasible`）；
  实测（native release，全部节点通过校验）：`flugpl` 12411 节点 / 目标 1201500（官方最优 1201500）、
  `khb05250` 7543 节点 / 106940226（官方 106940226）、`22433` 59 节点 / 21477（官方 21477）；
- `cmd/parse`：模型文件巡检 CLI（格式判定、规模统计与校验结论、`--manifest` 批量模式、
  `--solve` / `--relax` / `--presolve` / `--max-rows` / `--max-iterations` 求解开关、
  `--verify` / `--certificate` 证书校验、`--reoptimize` 热启动实测、
  `--mip --max-nodes` 分支定界并在报告里独立复核解的行/界/整数性，失败返回非零退出码）；
- CLI 与两个可运行示例，`moon test` 140 个测试全绿，CI 覆盖 Linux/macOS/Windows 与 wasm-gc/js 目标。

**当前内核的能力边界（明确写出来，不夸大）**：

| 支持 | 暂不支持（返回 `NotSolved` + 原因，绝不返回可疑解） |
| --- | --- |
| 连续变量、任意有限上下界、自由变量 | — |
| **整数 / 0-1 变量**（`mip` 分支定界，每个松弛过 `verify`；实测三个 MIPLIB 实例证到官方最优值） | 割平面与取整启发式（M5 后续）、整数无界性的证明（需要整数射线，当前只报 `UnboundedRelaxation`） |
| `≤`、`≥`、`=` 任意混合，含负右端项 | — |
| min / max | — |
| **对偶单纯形热启动**：`SimplexBasis` + `solve_model_with_basis`，改界后重解不再重建 Phase I（实测真实实例枢轴数 1–49 vs 冷启 21–1008） | 化简模型上的热启动（基与化简后模型同构时才能用） |
| **证书与独立校验器**（`verify`）：最优性（原始/对偶可行性、互补松弛、对偶间隙）、Farkas 不可行射线、无界射线 + 可行起点、证书 JSON、`cmd/parse --verify` / `--certificate` | 化简模型的乘子回映（证书现在只对**内核收到的模型**成立，即 `--verify` 走不化简的路径） |
| MPS / LP 文件读入与写出（M2） | MPS 的 `SC`/`SI` 半连续界、完整 `SOS` / `MARKER` 语义 |
| presolve：空行/列消元、冗余行、singleton 转界、隐式界收紧、固定变量消元 + 解还原（`solve` 默认开启，`--presolve`） | 系数强化、对偶固定、变量/行的重复与支配检测；整数模型不经化简（保持内核的拒绝语义） |
| 内核行数 ≤ 200000 的模型（`SimplexOptions::max_kernel_rows`；基用**稀疏 LU** 因子分解，内存 `O(nnz+fill)`） | 填充量由 `max_factor_entries` 预算约束；再往上走真正的限制是枢轴数与每次枢轴的实际增益，在"每个有限上界一行"的大实例上尤其明显（见 `bench/README.md`） |

**两个行数上限不要混淆**：`cmd/parse --max-rows N` 限制的是**模型约束数**（超过即
`solve=skipped`）；内核自己的门禁 `max_kernel_rows` 限制的是**内核行数**。有限上界**不再**占行
（有界变量枢轴把上下界当界用，比值检验两个方向都读），所以内核行数通常就是模型约束数；
唯一还会放大它的是"下界无界的自由变量 + 有限上界"——`p − n ≤ ub` 是两个列之差，没有单列界可用，
只能留成显式行。实测的极端例子是 `fast0507`：507 条约束、63009 个 0/1 变量，
在上界还是行的年代内核规模是 **63516 行**（稠密基逆时代约 **30.8 GB**，native 会以访问冲突
exit `0xC0000005` 退出并因巨量换页拖垮整机），**现在内核规模是 489 行**。

**内核行数为什么值得盯**：不仅因为内存。实测枢轴数跟着内核行数走、与列数几乎无关
（小规模覆盖型 LP 探针：20 / 40 / 120 / 240 行 → 57 / 137 / 632 / 2220 次枢轴；
20 行时 100 列与 900 列的枢轴数是 57 与 35），而去掉那 63001 行上界行让 `fast0507`
每次枢轴的代价从约 **47.5 ms 掉到约 2.4 ms**，Phase I 首次在 45000 次枢轴内跑完
（此前 20000 次上限下 Phase I 还停在人工和约 180）。

**规模上限的口径已经变了**：基不再求逆，而是做稀疏 LU 因子分解（`P·B = L·U`），
内存从 `O(m²)` 变成 `O(nnz + fill)`，`max_kernel_rows` 默认因此从 4000 抬到 **200000**。
填充量（fill）是稀疏分解里唯一无法事先预测的量，所以另有 `max_factor_entries`（默认 2×10⁷）
作为预算：超预算就让分解失败，而不是无上限分配。实测：`30n20b8`（presolve 后 11591 行）
**16 秒求到最优**；`danoint` 在默认 20000 迭代上限下 **3716 次枢轴、11.7 秒求到最优**
（目标值 `62.6372804184694`，重建解在原模型上可行）；`fast0507`（内核 489 行）**能跑完 Phase I**，
Phase II 仍是最大的一道墙 —— 而它的成因在**定价**：Dantzig 的检验数是改进的速率、不是改进本身，
覆盖最多未覆盖行的列速率最大、却常被第一行接近紧的约束卡住。改成按**实测增益** `|r| · step`
选列（`gain_candidates`，每迭代只测一个有界候选集）之后，同一个枢轴预算下：
20000 次枢轴的内核目标值从 165.115 降到 **156.778**，45000 次到 **133.032**
（Dantzig 要跑到 250000 次枢轴才到 160.353）；1000 行口径全清单里
`bienst1` / `bienst2` 因此从 `iteration-limit` 变成求到最优。代价是每次枢轴约 2.4 → 14 ms。
量级与取舍见 [`bench/README.md`](bench/README.md) 与 [`docs/roadmap.md`](docs/roadmap.md)。

**公开入口的默认路径**（`solve` / `solve_with`）：先化简（`presolve`，默认开启），再交给内核算，
然后把解还原回原变量。还原结果必须**同时**通过三项检查才以 `Optimal` 返回 —— 原模型的行、
原模型的界、以及用原模型目标向量重算出的目标值与报告值一致；任何一项不过就返回 `NotSolved`
并附上实测违反量。化简能自行证明不可行或无界时直接返回该判定，不启动内核。

**整数模型的入口**：`mip::solve_mip`（以及 `cmd/parse --mip`）走分支定界；顶层公开入口 `Model::solve`
目前仍对整数变量返回 `NotSolved` + 原因，**且依然不做化简** —— 化简是否碰巧把所有整数变量定住，
不能决定内核的拒绝语义。把 M5 接进顶层入口（`SolveStatus` 增加节点预算状态）是 M5 后续的一步。

**分支定界的取舍**（M5 第一轮）：① 节点不复制模型，只存"父节点 + 一条收紧的界"，求解时沿链从根重建 ——
一次界改动的代价是 `O(depth)` 而不是 `O(模型)`；② 子节点**热启动**自父节点的最优基，
理由与 M3 的对偶单纯形同源：界改动不动检验数，父基对偶可行，只差原始可行性；
③ 分支前**每个松弛都过 `verify`**，被拒就停下报 `Unverified`，而不是拿一个没人能复核的答案去分支 ——
这条规则在本轮抓到过真 bug（见 CHANGELOG 的比值检验负步长）；
④ 只有树穷尽才叫 `Optimal`，节点到顶叫 `NodeLimit` 并给出"当前最优解 + 仍在界的最好下界"这一对数，
松弛无界叫 `UnboundedRelaxation`（松弛的改善射线不含整数性，不能当模型的结论）。

**内核的一条硬规则**：声明 `Optimal` 之前，内核会用自己的矩阵独立重算**按行缩放的行残差**
（`|Ax−b| / (1+|b|+Σ|a·x|)`，不计人工列）与缩放的负值，只要超过容差就返回 `NumericalFailure`
并给出测得的数值，而不是给出一个看起来合理的解。这条规则生效过两次：`blend2` 的绝对残差
2.5e-7 是舍入误差（改用缩放口径后恢复为最优），而 `noswot` 的缩放负值 2.0e-4 是真实违反 ——
后者是比值检验把基本变量推出可行性下限造成的，已由守卫式 Harris 修掉（先模拟这一步，
若破坏可行性则退回严格最小比值行）。

**基准运行方式**：内核基准一律用 **native release** 目标（`moon run --target native --release`）。
同一实例实测比默认 wasm 目标快约 6 倍（`mod010`：wasm 119.6s / native release 18.8s），
`bench/report-solve.ps1` 已按此运行。**排查崩溃或用例复现时反过来走 wasm 目标**：
它带边界检查，越界会给出 panic 信息而不是访问冲突，也不会造成内存破坏。

**数值失败的三道防线**：① **退化扰动**（`degeneracy_perturbation`，默认 1e-12）：求解用的右端项按
确定性模式加 `ε·(1+|bᵢ|)` 的微扰以打破退化平局，而残差自检始终对**未扰动**右端项测量 ——
这是实测出来的根因修复（noswot 系数幅度 0.25–21、跨度比 84，是良态模型，病根是退化不是尺度；
扰动让它在 158 次迭代直达最优，不再需要任何恢复）。② 比值检验选出的主元若小于该次方向最大元的
`pivot_relative_tolerance`（默认 1e-8），内核先重建基逆、重做比值检验再枢轴。
③ 仍以数值失败结束时，从初始基**重启一次**，改用 Bland 规则并缩短重新分解间隔，恢复结果同样要过
残差自检，仍失败才返回**原始失败**。恢复成功的运行会在消息里如实标注
（`recovered from a numerical failure by restarting with Bland's rule (...)`）：
"换了一条路走通"和"原来那条路是对的"不是一回事。当前基准报告里恢复次数为 **0**。

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
| 证书与校验 | 无 | 无 | **最优性、Farkas、无界射线 + 独立 `verify`**（M4）；分支定界对**每个节点松弛**都过校验（M5） |
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
moon run cmd/parse -- <file.mps> --presolve --relax --max-rows 300
```

`--presolve` 先做模型化简（空行/列、冗余行、singleton 转界、隐式界收紧、固定变量消元），
打印每实例的化简前后规模，然后求解**化简后**的模型并把解还原回原变量，
最后打印还原解在**原模型**上的最大行/界违反（可行才标 `(feasible)`）。

巡检与求解真实数据集（MIPLIB 2017，32 个实例）：

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File bench/fetch-instances.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File bench/report-parse.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File bench/report-solve.ps1 -Relax -MaxRows 1000 -MaxIterations 1200 -Presolve
```

`moon run cmd/main` 的实际输出（节选）：

```
moonopt 0.1.0-dev

== production plan
status     : Optimal
iterations : 2
objective  : 21.00000000002238
  x = 3.0000000000026206
  y = 1.5000000000023193
```

> 这些末位偏差是**退化扰动**留下的脚印（`degeneracy_perturbation`，默认 1e-12）：内核给求解用的
> 右端项加了一个远小于可行性容差的微扰来打破退化平局，因此结果在 1e-12 相对量级上与精确值不同，
> 而残差自检始终针对**未扰动**的右端项测量 —— 也就是说解仍然对调用方写下的模型可行。
> 面向人读的定点格式化属于报表层（M6），当前示例直接打印原始值，不做美化。

`solve` / `verify` / `fmt` / `bench` 等子命令随 M2–M6 落地，见 [`docs/roadmap.md`](docs/roadmap.md)。

## 项目结构

```
moonopt.mbt       公开入口：solve / solve_with、SolveStatus、Solution、SolveOptions（默认开启 presolve）
core/             数值与稀疏基础设施（容差比较、补偿求和、CSC 稀疏矩阵）
model/            模型层（变量、线性表达式、约束、目标、模型校验）
format/           MPS 与 LP 格式读写、解析错误定位
oracle/           参考实现：稠密两阶段单纯形（差分测试对照基准，非交付求解器）
simplex/          稀疏修正单纯形内核（M3 进行中：对偶单纯形待补）
presolve/         模型化简与解还原（M3；公开接口可单独使用）
verify/           独立校验器：最优性、Farkas、无界射线 + 证书 JSON（M4，不依赖 simplex）
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
