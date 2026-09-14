# 生态现状调研与设计边界（核对于 2026-09-14）

本文件记录选型阶段对 MoonBit 生态的**技术现状调研方法与原始证据**，目的是界定本项目的设计边界：
哪些能力必须自己实现，哪些实现已存在、可以对接或复用，以及为什么当前设计不是重复劳动。

## 调研方法

| 步骤 | 做法 | 结果 |
| --- | --- | --- |
| 1 | 枚举 mooncakes.io 已发布模块全集（本机 registry 索引 `~/.moon/registry/index/user/*.index`） | **2 470 个模块**（含描述、关键词、发布时间） |
| 2 | 枚举 GitHub 全站 `topic:moonbit` 仓库 | **304 个仓库** |
| 3 | `moon search` 关键词核验 | `milp` → *No modules found*；`simplex` → 仅噪声与一个零和博弈专用实现 |
| 4 | GitHub 仓库搜索 | `moonbit+simplex` = 0；`moonbit+MPS+solver` = 0；`moonbit+linear programming` = 1（`Luna-Flow/linear-program`） |
| 5 | 生态源码/描述全文关键词命中统计 | `revised simplex`、`sparse simplex`、`dual simplex`、`bounded variable simplex`、`Farkas`、`optimality certificate`、`infeasibility certificate`、`MPS format/file/.mps`、`presolve`、`branch-and-cut`、`LU factorization`、`basis factorization`、`interior point`、`barrier method` —— **命中数均为 0** |

## 两个相关实现的实测事实

### `Juwan-Hwang/moon-certified`（已发布 mooncakes v0.1.1）

- 仓库：0 star / 0 fork；创建 2026-07-22；最后推送 2026-08-27；Apache-2.0。
- 规模：1084 个文件、**566 个 `.mbt`**（`.mbt` 源码合计约 7.6 MB），横跨 30+ 领域目录。
- `math/simplex/simplex.mbt`：**561 行**，文件头自述
  `maximize c^T x  subject to  A x <= b,  x >= 0`，
  “tableau-based primal simplex with Bland's rule for pivot selection”。
- `math/ilp/ilp.mbt`：**527 行**，B&B + LP 松弛 + Gomory 割，
  文件头自述模型为 `maximize c^T x subject to Ax <= b, x >= 0, x integer`。
- 源码关键词命中：`Farkas`=0、`certificate`=0、`presolve`=0、`MPS`=0、`dual`=0、
  `sparse`=0、`revised`=0；`tab`=34/37（确为稠密 tableau）。

**设计边界上的含义**：它不能表达等式/`≥` 约束、变量上下界、自由变量与最小化（需使用者自行变换），
也没有模型文件输入、对偶、presolve 与证书。本项目不与它竞争“是否存在实现”，而是补齐上述工程化
与可验证性要素，并保留“模型 → 求解内核”的对接路径。

### `Luna-Flow/linear-program`（未发布到 mooncakes.io）

- 仓库：0 star / 1 fork；最后提交 2026-06-07；Apache-2.0；约 1.4k 行。
- 内容：建模（`Variable` / `Poly` / `Obj_func` / `Constraint` / `Lp`）+ 标准化 +
  稠密两阶段单纯形（`phase_1` / `phase_2` / `pivot` / `two_stage`）。
- 不包含：整数与 0-1 变量、MPS/LP 标准格式、稀疏结构、presolve、对偶与灵敏度分析、CLI/CI。

**设计边界上的含义**：它的建模/标准化思路可复用，本项目计划提供适配层把它的模型喂进
`moonopt` 的求解内核，形成协作而非重复。

## 本项目在生态中的位置

- MoonBit 现有排产/排班/路由/装箱/约束类项目（`moonbitJobShop`、`moonbit-vrp-solver`、
  `moonbit_constraint`、`fairshift`、`shiftweave`、`neighbor_rota`、`moonsatkit`、`sat-solver` 等）
  多为**启发式或专用**求解，缺一个能给出最优性界与证书的通用精确内核。
- `moonopt` 的目标是成为这些上层项目可以依赖的地基：LP 松弛 → 对偶界 → 分支定界 → 证书校验。
