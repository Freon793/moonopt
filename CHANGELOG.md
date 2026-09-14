# Changelog

本文件记录每个版本的可见变化。格式参考 [Keep a Changelog](https://keepachangelog.com/)，
版本号遵循 [Semantic Versioning](https://semver.org/)。

## [Unreleased]

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
