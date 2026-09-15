# Changelog

本文件记录每个版本的可见变化。格式参考 [Keep a Changelog](https://keepachangelog.com/)，
版本号遵循 [Semantic Versioning](https://semver.org/)。

## [Unreleased]

### Changed — M3 (product-form / eta basis updates)

- **基逆不再被显式维护**：枢轴改为追加一个**稀疏 eta**（`B⁻¹ = E_k·…·E₁·B₀⁻¹`，
  `E = I + w·eᵣᵀ`，`w = (eᵣ − d)/dᵣ`，Sherman–Morrison 推导，符号写反会被差分测试立刻抓到），
  每枢轴从 O(m²) 的行操作降到 eta 的非零元个数；基逆只在重新分解时重建，
  重新分解间隔由 100 提升到 500；
- 正向/反向求解（FTRAN/BTRAN）按稀疏方式实现：基准逆按输入向量的非零元走，
  eta 按时间顺序/逆序施加；对偶值与方向计算改用共享 scratch buffer，迭代循环内不再分配；
- 结果：`mod010`（146 行 / 2655 列）**121.2s → 1.8s**，`22433`（198 行）**35.5s → 0.4s**，
  `khb05250` 0.5s → 0.2s（均为 native release）；
- 声明最优前的自检若失败，会**先折回分解（refactorize）再判一次**：eta 的累积舍入常在这一步被消除，
  只有仍然违反的才算数值失败。`blend2` 因此恢复为最优（obj 6.915675114009083），
  `noswot` 仍是真实失败（缩放负值 1.7e-4，是真实的非负性违反）。

### Changed — M3 (performance, measured rather than guessed)

- 定价与方向计算改为直接遍历 CSC 原始数组（新增
  `SparseMatrix::col_pointers` / `row_indices` / `values_view`），不再为每一列分配一个
  `(row, value)` 列表：`mod010` 的求解时间从 154.6s 降到 121.2s（约 20%）。先测量、再改，
  没有凭感觉优化；
- 人工变量驱逐改为用基逆的一行作权向量、按列非零元计算单个表元素（`tableau_entry`）；
  原实现为每个候选列构造完整方向，复杂度 O(m·nnz) 且每次都分配一个 m 向量。
  现在只有真正要枢轴的那一列才重建完整方向；
- **基准改用原生 release 目标**：同一实例（`mod010`，146 行 / 2655 列）实测
  wasm 默认目标 119.6s、native debug 203.6s、**native release 18.8s**（6.4×）。
  `bench/report-solve.ps1` 已切到 native release，报告里的数字全部来自该目标；
- 可行性的判定改为**按行缩放残差**（`|Ax−b| / (1+|b|+Σ|a·x|)`，负值同样按解的尺度缩放）：
  绝对残差 2.5e-7 出现在右端项上百的行上是舍入误差，而相对量级 2.0e-4 的负值才是真实违反。
  此前 `blend2` 因绝对口径被误判为数值失败，修正后它求到最优，`noswot` 仍被判为真实失败；
- 求解报告的行数上限由 200 提升到 300；eta 版落地后进一步提升到 1000，
  覆盖的实例与结果见 [`bench/solve-report.md`](bench/solve-report.md)。

### Added — M3 (sparse revised simplex kernel)

- `simplex`：**稀疏修正单纯形内核**，公开入口 `solve_standard` / `solve_model`
  （以及带显式选项的 `_with` 版本），状态区分 `Optimal` / `Infeasible` / `Unbounded` /
  `IterationLimit` / `NumericalFailure`；
- 数据结构：问题以 CSC 列存储，定价按列非零元走；基逆为稠密 `m×m`，
  用乘积形式行变换更新，并每 `refactorize_every` 次枢轴重新用部分主元 Gauss-Jordan 分解，
  奇异时上报 `NumericalFailure` 而不是继续跑；
- 单纯形过程：Phase I 最小化人工变量和，Phase II 优化真实目标并禁止人工变量入基；
  Dantzig 定价（停滞时自动切到 Bland 规则以保终止）、**Harris 两遍比值检验**、
  对偶值与检验数、比值检验忽略负的基本值以免反向迈步；
- **人工变量驱逐**：Phase I 结束后仍留在基里的零值人工变量会被换出，
  否则 Phase II 的枢轴会把它推成正数从而悄悄破坏对应行的可行性（此问题由差分测试发现）；
- **自检**：声明最优前用内核自己的矩阵重算行残差（不计人工列）与非负性，
  超容差即返回 `NumericalFailure` 并附测得数值；
- 模型侧变换：非零下界通过平移、自由变量拆成正负两部分、有限上界转为显式行，
  目标常数随平移一起记录；`SimplexOptions::relaxed()` 把整数变量当作连续变量，
  用于求 MILP 的 LP 松弛；
- 根包 `moonopt::solve` 不再使用稠密参考实现，改为调用内核；旧的适配层删除。
- `cmd/parse` 新增 `--solve` / `--relax` / `--max-rows`，可对解析出的模型直接求解。

### Differential testing — 2026-09-14

- 新增随机 LP 差分测试：确定性 LCG 生成 **200 个随机 LP**（2–5 变量、2–5 行、
  混合 `≤`/`≥`/`=`、含负右端项与负成本系数），内核与 `oracle` 在**状态、目标值与
  解的可行性**三方面必须一致；另有 41 个非整数系数（0.5 缩放 + 偏移）实例，
  用于覆盖符号正规化与比值检验的非整数路径。
- 测试总数 58 → **72**，`moon check --deny-warn` / `moon test --deny-warn` 与
  wasm-gc、js、native 三目标全绿。

### Benchmark — 2026-09-14 (kernel)

- 在 MIPLIB 2017 的 33 个实例上运行求解报告（LP 松弛模式，行数 ≤ 200）：
  **9 个求到最优**、23 个因行数超过当前稠密基逆的规模上限而跳过、
  1 个由内核自检判定为数值失败并如实记录残差与负值。完整表格见
  [`bench/solve-report.md`](bench/solve-report.md)。
- 规模上限是当前实现（稠密基逆）的真实边界，已写入 README 的能力表；
  稀疏 LU 基分解与更快的定价属于 M3 剩余工作。

### Added — M2 (standard model input)

- `format`：**MPS 读取器**（free 与 fixed 布局、`NAME` / `ROWS` / `COLUMNS` / `RHS` /
  `RANGES` / `BOUNDS` / `OBJSENSE` / `ENDATA`、`MARKER` 整数块、Fortran 风格指数 `1.5D+02`、
  额外的 `N` 行按 MPS 语义当作 free row 忽略、`RANGES` 展开为两条不等式）；
- `format`：**MPS 写出器**（列顺序保持稳定、整数列用 `INTORG`/`INTEND` 包裹、显式写出非默认上下界，
  因此 读→写→读 得到等价模型且文本稳定）；
- `format`：**LP 格式读写**（`Minimize`/`Maximize`、目标行、`Subject To`、`Bounds` 的全部常见写法、
  `Generals`/`Binary`、`End`，支持粘连写法 `3x`、`x+y<=4`、`1e-3` 与 `free`/`infinity` 等）；
- `format`：`ParseIssue`（行号、列号、token、原因）与 `split_tokens` / `parse_number` 工具；
  所有畸形输入只报错不 panic，错误信息带精确位置；
- `cmd/parse`：模型文件巡检 CLI —— 按扩展名或内容判定格式、打印规模统计与校验结果、
  `--manifest` 批量模式、失败时返回非零退出码；
- `bench/`：`fetch-instances.ps1`（下载 MIPLIB 2017 实例，gzip 解压，数据不入库）、
  `report-parse.ps1`（生成报告，含工具链版本与提交哈希）、`parse-report.md`。
- 模型层新增 `Model::set_var_bounds` / `Model::set_var_integer`：文件读取器在读到 `BOUNDS`
  段之后才确定变量上下界，需要这两个 setter。

### Benchmark — 2026-09-14

- 在 **MIPLIB 2017 的 33 个实例**上运行解析报告：**33 解析成功 / 0 失败**，
  合计 173 934 个变量、44 480 条约束、1 651 814 个非零元，最大实例 `fast0507`（472 358 非零元）。
  完整表格见 [`bench/parse-report.md`](bench/parse-report.md)。
- 报告脚本会记录工具链版本与提交哈希，数字可追溯。

### Notes

- 库包（`core` / `model` / `oracle` / `format` / 根包）保持零第三方依赖；
  仅 CLI（`cmd/parse`）依赖官方 `moonbitlang/x` 的 `fs` 与 `sys` 用于文件与命令行访问。
- `bench/` 下的脚本只用 ASCII 字符：Windows PowerShell 5.1 读取无 BOM 的 UTF-8 脚本时会按
  ANSI 解码，非 ASCII 字符会变成乱码。

### Added — 2026-09-14 (M1)

- 项目骨架：`moon.mod` / 多包布局 / CI（Linux、macOS、Windows + wasm-gc、js 目标）/ pre-commit hook / 文档。
- `core`：相对容差比较（`approx_eq` / `approx_zero` / `approx_positive` / `is_finite` / `is_nan`）、
  Neumaier 补偿求和、CSC 稀疏矩阵（构造、按列访问、转置、稠密化、矩阵向量乘）。
- `model`：`Sense` / `Rel` / `Var` / `Constraint` / `Model`
  （变量上下界、整数标记、约束、目标、模型校验）以及 MPS 关键字解析（`Sense::from_symbol` /
  `Rel::from_symbol`）。
- `oracle`：稠密两阶段单纯形（`≤` / `≥` / `=`，人工变量 Phase I，Bland 防循环），
  作为差分测试对照基准保留。
- `moonopt`（根包）：`solve` / `solve_with`、`SolveStatus`、`Solution`、`SolveOptions`；
  越出当前内核能力边界时返回 `NotSolved` 并给出明确原因。
- `cmd/main`：打印两个内置示例（生产计划、运输问题）与一个“当前不支持”的诚实示例；
  子命令（`solve` / `verify` / `fmt` / `bench`）在 M6 落地。
- `examples/production_plan`、`examples/transportation`：可直接 `moon run` 的示例。
- 测试：38 个（白盒 + 黑盒），`moon check --deny-warn` / `moon test --deny-warn` 全绿，
  `wasm-gc` / `js` / `native` 三个目标同样全绿。

### Known limitations

- 求解内核仍是 `oracle`（稠密参考实现）：非零变量下界与整数变量会返回 `NotSolved` + 原因。
- 尚无 MPS/LP 文件输入（M2）、无稀疏修正单纯形（M3）、无证书校验（M4）、无整数分支（M5）。
- CLI 尚未做定点数值格式化，示例直接打印 `Double` 的原始值。

## [0.1.0] — 计划发布

- M2–M6 完成后发布：MPS/LP 读写、稀疏修正单纯形与对偶单纯形、presolve/postsolve、
  证书（最优性 / Farkas / 无界）与独立 `verify` 校验器、CLI、Netlib 对拍报告、
  发布到 mooncakes.io。
- 整数规划层（分支定界 + 割平面）是否纳入本版本，取决于 [`docs/roadmap.md`](docs/roadmap.md)
  的范围闸门。
