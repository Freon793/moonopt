# 公开 API 契约

本文件是**面向调用方的契约**：每个包对外承诺什么、什么情况下返回哪个状态、哪些字段在哪些状态下有意义。
它只写代码里已经成立的事——`.mbti` 里出现的就是契约，`.mbti` 里没出现的就是内部实现。
每条规则后面给出可复核的证据：测试文件、`bench/` 里的报告行，或一条可直接跑的命令。

> 生成 `.mbti` 的命令是 `moon info`。任何一处公开面变化都会让 `.mbti` 出现 diff，
> 这是本项目的"承诺面"闸门：提交前看 `.mbti` 有没有意外变化。

## 顶层包 `Freon793/moonopt`（`moonopt.mbt`）

```moonbit
pub fn solve(model : @model.Model) -> Solution
pub fn solve_with(model : @model.Model, options : SolveOptions) -> Solution

pub(all) struct SolveOptions { max_iterations, presolve, max_nodes, cut_rounds }
pub struct Solution { status, values, objective, iterations, nodes, bound, gap, message }
pub(all) enum SolveStatus { Optimal, Infeasible, Unbounded, NodeLimit, NotSolved }
```

**契约（每条都是"调用方能依赖的承诺"）**

| 规则 | 说明 | 证据 |
| --- | --- | --- |
| 整数模型走分支定界，**不做化简** | 答案不能取决于化简碰巧定住了什么；`presolve` 选项对整数模型不生效 | `moonopt_test.mbt`（根目录）；`cmd/parse` 在整数模型上打印 `mip=presolve-skipped(...)` |
| 只承认搜索证明过的结论 | `MipStatus::Optimal`/`Infeasible` → 同名公开状态；节点预算到顶 → `NodeLimit` | `moonopt_test.mbt` |
| 三类情况一律 `NotSolved` 并带原话 | 松弛无界（改善射线不含整数性）、证书被拒（那是关于内核的陈述，不是关于模型的结论）、模型非法；**另加**"量到违反却写不出不可行证书"——Phase I 的人工和不足以解释它要证明的违反量时内核报 `NumericalFailure`（`CHANGELOG.md` 第二十三轮） | 同上 |
| `values` 非空时才有 `objective` | 预算到顶且没找到整数点时 `objective` 为 0，`message` 用文字说"还没有整数点" | `cmd/parse` 的 `"(no integer point yet)"`；`moonopt_test.mbt` |
| `bound`/`gap` 在所有路径同义 | 线性求解下 `bound = objective`、`gap = 0`（线性解就是它自己的界）；`NodeLimit` 下是仍在开的界 | `moonopt_test.mbt` |

### 状态体系与 MathOptInterface 的逐条对照（审计于 2026-09-20；**只记录，不改公开枚举**）

外部标准参照是 MathOptInterface（JuMP 生态）的 `TerminationStatusCode`：它用十来年把"一个求解结果
到底处于什么状态"分类清楚。本项目自创了三层：公开 `SolveStatus`（5）、内核 `SimplexStatus`（6）、
`MipStatus`（6）。逐条对照的结果如下 —— **只有一条是实质缺口，其余是"刻意的合并"或"功能不存在"**：

| MOI | 本项目 | 审计结论 |
| --- | --- | --- |
| `OPTIMAL` | `SolveStatus::Optimal`（只在证书被独立校验器接受时给出） | 同义；本项目的 `Optimal` 比 MOI 更难拿（要过校验器） |
| `ALMOST_OPTIMAL` | 无 | **不是缺口**：本项目没有"解出来了但证不出来"的公开状态 —— 那种情况是 `NotSolved`（线性）或内核 `NumericalFailure`。MOI 需要它，是因为有些求解器无法证明最优 |
| `INFEASIBLE` | `Infeasible`（带 Farkas 证书） | 同义 |
| `INFEASIBLE_OR_UNBOUNDED` | 无 | **不是缺口**：两个结论各自带证书，能分开，不需要"分不清"的兜底 |
| `DUAL_INFEASIBLE` | 无（对偶面不公开） | 刻意的：公开面只到 `Infeasible` |
| `UNBOUNDED` | `Unbounded` + 校验器复核的射线 | 同义 |
| `NODE_LIMIT` | `NodeLimit`（带当前整数点与仍在开的界） | 同义 |
| `ITERATION_LIMIT` | **内核有（`SimplexStatus::IterationLimit`），公开面没有**，归入 `NotSolved` | **唯一实质条目：同样"预算用尽"，整数侧的节点预算有专门状态，线性侧的枢轴上限却与"数值失败/规模拒绝/非法模型"合并进 `NotSolved`** —— 调用方无法只凭状态区分"再给点预算就可能解完"与"这条路走不通" |
| `SOLUTION_LIMIT` / `TIME_LIMIT` / `INTERRUPTED` | 无 | **功能不存在 ⇒ 状态不存在**（不做时间预算、不做并行、没有中断通道），已在 README 的非目标里写明 |
| `NUMERICAL_ERROR` | 内核 `NumericalFailure` → 公开 `NotSolved` + 内核原话 | **刻意的合并**：`NotSolved` 的口径是"带内核自己的原话"，调用方读原话就知道是数值问题 |
| `INVALID_MODEL` | `MipStatus::Invalid` → 公开 `NotSolved` + 原话 | 同上（模型非法不是一种求解结论） |
| `OTHER_ERROR` | 无 | 同 `NUMERICAL_ERROR` 的合并 |

**结论与倾向（本轮不改）**：唯一值得考虑的是给公开面加 `IterationLimit`（与 `NodeLimit` 对称）。
但公开枚举是**契约**，改动会让 `.mbti` 变化、并要求先把"线性求解的枢轴预算用尽算不算一种结论"
写清楚（本项目的口径是"只承认证明过的结论"，而"没解完"确实不是结论 —— 这与 MIP 侧给 `NodeLimit`
的理由并不对称：那边给状态是因为**有 incumbent 与仍在开的界**两个可用数字，线性侧没有）。要动就先写口径。

## `model`：模型层

`Model`（变量、约束、目标、sense）+ `Var`/`Constraint` 视图 + `validate`（返回人类可读的问题列表）。
`add_var(name, lb?, ub?, is_int?)` 返回变量下标；`infinite_bound` 是无穷界的哨兵值（`±1e30` 量级，
不是 IEEE 无穷——有界变量枢轴需要一个可比大小的界）。

- **证据**：`model/model_test.mbt`、`model/model_wbtest.mbt`。
- **无界/不可行**：`Model::validate` 只判**结构**合法性（下标越界、NaN、`lb > ub` 等），
  不判数学可行性；数学结论由内核或分支定界给出。

## `core`：数值与稀疏基础设施

`approx_eq/zero/positive/negative`（容差感知比较）、`CompensatedSum`（Neumaier 补偿求和）、
`SparseMatrix`（CSC，**不存结构零**、列内行号升序）、`fabs/fmax/fmin`。

- **契约**：所有"是否为零/是否为正"的判断都走容差助手，不用 `==` 比浮点。
- **证据**：`core/core_test.mbt`、`core/numerics_wbtest.mbt`、`core/sparse_wbtest.mbt`。

## `format`：MPS / LP 读写

```moonbit
pub fn parse_mps(text) -> Result[Model, ParseIssue]
pub fn read_lp(text)   -> Result[Model, ParseIssue]
pub fn write_mps(model) -> String
pub fn write_lp(model)  -> String
pub fn format_number(value : Double) -> String
```

- **契约**：`Err` 带**位置**（行/列）与人类可读原因；**读→写→读是幂等的**（同一个模型读进来、写出去、
  再读回来，得到同一个模型）。
- **数字格式政策**：`format_number` 用最短往返表示（`Double::to_string`），
  **不在上面加一层取整**——读回来的数与写出去的数逐位相同。CLI 的 JSON 输出用同一条政策。
- **证据**：`format/mps_test.mbt`、`format/lp_test.mbt`、`format/mps_wbtest.mbt`；
  全量真实数据见 `bench/parse-report.md`（33/33 解析成功）。

## `simplex`：稀疏修正单纯形内核

```moonbit
pub fn solve_model(model) -> Result[SimplexResult, String]
pub fn solve_model_with(model, options) -> Result[SimplexResult, String]
pub fn solve_model_with_basis(model, options, basis) -> Result[SimplexResult, String]
pub fn solve_standard(num_vars, cost, rows) -> SimplexResult
pub fn tableau_rows(model, options, basis) -> Result[Array[TableauRow], String]
```

- **`Err` 与状态的分工**：`Err` 表示**模型不在内核受理范围内**（整数变量、无法构造标准形），
  不是"没解出来"；后者由 `SimplexStatus` 表达：
  `Optimal` / `Infeasible` / `Unbounded` / `IterationLimit` / `NumericalFailure` / `TooLarge`。
- **`NumericalFailure` 的含义**：内核**有答案但证据不成立**时选择不报（原始可行性、非负性、
  行乘子符号约定任一项过不了自检），而不是给一个看起来合理的解。见 `CHANGELOG.md` 第三、十五轮。
- **热启动**：`solve_model_with_basis` 只在基**对偶可行**时走对偶单纯形；形状不匹配、对偶可行性丢失、
  数值失败一律回退冷启动——**热启动只是提速，永远不会给出不同的答案**。`SimplexBasis` 由上一次运行的
  `SimplexResult::basis` 提供。
- **证据**：`simplex/differential_test.mbt`（与 `oracle/` 参照实现差分）、`simplex/simplex_wbtest.mbt`、
  `simplex/dual_test.mbt`、`simplex/certificate_test.mbt`（内核给出的证书交独立校验器复核）、
  `simplex/lu_wbtest.mbt`（稀疏 LU 对稠密参照）。

## `presolve`：模型化简与还原

```moonbit
pub fn presolve(model) -> ReducedModel
pub fn max_row_violation(model, x)   -> Double
pub fn max_bound_violation(model, x) -> Double
pub fn objective_value(model, x)     -> Double
```

- **契约**：每条归约**先证明再触发**；`ReducedModel::verdict()` 为 `Reduced` / `Infeasible` / `Unbounded`
  （后两者是化简自己证出来的结论，带 `reason()`）。
- **还原必须被独立复核**：`reconstruct` 把化简解映回原变量，调用方**必须**用上面三个函数在**原模型**上量
  行违反、界违反与目标值——不能拿化简自己的记账当证据（`cmd/parse` 的 `reconstructed:` 一行就是这么做的）。
- **证据**：`presolve/presolve_test.mbt`（150 个随机模型上与未化简路径一致）、`presolve/presolve_wbtest.mbt`；
  `bench/solve-report.md` 的 `presolve` 与 `check` 两列。

## `verify`：独立校验器

```moonbit
pub fn verify(model, certificate, tolerance? = 1e-7) -> Verdict
pub fn derive_cut(model, certificate, tolerance? = 1e-7) -> Result[CutRow, String]
pub fn verify_cut(model, cut, certificate, tolerance? = 1e-7) -> CutVerdict
pub fn Certificate::to_json(self) -> String
pub fn Certificate::from_json(text) -> Certificate?
```

- **乘子约定**（生产者必须按它写证书）：对行定义定向形式 gᵢ（`≤` 行为 `a·x − b`，`≥`/`=` 行为 `b − a·x`），
  乘子 `y ≥ 0`（`=` 行自由）；于是下界 = `Σⱼ min over [lⱼ,uⱼ](rⱼxⱼ) + D`，
  最优性要求该下界等于点上的目标值，**Farkas 不可行证书就是同一式子取 `c = 0` 并要求严格为正**。
  推导写在 `verify/verify.mbt` 的包文档里。
- **`verify` 不依赖 `simplex`**：`verify/moon.pkg` 的 import 就是证据——校验器与求解器不共享任何状态，
  这是"证书"这个词的意义。
- **`Verdict` 带全部测量**：`accepted` / `claim` / `reason`（第一处失败的原话）/ `checks`（逐项测量与容差）。
- **割的复核**：`verify_cut` 把割**重新推导一遍**（组合重现自称的行、基变量整数、有限界移位、
  小数部分按 `combination_noise` 判、割大于产生它的算术、与交上来的行逐项相同）；
  拒绝即停，不"跳过继续"。见 `verify/cuts_test.mbt`。
- **证书只对内核收到的模型成立**：`--verify` 因此不化简（化简模型的乘子不是原模型的乘子）。
- **证据**：`verify/verify_test.mbt`（含"故意做坏的解必须被拒"）、`verify/cuts_test.mbt`（含穷举小模型
  所有整数点、确认无效割确实砍掉一个可行整点）。

## `mip`：分支定界

```moonbit
pub fn solve_mip(model, options) -> MipResult

pub(all) enum MipStatus { Optimal, Infeasible, NodeLimit, UnboundedRelaxation, Unverified, Invalid }
pub(all) struct MipOptions { max_nodes, max_iterations, tolerance, verify_nodes,
                             dive_steps, dive_attempts, cut_rounds, node_solver, cut_hook }
```

| 规则 | 说明 | 证据 |
| --- | --- | --- |
| 每个节点的松弛都过 `verify` | `verified` 是这件事的计数；开启校验时 `nodes - verified` 恰好是"无结论的松弛"数 | `mip/mip_test.mbt` 的 `verified == nodes` 断言 |
| 证书被拒**停整轮**为 `Unverified` | 不拿一个没人能复核的答案去分支；消息带校验器原话 | `mip/mip_test.mbt`（`with_node_solver` 注入错误求解器）、`mip/cuts_test.mbt` |
| 松弛无界 ≠ 模型无界 | 报 `UnboundedRelaxation`，因为改善射线不含整数性 | `mip/mip_test.mbt` |
| 模型非法 ≠ 不可行 | 报 `Invalid` | 同上 |
| `NodeLimit` 给出当前整数点与仍在开的界 | 两者一起才是调用方需要的（"能到多好"与"已经多好"） | `bench/mip-report*.md` 的 `bound`/`gap` 列 |
| 割必须能被独立再推导 | 每条割带"由哪一行舍入而来"的证明，`verify_cut` 复核后才进模型 | `mip/cuts_test.mbt`、`bench/*.md` 的 `cuts` 列 |
| 取整启发式只**提供**当前解 | 它的松弛走同一条求解+校验路径、计入 `nodes`/`verified`、受同一预算约束，永不主张最优 | `mip/search_wbtest.mbt`、`dive_*` 选项 |
| `node_solver`/`cut_hook` 只给测试用 | 用来演示"做坏的松弛/割会被拒" | `mip/mip_test.mbt`、`mip/cuts_test.mbt` |

## CLI（`cmd/parse`）

```
moon run cmd/parse -- <file> [flags]                # 巡检（默认）
moon run cmd/parse -- <verb> <file> [flags]         # verb ∈ parse|solve|verify|fmt|bench
```

- 文本输出是 `bench/` 四个脚本解析的格式，**逐位稳定**；`--json` 是同一批运行的另一份渲染。
- 退出码：解析失败、证书被拒、点没通过复核 → 非零；**模型不在内核受理范围内（`refused`）不算失败**。
- `fmt` 不给 `-o` 时只打印不落盘；`--json` 与 `--reoptimize` 的组合被显式拒绝（退出 2）。
- 证据：`cmd/parse/main_wbtest.mbt`；`bench/README.md` 的脚本与拒绝条件说明。
