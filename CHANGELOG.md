# Changelog

本文件记录每个版本的可见变化。格式参考 [Keep a Changelog](https://keepachangelog.com/)，
版本号遵循 [Semantic Versioning](https://semver.org/)。

## [Unreleased]

### Added — 2026-09-14

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
