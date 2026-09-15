# 基准数据与报告

## 数据政策（重要）

**本仓库不再分发第三方测试数据集。** 只提供下载脚本、清单与报告；数据落在 `bench/data/`，该目录已被
`.gitignore` 忽略。

| 数据集 | 来源 | 获取方式 |
| --- | --- | --- |
| MIPLIB 2017 | <https://miplib.zib.de> | `bench/fetch-instances.ps1` 下载 `.mps.gz` 并就地 gzip 解压为纯 MPS |

### 为什么不用 Netlib LP 测试集

netlib 的 `lp/data/` **不是纯 MPS**：文件由一行 `NAME`、一行维度头，随后是它自己的压缩记录组成
（netlib 的 emps 容器）。在实现该容器的解压器之前，这些文件无法直接读取，因此解析报告改用
MIPLIB 2017 —— 它提供同样性质的工业实例，但以纯 MPS（gzip 压缩）发布。

如果将来要接入 Netlib，正确做法是先实现/移植 emps 解压，而不是把压缩数据喂给 MPS 读取器。

## 脚本

| 脚本 | 作用 |
| --- | --- |
| `fetch-instances.ps1` | 下载实例到 `bench/data/instances/`，生成 `manifest.txt`（相对路径，可移植） |
| `report-parse.ps1` | 通过 `moon run cmd/parse -- --manifest ...` 解析全部实例，生成 `parse-report.md` |
| `report-solve.ps1` | 加 `--solve --relax --max-rows N` 求解，生成 `solve-report.md` |
| `check-relaxation-bounds.ps1` | 把求解报告里的目标值与 MIPLIB 官方最优值表对拍 |

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File bench/fetch-instances.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File bench/report-parse.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File bench/report-solve.ps1 -Relax -MaxRows 300 -Presolve
powershell -NoProfile -ExecutionPolicy Bypass -File bench/check-relaxation-bounds.ps1
```

`report-solve.ps1` 用 **native release** 目标运行内核：同一实例在默认 wasm 目标上要慢约 6 倍
（实测 `mod010`：wasm 119.6s / native debug 203.6s / native release 18.8s），
报告里的每个结果与耗时都来自 native release。

`report-solve.ps1` 在两种情况下**拒绝写报告**并以非零码退出：内核退出码非零
（崩溃或某个文件解析失败），或解析到的实例数与清单条数不一致。一次 native 崩溃曾被写成
"22/33 实例成功"的报告，而报告是仓库里唯一的实测证据，不能把一次没跑完的运行写成一次跑完的运行。

## 行数上限有两个，别混淆

| 上限 | 位置 | 含义 |
| --- | --- | --- |
| `--max-rows N` | `cmd/parse` | **模型约束数**，超过即报 `solve=skipped`，不进入内核 |
| `max_kernel_rows` | `SimplexOptions`（默认 4000） | **内核行数**，超过即返回 `SimplexStatus::TooLarge` |

内核行数 = 模型约束数 + **每个有限上界一行**（本里程碑还没有 bounded-variable pivot）。
因此只看模型行数会漏判：`fast0507` 是 507 条约束，但 63009 个 0/1 变量各带一条上界行，
内核规模是 **63516 行**，稠密基逆需要 **约 30.8 GB**。此前 native 目标在这里直接以
访问冲突退出（`0xC0000005`）并造成整机换页卡顿；现在内核在**分配之前**改用实测数字拒绝：

```
solve=too-large obj=0 iters=0 (kernel problem has 63516 rows, above the 4000 row limit of
this milestone; the dense basis inverse would ask for about 30779.13 MB. ...)
```

4000 行对应 128 MB 的稠密基逆（4000² 个 double）。这个上限是**当前里程碑的边界**，
不是算法结论：稀疏基分解落地后它会随之上移。

四个脚本只用 ASCII 字符：Windows PowerShell 5.1 读取**没有 BOM** 的 UTF-8 脚本时会按 ANSI 解码，
非 ASCII 字符会变成乱码。新增脚本请遵守这一约定。

## 报告

- `parse-report.md`：解析报告。含工具链版本与产生它的提交哈希，因此每个数字都可追溯到具体代码；
  记录每个实例的规模、整数列数与校验结论，失败的实例逐条给出原因与位置。
- `solve-report.md`：求解报告。记录模式（是否 LP 松弛）、行数上限、工具链版本与提交哈希，
  逐实例给出状态、目标值与枢轴迭代数；非最优结果逐条如实列出，包含内核自检测得的残差与负值。
  当前这份由带 `-Presolve` 的运行生成：**32 个实例全覆盖、15 最优、17 因行数上限跳过、
  0 数值失败、0 规模拒绝**，并且每个重建解都在**原模型**上通过行、界与目标值三项检查。
  报告里每行还带 `presolve`（化简前后规模与各项计数）与 `check`（还原解在原模型上的
  最大行/界违反，以及用原模型目标向量重算出的目标值）两列 —— 化简是实验的一部分，
  它的记账必须自己站得住。

## 交叉校验（外部权威，独立于本实现）

`check-relaxation-bounds.ps1` 把求解报告里的目标值与 **MIPLIB 2017 官方最优值表**
（`miplib2017-v26.solu`）对拍。松弛问题的目标值不可能超过原问题最优值，所以每个求到最优的实例
都给出一个可判定不等式；一旦松弛值超过官方最优值，就说明内核错了。

最近一次结果（与 `solve-report.md` 同批实例，15 项全部对拍）：

| 实例 | 松弛目标值 | 官方最优值 | 结论 |
| --- | ---: | ---: | --- |
| flugpl | 1 167 185.7256 | 1 201 500 | 松弛 ≤ 最优 |
| blend2 | 6.9157 | 7.598985 | 松弛 ≤ 最优 |
| dcmulti | 183 975.5397 | 188 182 | 松弛 ≤ 最优 |
| gt2 | 13 460.2331 | 21 166 | 松弛 ≤ 最优 |
| khb05250 | 95 919 464 | 106 940 226 | 松弛 ≤ 最优 |
| markshare1 | 0 | 0.999999999999 | 松弛 ≤ 最优 |
| markshare2 | 0 | 1 | 松弛 ≤ 最优 |
| misc07 | 1 415 | 2 810 | 松弛 ≤ 最优 |
| mod010 | 6 532.0833 | 6 548 | 松弛 ≤ 最优 |
| noswot | −43 | −41.00000885 | 松弛 ≤ 最优 |
| p0201 | 6 875 | 7 615 | 松弛 ≤ 最优 |
| pk1 | 0 | 11 | 松弛 ≤ 最优 |
| rout | 981.8643 | 1 077.56 | 松弛 ≤ 最优 |
| 22433 | 21 240.5262 | 21 477 | 松弛 ≤ 最优 |
| 50v-10 | 2 879.0657 | 3 311.1799841 | 松弛 ≤ 最优 |

**15 项校验，0 项违反。** 这不是正确性证明，但能廉价地排掉一整类错误，而且结论是记录下来的，
不是假定的。表里每一行都由 `check-relaxation-bounds.ps1` 从报告文件直接生成并对拍。`noswot` 一行
也说明了为什么这类对拍值得做：它的松弛值 `-43` 比 MIP 最优值 `-41.00000885` 更小才是正确的方向。

## 报告原则

1. 只报告**实测**结果，不写没有测量支撑的推测；
2. 失败要显式：超时、迭代上限、数值失败、超出能力边界分别统计，不合并成“其他”；
3. 每次报告携带运行环境（`moon version --all`）与提交哈希，保证可复现；
4. 数据不入库，脚本入库，报告入库。
