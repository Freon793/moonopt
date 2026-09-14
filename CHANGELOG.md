# Changelog

本文件记录每个版本的可见变化。格式参考 [Keep a Changelog](https://keepachangelog.com/)，
版本号遵循 [Semantic Versioning](https://semver.org/)。

## [Unreleased]

### Added (D1 — 2026-09-14)

- 项目骨架：`moon.mod` / 多包布局 / CI（Linux、macOS、Windows）/ pre-commit hook / 文档。
- `core`：相对容差比较（`approx_eq` / `approx_zero` / `is_finite` / `is_nan`）、
  Neumaier 补偿求和、CSC 稀疏矩阵（构造、按列访问、转置、稠密化、矩阵向量乘）。
- `model`：`Sense` / `Rel` / `Var` / `Constraint` / `Model`
  （变量上下界、整数标记、约束、目标、模型校验）。
- `oracle`：稠密两阶段单纯形（`≤` / `≥` / `=`，Bland 防循环，人工变量 Phase I），
  作为差分测试对照基准保留。
- `moonopt`（根包）：`Model::solve`、`SolveStatus`、`Solution`、`SolveOptions`；
  D1 阶段求解能力受限于 oracle，超出能力范围时返回 `NotSolved` 并给出明确原因。
- `cmd/main`：打印两个内置示例（生产计划、运输问题）与一个“当前不支持”的诚实示例；
  子命令（`solve` / `verify` / `fmt` / `bench`）在 D9 落地。
- `examples/production_plan`、`examples/transportation`：可直接 `moon run` 的示例。
- 测试：38 个（白盒 + 黑盒），`moon check --deny-warn` / `moon test --deny-warn` 全绿。

### Known limitations (D1)

- 求解内核仍是 `oracle`（稠密参考实现）：非零变量下界与整数变量会返回 `NotSolved` + 原因。
- 尚无 MPS/LP 文件输入（D2）、无稀疏修正单纯形（D3）、无证书校验（D6）、无整数分支（D7–D9）。
- CLI 尚未做定点数值格式化，示例直接打印 `Double` 的原始值。

## [0.1.0] — 计划于 D10（2026-09-24）发布

- 必达：MPS/LP 读写、稀疏修正单纯形 + 对偶单纯形、presolve/postsolve、
  最优性 / Farkas / 无界证书与 `verify` 校验器、CLI、Netlib 对拍报告、mooncakes 发布。
- 加分：薄 MILP 层（复用自家 LP 内核的分支定界），以 D7 硬开关决定是否纳入本版本。
