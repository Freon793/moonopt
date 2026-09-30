# moonopt

[![check](https://github.com/Freon793/moonopt/actions/workflows/check.yml/badge.svg)](https://github.com/Freon793/moonopt/actions/workflows/check.yml)

MoonBit 的线性与整数规划求解器：读标准模型文件，用稀疏修正单纯形求解，对整数模型做分支定界，
并对每个结论给出一份可被第三方独立校验的证书。纯 MoonBit 实现，无 FFI 依赖。

- **模型输入**：MPS（free / fixed）、CPLEX LP
- **线性求解**：稀疏 CSC + 稀疏 LU 基分解的修正单纯形，增益定价，Harris 两遍比值检验，有界变量枢轴，
  对偶单纯形热启动，presolve / postsolve
- **整数求解**：best-bound 分支定界，节点热启动，根割（混合整数舍入，附推导证明），
  取整 / 下潜 / 可行性泵三种原始启发式
- **证书**：最优性、Farkas 不可行性、无界射线，可序列化为 JSON；`verify` 包独立复核，不依赖 `simplex`
- **目标平台**：native / wasm / wasm-gc / js

当前版本 `0.1.2`，已发布到 [mooncakes.io](https://mooncakes.io/docs/Freon793/moonopt)。
198 个测试在 native / wasm-gc / js 三个目标上全绿；CI 在 Linux / macOS / Windows 上跑检查、构建与测试。

## 安装

```bash
moon add Freon793/moonopt
```

需要 MoonBit 0.10.7 或更新版本（`moon version --all`）。

## 快速开始

```moonbit
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

用到两个包：`Freon793/moonopt`（求解入口）与 `Freon793/moonopt/model`（模型构造）。
整数变量用 `m.add_var("n", lb=0.0, ub=10.0, is_int=true)` 声明，`solve` 会自动走分支定界。

两个完整可运行的例子：

```bash
moon run examples/production_plan    # 两产品生产计划（最优 21 at (3, 1.5)）
moon run examples/transportation     # 产销平衡运输问题（全等式约束，走 Phase I；最优 11）
moon run cmd/main                    # 打印示例模型与一个"当前不支持"的诚实案例
```

示例里 `21.00000000002238` 这样的末位偏差来自退化扰动（默认 `1e-12`）：求解时给右端项加了一个远小于
可行性容差的确定性微扰来打破退化平局，而所有自检都按**未扰动**的右端项测量，所以解对调用方写下的模型
仍然可行。要打印成定点格式请自行格式化，示例直接输出原始值。

## 命令行

`cmd/parse` 是一个模型巡检 / 求解 / 校验 / 格式转换 / 批量基准工具。

```bash
moon run cmd/parse -- <file.mps>                                # 巡检：格式、规模、校验结论
moon run cmd/parse -- solve <file.mps> --relax --presolve        # 线性求解（默认走 presolve）
moon run cmd/parse -- solve <file.mps> --mip --max-nodes 2000    # 分支定界，每个松弛过 verify
moon run cmd/parse -- verify <file.mps> --relax                  # 求解并用独立校验器复核证书
moon run cmd/parse -- verify <file.mps> --certificate cert.json  # 只校验证书，不重解
moon run cmd/parse -- fmt <file.mps> --format lp -o out.lp       # 读→写
moon run cmd/parse -- bench --manifest instances.txt --mip --max-nodes 300
```

首参数是 `parse` / `solve` / `verify` / `fmt` / `bench` 之一时按子命令解释，否则按旗标形式解释，
两者都支持。加 `--json` 得到机器可读输出：`{"tool","command","files":[...],"summary":{...}}`，
**没跑出来的字段不出现**（而不是填 0），数字用最短往返表示、不取整。

退出码：解析失败、证书被拒、报告的点没通过复核都是非零；"模型超出内核受理范围"不算失败
（在 JSON 里是 `refused`），因为它是一个明确的结论而不是错误。

## 支持的模型

| 支持 | 暂不支持 |
| --- | --- |
| `min` / `max`；`≤` / `≥` / `=` 任意混合（含负右端项） | MPS 的 `SC` / `SI` 半连续界、完整的 `SOS` / `MARKER` 语义 |
| 任意有限上下界、自由变量 | 系数强化、对偶固定、行/列的支配检测等 presolve 归约 |
| 整数与 0-1 变量（分支定界） | **节点上的割**；整数无界性的证明（松弛无界只报 `NotSolved` / `UnboundedRelaxation`） |
| 证书复核（最优性 / Farkas / 无界射线） | 化简模型的乘子回映（证书只对内核收到的模型成立，故校验路径不化简） |
| 内核行数上限 200 000（稀疏 LU，内存 `O(nnz + fill)`） | 非线性 / 半定规划、并行、网络单纯形专用路径、Python / JS 绑定 |

超出能力边界的调用一律返回 `NotSolved` 并带原因，不会返回一个可疑解。详细的状态口径见
[`docs/api.md`](docs/api.md)。

## 真实数据与基准

[`bench/`](bench/README.md) 用公开实例（MIPLIB 2017，仓库不分发数据，只提供下载脚本与清单）对拍，
产出四份报告：

| 报告 | 口径 | 结果 |
| --- | --- | --- |
| [`bench/parse-report.md`](bench/parse-report.md) | 全清单解析 | 32 个实例全部解析成功 |
| [`bench/solve-report.md`](bench/solve-report.md) | 32 个实例、1000 行上限、20000 枢轴上限、presolve | 20 个求到最优、11 个超行数上限跳过、1 个到枢轴上限 |
| [`bench/mip-report.md`](bench/mip-report.md) | 32 个实例、300 节点 | 3 个证到最优、12 个到节点预算、17 个跳过 |
| [`bench/mip-report-small.md`](bench/mip-report-small.md) | 10 个实例、30000 节点 | 5 个证到公开已知最优值、5 个到节点预算 |

上限是结果的一部分：报告头部逐字记录行数上限、枢轴上限与节点预算，不同上限下的计数不能互相比较。
[`bench/report.md`](bench/report.md) 是索引，同时判定每份报告描述的还是不是当前代码里的那份。

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File bench/fetch-instances.ps1   # 下载实例
powershell -NoProfile -ExecutionPolicy Bypass -File bench/report.ps1            # 四份报告是否仍被当前代码支持
```

## 项目结构

```
moonopt.mbt       公开入口：solve / solve_with、SolveStatus、Solution、SolveOptions
core/             数值与稀疏基础设施（容差比较、补偿求和、CSC 稀疏矩阵）
model/            模型层（变量、线性表达式、约束、目标、模型校验）
format/           MPS 与 LP 读写、解析错误定位
oracle/           参考实现：稠密两阶段单纯形（差分测试的对照基准，不是交付求解器）
simplex/          稀疏修正单纯形内核、稀疏 LU、对偶单纯形热启动、证书生产端自检
presolve/         模型化简与解还原
verify/           独立校验器：最优性、Farkas、无界射线、割的再推导（不依赖 simplex）
mip/              分支定界、根割、原始启发式
cmd/main/         演示 CLI        cmd/parse/  模型巡检与求解 CLI
examples/         可运行示例      bench/      数据政策、下载与报告脚本、报告
docs/             设计、算法、API 契约、路线图、生态调研、验收对照
```

## 文档

| 文件 | 内容 |
| --- | --- |
| [`docs/design.md`](docs/design.md) | 架构：目标与非目标、包边界与依赖规则、数据表示、证书约定 |
| [`docs/algorithms.md`](docs/algorithms.md) | 实现里真正在跑的算法，每节附一条可复核的实测数字 |
| [`docs/api.md`](docs/api.md) | 公开 API 契约：每个包承诺什么、什么情况下返回哪个状态 |
| [`docs/roadmap.md`](docs/roadmap.md) | 里程碑与完成标准、下一步方向、明确不做的事 |
| [`docs/prior-art.md`](docs/prior-art.md) | 生态调研：生态内有无同类实现、可借鉴的公开标准、许可证红线 |
| [`bench/README.md`](bench/README.md) | 基准数据政策、实例量级、四份报告的复现步骤与口径 |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | 本地环境、提交前必须全绿的检查、代码规范 |
| [`CHANGELOG.md`](CHANGELOG.md) | 逐版变化 |
| [`docs/history.md`](docs/history.md) | 开发过程中的实测记录（归档，含被否决的方案与理由） |

## 开发

```bash
moon check --deny-warn
moon test --deny-warn
moon fmt && git diff --exit-code
moon info && git diff --exit-code   # .mbti 是接口合同，必须随代码提交
```

库包（`core` / `model` / `format` / `oracle` / `simplex` / `presolve` / `verify` / `mip` / 根包）
不依赖任何第三方包；只有 `cmd/parse` 依赖官方 `moonbitlang/x` 的 `fs` 与 `sys`。

## 许可与数据

- 本项目以 **Apache-2.0** 发布，见 [`LICENSE`](LICENSE)。
- 算法实现基于公开文献，代码为本项目原创，未移植任何第三方实现。
- 基准实例（MIPLIB 2017）是第三方数据，**不由本仓库再分发**：仓库里只有下载脚本与本项目自己写的清单，
  `.moonignore` 保证它们不进发布归档。细节见 [`bench/README.md`](bench/README.md)。
