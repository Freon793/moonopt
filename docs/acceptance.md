# 验收对照：要求 ↔ 证据

本文件把**赛事验收要求**逐条对上可复核的证据，并给出评审可以在本地执行的验证步骤。

两条证据轴分工不同，别混用：

- **本文件**回答"验收要求是否满足"（要求来自赛事的《代码仓库及验收要求》）；
- [`../README.md`](../README.md) 的**承诺 ↔ 证据**表回答"项目自己声明的能力是否有证据"。

两条轴的证据都指向同一批可复现对象：`bench/*.md`（报告）、`moon test`（测试）、`cmd/parse`（CLI 复现命令）。

## 1. 逐条对照

| # | 验收要求 | 证据 | 复核方式 |
| --- | --- | --- | --- |
| 1 | 以 MoonBit 为主要实现语言 | 非测试 MoonBit 实现 **125 个文件 / 33 228 行**（测试另 77 文件 / 15 882 行）；零 FFI、零第三方运行期依赖（库包不引任何第三方包，仅 `cmd/parse` 引官方 `moonbitlang/x` 的 `fs`/`sys`） | `moon check --deny-warn`；`git ls-files '*.mbt' \| Measure-Object`；`simplex/moon.pkg` 等包配置 |
| 2 | GitHub 仓库公开可访问、提交记录清晰 | 公开仓库 `Freon793/moonopt`，**提交记录按轮次推进**（每轮一个主题，提交信息写明"做了什么 / 为什么 / 证据"）；唯一的作者与仓库所有者一致 | `git log --oneline`；GitHub 仓库页 |
| 3 | 源代码结构清晰，能完成声明的核心功能 | 10 个包各司其职（`core`/`model`/`format`/`simplex`/`presolve`/`verify`/`mip`/`oracle`/`cmd/*`），包边界与依赖规则写在 [`design.md`](design.md)；核心功能有基准报告 | [`design.md`](design.md)；`bench/parse-report.md`、`bench/solve-report.md`、`bench/mip-report.md`、`bench/mip-report-small.md` |
| 4 | 提供 README，说明目标 / 安装 / 使用 / 示例，且可复现 | [`../README.md`](../README.md) 的四要素齐备（定位与"为什么需要它"、`moon add` 安装、CLI 与 API 用法、可运行示例）；本文件第 2 节给出评审可执行的最短复现路径 | 见下方"五分钟复现" |
| 5 | 使用持续集成工具并覆盖**检查、构建、测试**流程 | [`.github/workflows/check.yml`](../.github/workflows/check.yml)：`check` 任务在 Linux / macOS / Windows 上跑 `moon check` → `moon build` → `format diff` → `info check` → `moon test` → 报告陈旧性；`targets` 任务在 wasm-gc / js 上跑 `moon build --target <t>` → `moon test --target <t>` | GitHub Actions 运行页；每个任务都在注解里写出本次使用的工具链版本 |
| 6 | 提供至少一个可运行示例或最小使用样例 | `examples/production_plan`（最优 21）、`examples/transportation`（最优 11）、`cmd/main`（含一个"当前不支持"的诚实案例），README 另给最小 API 片段 | `moon run examples/production_plan` |
| 7 | 提供完整测试，覆盖核心功能路径 | **180 个测试**在 native / wasm-gc / js 三目标全绿，覆盖：与 `oracle` 的随机 LP 差分、presolve/postsolve 还原一致性、证书"故意做坏必须被拒"、无效割必须被拒、`verified == nodes` 不变量、CLI 文本与 JSON 两条路径、"不可行主张必须能被人工和解释"这条内核自检判据、cutoff 收紧节点盒子的四种情形、以及 `box_minimum` 在真实实例量级上的带内行为与"内核量与校验器量是同一个数" | `moon test`（及 `--target wasm-gc` / `--target js`） |
| 8 | 发布到 mooncakes.io | `Freon793/moonopt` 已发布（`0.1.0`、`0.1.1`、`0.1.2`），注册表可解析、可安装；发布物自包含且不含第三方数据 | `moon add Freon793/moonopt`（见下方第 3 节） |
| 9 | 采用 OSI 认可的开源许可证；参考/移植需符合原项目许可证 | **Apache-2.0**（`LICENSE` + `moon.mod` 的 `license`）；项目为**原创实现**，未移植任何第三方代码；基准数据（MIPLIB 2017）只下载、不入库、且被 `.moonignore` 排除在发布归档之外 | `LICENSE`；`bench/README.md` 的数据政策；`.moonignore` |

## 2. 五分钟复现（评审可执行）

```bash
moon version --all                    # 需要 MoonBit 0.10.7 以上
git clone https://github.com/Freon793/moonopt && cd moonopt

# ① 检查 / 构建 / 测试（与 CI 相同的三步）
moon check --deny-warn
moon build
moon test                             # 180 个测试

# ② 可运行示例
moon run examples/production_plan     # 最优 21 at (3, 1.5)
moon run cmd/main                     # 三个模型的状态报告（含一个诚实的失败案例）

# ③ 用真实实例走一遍"求解 + 独立校验"
powershell -NoProfile -ExecutionPolicy Bypass -File bench/fetch-instances.ps1
moon run cmd/parse -- bench/data/instances/22433 --mip --max-nodes 2000
moon run cmd/parse -- verify bench/data/instances/22433 --relax   # 求解并用独立校验器复核证书

# ④ 报告是否仍被当前代码支持（机械判定，含工具链比对）
powershell -NoProfile -ExecutionPolicy Bypass -File bench/report.ps1
```

四份报告可由脚本一键重跑（`bench/report-parse.ps1` / `report-solve.ps1` / `report-mip.ps1`），
每条命令与其口径（行数上限、枢轴上限、节点预算）都记录在 [`../bench/report.md`](../bench/report.md)
与各报告头部；**上限是结果的一部分**，不同上限下的计数不能互相比较。

## 3. 发布物验收

```bash
# 在一个空工程里装发布版（而不是仓库源码）
moon new consumer && cd consumer
moon add Freon793/moonopt
```

发布归档本身的三个事实（都在 `docs/roadmap.md` 的 M6 轮次里记录了做法）：

- **自包含**：归档解出来后当模块根，`moon check --deny-warn` 干净、`moon test` 180/180；
- **不含第三方数据**：121 条目 / 421 KB（0.1.0 口径），`bench/data` 只保留本项目自己写的清单，排除规则在 `.moonignore`；
- **公开面可被陌生人使用**：一个只 import `Freon793/moonopt` 与 `Freon793/moonopt/model` 的外部包
  能编译并按四项契约运行（线性模型 21、整数模型 20、不可行模型、以及"预算不足时报 `node-limit` 而不是假装最优"）。

## 4. 与生态内既有实现的差异（为什么不是重复项目）

选型期用 `moon search` 与 mooncakes.io 做过检索（方法与命中数见 [`related-work.md`](related-work.md)），
生态内**没有**通用 LP/MILP 求解器与标准模型格式支持。最相关的两个既有实现与逐项能力对照见
[`ecosystem-survey.md`](ecosystem-survey.md#与生态内既有实现的差异)，要点：

- `Juwan-Hwang/moon-certified` 的 `math/simplex` / `math/ilp` 是**合集仓库里的稠密数组接口**
  （`solve(c, A, b)`，`SimplexResult { Optimal(Array[Double], Double) \| Infeasible \| Unbounded }`）：
  没有模型对象与文件输入、没有对偶/证书、没有 presolve 与分支定界；
- `Luna-Flow/linear-program` 是**未发布**的建模 + 标准化实现（注册表中不存在）；
- 本项目补的是**内核与外层契约**：标准模型互操作、稀疏修正单纯形与稀疏 LU、presolve/postsolve、
  可独立校验的证书、分支定界与带证明的割、以及可复现的公开基准报告。

## 5. 已知限度（写出来，而不是藏起来）

- 割只有**单行**舍入，且只在**根**节点做：选择规则五条（第十六~十八轮）、多行 MIR 聚合族（第二十一轮）
  与**节点上的割**（第二十二轮）都已实测、均无净收益并回退；cutoff 传播未做；
- **Farkas 射线**仍是 Phase I 的最优对偶解，但内核先用必需条件 `Σ a ≥ max v`（人工和必须能吸收它要解释的
  违反量）自检，不成立就**不发证书**、报 `NumericalFailure`，搜索按"没有结论的松弛"继续（第二十三轮；
  该条件在 `noswot` 节点 1558 上曾相差 5 个数量级，触发过一次整轮 `unverified` 停下）；校验端对每一份证书仍独立复核；
- 整数无界性（整数射线）未证明；`fast0507` 在默认枢轴上限内跑不完；DeVex / steepest-edge 定价与部分 presolve 归约未做；
- `bench/mip-report-small.md` 口径下 10 个实例中 6 个到节点预算（4 个证到公开已知最优值）。
