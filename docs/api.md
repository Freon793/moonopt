# 公开 API 契约

本文件面向调用方：每个包对外承诺什么、什么情况下返回哪个状态、哪些字段在哪些状态下有意义。
它只写代码里已经成立的事——`.mbti` 里出现的就是契约，`.mbti` 里没出现的就是内部实现。
生成 `.mbti` 的命令是 `moon info`，任何公开面变化都会让它出现 diff，提交前看一眼这个 diff 就知道
自己的改动有没有碰到承诺面。

## 顶层包 `Freon793/moonopt`（`moonopt.mbt`）

```moonbit
pub fn solve(model : @model.Model) -> Solution
pub fn solve_with(model : @model.Model, options : SolveOptions) -> Solution
pub fn relaxation(model : @model.Model) -> @model.Model

pub(all) struct SolveOptions { max_iterations, presolve, max_nodes, cut_rounds }
pub struct Solution { status, values, objective, iterations, nodes, bound, gap, message }
pub(all) enum SolveStatus { Optimal, Infeasible, Unbounded, NodeLimit, NotSolved }
```

| 规则 | 说明 |
| --- | --- |
| 整数模型走分支定界，**不做化简** | 答案不能取决于化简碰巧定住了什么；`presolve` 选项对整数模型不生效 |
| 只承认搜索证明过的结论 | `MipStatus::Optimal` / `Infeasible` → 同名公开状态；节点预算到顶 → `NodeLimit` |
| 三类情况一律 `NotSolved` 并带原话 | 松弛无界（改善射线不含整数性）、证书被拒（那是关于内核的陈述，不是关于模型的结论）、模型非法；另加"量到违反却写不出不可行证书"——Phase I 的人工和不足以解释它要证明的违反量 |
| `values` 非空时才有 `objective` | 预算到顶且没找到整数点时 `objective` 为 0，`message` 用文字说明"还没有整数点" |
| `bound` / `gap` 在所有路径同义 | 线性求解下 `bound = objective`、`gap = 0`（线性解就是它自己的界）；`NodeLimit` 下是仍在开的界 |
| `relaxation` 是"另一问"的入口 | 整数模型不会以松弛的形式被回答，所以想要**界**（而不是最优整点）的调用方显式要它：同一个模型、同一批变量与顺序、相同的行、去掉整数性。它返回一个普通线性模型，走与任何线性模型相同的 `solve`（含化简与独立复核）；调用方手上那个点仍在同一空间里，可以用 `presolve` 的 `objective_value` / `max_row_violation` 读回，于是"当前方案 gap ≤ X%"是可算的（`examples/schedule_bound` 是这条链路的完整示例） |

**状态口径与外部标准**：外部参照是 MathOptInterface 的 `TerminationStatusCode`。逐条比较过之后只有一处
是实质差异：MOI 有 `ITERATION_LIMIT`，本项目的公开面**没有**枢轴上限用尽这个状态，它与数值失败、规模
拒绝、非法模型一起归入 `NotSolved`。这是刻意的——本项目的口径是"只承认证明过的结论"，而"没解完"不是
结论；MIP 侧给 `NodeLimit` 是因为那里还有**当前整数点**与**仍在开的界**两个可用数字，线性侧没有。
其余 MOI 状态要么同义、要么对应本项目的功能不存在（不做时间预算、不做并行、没有中断通道），
要么是刻意的合并。

`SolveStatus` 只 derive `Eq` 与 `Debug`，**公开面上没有 `to_string`**：打印状态文本是调用方的事
（README 与 `examples/` 里的 `match` 就是这件事的写法）。同理 `Solution` 是 `pub struct`——字段可读
但包外不可构造，`SolveOptions` 是 `pub(all) struct`。

## `model`：模型层

`Model`（变量、约束、目标、sense）+ `Var` / `Constraint` 视图 + `validate`（返回人类可读的问题列表）。

```moonbit
pub fn Model::add_var(self, name : String, lb? : Double = 0.0, ub? : Double = infinite_bound,
                      is_int? : Bool = false) -> Int
```

- `infinite_bound` 是无穷界的哨兵（`±1e30` 量级，不是 IEEE 无穷——有界变量枢轴需要一个可比大小的界）。
- `Model::validate` 只判**结构**合法性（下标越界、NaN、`lb > ub` 等），不判数学可行性；数学结论由内核
  或分支定界给出。

## `core`：数值与稀疏基础设施

`approx_eq` / `approx_zero` / `approx_positive` / `approx_negative`（容差感知比较）、
`CompensatedSum`（Neumaier 补偿求和）、`SparseMatrix`（CSC，不存结构零、列内行号升序）、
`fabs` / `fmax` / `fmin`。

契约：所有"是否为零 / 是否为正"的判断都走容差助手，不用 `==` 比较浮点。

## `format`：MPS / LP 读写

```moonbit
pub fn parse_mps(text) -> Result[Model, ParseIssue]
pub fn read_lp(text)   -> Result[Model, ParseIssue]
pub fn write_mps(model) -> String
pub fn write_lp(model)  -> String
pub fn format_number(value : Double) -> String
```

- `Err` 带**位置**（行 / 列）与人类可读原因；**读→写→读是幂等的**（同一个模型读进来、写出去、再读回来
  得到同一个模型）。
- 数字格式用最短往返表示（`Double::to_string`），**不在上面加一层取整**——读回来的数与写出去的数逐位
  相同。CLI 的 JSON 输出用同一条政策。
- 全量真实数据的解析结果见 [`../bench/parse-report.md`](../bench/parse-report.md)（32 个实例全部成功）。

## `simplex`：稀疏修正单纯形内核

```moonbit
pub fn solve_model(model) -> Result[SimplexResult, String]
pub fn solve_model_with(model, options) -> Result[SimplexResult, String]
pub fn solve_model_with_basis(model, options, basis) -> Result[SimplexResult, String]
pub fn solve_standard(num_vars, cost, rows) -> SimplexResult
pub fn tableau_rows(model, options, basis) -> Result[Array[TableauRow], String]

pub(all) enum Pricing { Dantzig, Gain, Devex }
pub fn SimplexOptions::with_pricing(self, pricing) -> SimplexOptions
```

- **`Err` 与状态的分工**：`Err` 表示模型**不在内核受理范围内**（整数变量、无法构造标准形），不是
  "没解出来"；后者由 `SimplexStatus` 表达：`Optimal` / `Infeasible` / `Unbounded` / `IterationLimit` /
  `NumericalFailure` / `TooLarge`。
- **`NumericalFailure` 的含义**：内核**有答案但证据不成立**时选择不报（行残差、变量界、非负性、行乘子
  符号约定、对偶间隙任一项过不了自检），而不是给一个看起来合理的解。恢复梯子（Bland 重启 → 去掉退化
  微扰 → 换定价规则）会先试三条走法，仍失败才返回原始失败。
- **热启动**：`solve_model_with_basis` 只在基**对偶可行**时走对偶单纯形；形状不匹配、对偶可行性丢失、
  数值失败（含"基按检验数最优但证书写不出来"的拒签）一律回退冷启动——**热启动只是提速，永远不会给出
  不同的答案**。`SimplexBasis` 由上一次运行的 `SimplexResult::basis` 提供。
- **定价**：`SimplexOptions::pricing` 选 `Dantzig` / `Gain`（默认，候选预算由 `gain_candidates` 给）/
  `Devex`。定价只决定**走哪条路**，不决定答案——三条规则必须落在同一个最优值（测试断言这一点），
  所以它是一个"用每次迭代的代价换枢轴数"的旋钮。

## `presolve`：模型化简与还原

```moonbit
pub fn presolve(model) -> ReducedModel
pub fn strengthen_integer_rows(model) -> (Model, StrengthenStats)
pub fn max_row_violation(model, x)   -> Double
pub fn max_bound_violation(model, x) -> Double
pub fn objective_value(model, x)     -> Double

pub(all) struct StrengthenStats { rows_rewritten : Int, bounds_tightened : Int }
```

- 每条归约**先证明再触发**；`ReducedModel::verdict()` 为 `Reduced` / `Infeasible` / `Unbounded`，
  后两者是化简自己证出来的结论，带 `reason()`。`ReducedModel::stats()` 逐项报告哪些归约触发过
  （`variables_fixed_dual` 是对偶固定的计数；`rows_strengthened` 在这里恒为 0，因为系数强化属于整数
  路径，见下一条）。
- `strengthen_integer_rows` 是**整数路径**上的归约，做两件事：应用整数行隐含的整数界，以及把整数行
  的系数抬到"不丢掉任何一个整数点"的最高值。它不动变量与下标、也不需要 postsolve；返回强化后的模型与
  `StrengthenStats`（`rows_rewritten` = 系数被抬高的行数，`bounds_tightened` = 被收紧的变量界个数；
  两样都没有时原样返回）。`mip::solve_mip` 在搜索之前调用它，所以分支定界跑的是同一个整数问题的一个
  更强的松弛，而调用方拿到的点仍是自己那个模型的点。
- **还原必须被独立复核**：`reconstruct` 把化简解映回原变量，调用方**必须**用上面三个函数在**原模型**上
  量行违反、界违反与目标值——不能拿化简自己的记账当证据（`cmd/parse` 的 `reconstructed:` 一行就是这么
  做的）。

## `verify`：独立校验器

```moonbit
pub fn verify(model, certificate, tolerance? = 1e-7) -> Verdict
pub fn derive_cut(model, certificate, tolerance? = 1e-7) -> Result[CutRow, String]
pub fn verify_cut(model, cut, certificate, tolerance? = 1e-7) -> CutVerdict
pub fn Certificate::to_json(self) -> String
pub fn Certificate::from_json(text) -> Certificate?
```

- **乘子约定**（生产者必须按它写证书）：对行定义定向形式 gᵢ（`≤` 行为 `a·x − b`，`≥` / `=` 行为
  `b − a·x`），乘子 `y ≥ 0`（`=` 行自由）；于是下界 = `Σⱼ min over [lⱼ,uⱼ](rⱼxⱼ) + D`，最优性要求该下界
  等于点上的目标值，**Farkas 不可行证书就是同一式子取 `c = 0` 并要求严格为正**。推导写在
  `verify/verify.mbt` 的包文档里。
- **`verify` 不依赖 `simplex`**：`verify/moon.pkg` 的 import 就是证据——校验器与求解器不共享任何状态，
  这是"证书"这个词的意义。
- `Verdict` 带全部测量：`accepted` / `claim` / `reason`（第一处失败的原话）/ `checks`（逐项测量与容差）。
- **割的复核**：`verify_cut` 把割**重新推导一遍**（组合重现自称的行、基变量整数、有限界移位、小数部分
  按 `combination_noise` 判、割大于产生它的算术、与交上来的行逐项相同）；拒绝即停，不"跳过继续"。
- **证书只对内核收到的模型成立**：`--verify` 因此不化简（化简模型的乘子不是原模型的乘子）。

## `mip`：分支定界

```moonbit
pub fn solve_mip(model, options) -> MipResult

pub(all) enum MipStatus { Optimal, Infeasible, NodeLimit, UnboundedRelaxation, Unbounded, Unverified, Invalid }
pub(all) struct MipOptions { max_nodes, max_iterations, tolerance, verify_nodes,
                             row_strengthening, dive_steps, dive_attempts, cut_rounds,
                             primal_rounding, node_solver, cut_hook }
```

- `MipOptions::row_strengthening`（默认开）决定搜索之前是否调用 `strengthen_integer_rows`；关掉它，
  搜索拿到的就是调用方写的那个模型。`MipResult::strengthening` 如实报告它改了什么——两样都没改时
  全为零，于是"这条归约在这里到底有没有触发"是测量而不是假设（`--json` 的 `strengthened_rows` /
  `strengthened_bounds` 两个字段就是它）。

| 规则 | 说明 |
| --- | --- |
| 每个节点的松弛都过 `verify` | `verified` 是这件事的计数；开启校验时 `nodes − verified` 恰好是"无结论的松弛"数 |
| 证书被拒**停整轮**为 `Unverified` | 不拿一个没人能复核的答案去分支；消息带校验器原话 |
| 松弛无界 ≠ 模型无界 | 只有点与射线在整数变量上都是整数时报 `Unbounded`（`MipResult::values` + `ray` 是证明的两半，公开 `SolveStatus::Unbounded` 不带这两个数组，与线性路径一致）；否则报 `UnboundedRelaxation`，因为改善射线不含整数性 |
| 模型非法 ≠ 不可行 | 报 `Invalid` |
| `NodeLimit` 给出当前整数点与仍在开的界 | 两者一起才是调用方需要的（"能到多好"与"已经多好"）。界取自**全部开着的活**：队列里的节点，以及松弛到达不了结论、因此不再入队的那些节点所在的子树 |
| 割必须能被独立再推导 | 每条割带"由哪一行舍入而来"的证明，`verify_cut` 复核后才进模型 |
| 取整 / 修复 / 泵 / 下潜只**提供**当前解 | 四者各走同一条求解 + 校验路径、计入 `nodes` / `verified`、受同一预算约束，永不主张最优 |
| `nodes` 永不超过 `max_nodes` | 每个"花掉一次松弛"的地方都先问预算；`mip/mip_test.mbt` 里有模型 × 预算 1..8 的遍历断言 |
| `node_solver` / `cut_hook` 只给测试用 | 用来演示"做坏的松弛 / 割会被拒" |

## CLI（`cmd/parse`）

```
moon run cmd/parse -- <file> [flags]                # 巡检（默认）
moon run cmd/parse -- <verb> <file> [flags]         # verb ∈ parse|solve|verify|fmt|bench
moon run cmd/parse -- <file> --solve --pricing <rule>   # dantzig|gain|devex
```

- 文本输出是 `bench/` 四个脚本解析的格式，**逐位稳定**；`--json` 是同一批运行的另一份渲染，
  没跑出来的字段不出现。
- 退出码：解析失败、证书被拒、报告的点没通过复核 → 非零；**模型超出内核受理范围（`refused`）不算失败**。
- `fmt` 不给 `-o` 时只打印不落盘；`--json` 与 `--reoptimize` 的组合被显式拒绝（退出 2）。
- 证据：`cmd/parse/main_wbtest.mbt`；[`../bench/README.md`](../bench/README.md) 的脚本与拒绝条件说明。
