# Changelog

本文件记录每个版本的可见变化。格式参考 [Keep a Changelog](https://keepachangelog.com/)，
版本号遵循 [Semantic Versioning](https://semver.org/)。

## [Unreleased]

### Fixed — M3 (pivot stability check and one recovery attempt)

- **枢轴稳定性校验**（新选项 `pivot_relative_tolerance`，默认 1e-8）：比值检验选出的主元若小于
  该次方向最大元的这一比例，说明基逆已陈旧，内核先重建逆再重做比值检验后才枢轴。
  判断是**相对**量：绝对值阈值会在良态小问题上误触发、在病态大问题上沉默；
- **一次数值失败恢复**（新选项 `start_with_bland`）：运行以数值失败结束时，从初始基**重启一次**，
  改用 Bland 规则（确定、不会循环）并把重新分解间隔压到不超过 100。恢复结果同样必须通过残差自检，
  仍失败则返回**原始失败**并保留原始消息。
  效果：presolve 后的 `noswot` 报数值失败（基近奇异）→ 现在求到最优 `obj = -43`（171 次迭代），
  与无 presolve 的直接求解**结果一致**，两条独立路径互为旁证；
- **`--presolve` 的目标值显示修正，外加一道独立对照**：化简运行优化的是**化简后**的模型，
  其目标值不含被消元变量的贡献；此前 CLI 直接打印这个值，在 `flugpl` 上与未化简的结果差
  **162 000**，看起来像错答案，实际只是标签错（重建解在原模型上的目标值是
  `1167185.7255923206`，与未化简的 `1167185.7255923208` 一致）。
  现在打印的是加上 offset 后的原模型目标值，并且每次化简运行都会做**独立对照**：
  用原模型的目标向量重算重建解的目标值，与报告值对拍，不一致就标 `DISAGREES` ——
  "解可行但数字不对"这类错误因此进不了报告。300 行口径全量下 15 个最优实例全部通过该对拍；
- **诚实记在消息里**：恢复成功的运行会带 `recovered from a numerical failure by restarting with Bland's rule (...)`
  ——"重新走了一条路"和"那条路本来就对"不是一回事，报告不该混为一谈。

- **`bench/report-solve.ps1` 支持 `-Presolve`，并被切换为基准口径**：报告表格新增
  `presolve`（化简前后规模与各项计数）与 `check`（还原解在原模型上的最大行/界违反、
  以及用原模型目标向量重算的目标值）两列；任何重建检查失败（`FAILED` / `DISAGREES`）
  都会**拒绝写报告**（退出码 5）。基准报告现在同时是 presolve 正确性的证据：
  15 个最优实例的重建解全部通过三项检查，其中 `noswot` 的一次 Bland 恢复也被如实记录进报告；
- 报告脚本的括注解析改为贪婪匹配：恢复消息自带一层括号
  （`... with Bland's rule (basis became numerically singular)`），非贪婪模式会静默只留下内层。

- **基准口径提到 1000 行，并因此多解出 4 个实例**：报告从 `-MaxRows 300` 提升到
  `-MaxRows 1000`（用时 142 秒），`danoint`（664 行）、`bienst1` / `bienst2`（576 行）、
  `fiber`（363 行）进入可解范围：**19 最优 / 11 跳过 / 2 拒绝 / 0 数值失败**，
  19 个重建解全部通过三项检查，交叉校验 **19 项 0 违反**；
- 两个拒绝实例把化简的价值与边界都摆了出来：`30n20b8` 被化简掉 **7282 个变量**
  （18380→11098，内核行 18956→11591，降 39%），仍需约 1.0 GB 基逆；
  `fast0507` 是集覆盖问题，几乎没有可约的上限行（63009→63001 个变量），内核仍需 63490 行、
  约 30.8 GB —— 两者都在**分配之前**被拒绝，而不是崩溃或静默跳过；
- `bienst1` / `bienst2` 在报告里给出同一个松弛最优值 `11.724137931034488`（各 2130 次迭代），
  与官方最优值方向一致，闭合了早先"同一实例两个目标值"的疑点：那次 `obj = 11` 是崩溃进程的
  被污染读数，不是内核的第二个答案。

### Changed — M3 (the basis is factored sparsely, and the row ceiling moves with it)

- **稠密基逆换成稀疏 LU**：内核过去维护 `m×m` 稠密基逆，这正是规模上限的由来 ——
  MIPLIB 的 `fast0507`（内核 63490 行）需要约 30 GB，只能被门禁拒绝。现在改为
  **左看式稀疏 LU**（`P·B = L·U`，行主元按列内最大元选、阈值**相对**该列量级），
  每次单纯形需要的三种求解都走三角求解：`B x = b`、`Bᵀ y = c`（对偶值与 `B⁻¹` 的一行）。
  内存从 `O(m²)` 变成 `O(nnz + fill)`；
- **L 的元素按"原始行号"记录，而不是按位置号**：行主元交换会改变行↔位置映射，
  按位置记录的列会在后续交换中悄悄指向错误的行。这是实现过程中真实踩到的 bug，
  也正是两个 LU 测试（因子重建矩阵、两种求解对拍稠密参考）抓出来的；
- **测试 +4（共 92）**：因子重建 `P·B`、两种求解与测试内置的稠密参考一致（含 `B·x = b` 与
  `Bᵀ·y = c` 的残差回代）、奇异基被拒、带状基的因子保持稀疏（400 行三对角，元素数不到 `m²/8`）；
  测试内置稠密参考是有意的：随求解器一起发布的"参考"算不上参考；
- **规模门禁随之改口径**：`max_kernel_rows` 默认 4000 → **200000**（内存已线性，行数不再是真正的限制），
  并新增 `max_factor_entries`（默认 2×10⁷）作为**填充量预算** —— 填充是稀疏分解唯一无法事先预测的量，
  超预算即让分解失败，而不是无上限分配；
- **实测**：`30n20b8`（presolve 后 11591 行）**16 秒求到最优**，目标值 `1.5664076454608626`
  与稠密基逆时代的 `1.5664076455872395` 相差 1.3e-10 —— 两套线性代数后端的交叉印证；
  `fast0507`（63490 行）**不再被拒绝**，能跑起来，但 Phase I 在 500 次迭代（61 秒）内未收敛，
  其边界已从"内存"变成"时间"；1000 行口径报告里 `refused` 归零。

### Fixed — M3 (the root cause of the numerical failures: degeneracy, not scaling)

- 先测量后修改：扫描 noswot 的系数幅度是 **0.25 – 21（跨度比 84，中位数 1）**——
  这是个**良态**模型，所以"病态尺度"不是病根，行列均衡被测量直接否掉（省下一整套不会被用到的子系统）。
  真正的病根是**退化**：presolve 收紧的界把大量变量压到边界上，上界行的松弛基值成片为 0，
  比值检验面对 `min(0, 0)` 这样的平局无从选择，一连串退化枢轴正是基漂移到近奇异的途径；
- **新增退化扰动**（`degeneracy_perturbation`，默认 **1e-12**）：求解用的右端项按确定性模式加上
  `ε·(1+|bᵢ|)` 的微扰以打破平局；**残差自检始终针对未扰动的右端项**，所以扰动运行仍必须对调用方
  写下的模型可行。默认值是被测出来的：`1e-9` 能修好 noswot 但会移动目标值超过测试断言的 `1e-9`
  相对精度；`1e-12` 下 noswot **158 次迭代直接求到最优、不再触发 Bland 恢复**（此前 500 次迭代 +
  恢复），且全部精度断言仍然成立；
- 这解释了此前"presolved noswot 报基奇异"之谜的另一半：不是尺度、不是漂移、不是 eta 稀疏化取舍，
  而是退化。Bland 恢复保留为**最后一道**防线（它解决的问题依然存在），但不再是这类实例的必需路径。

### Changed — M3 (presolve becomes the default path of the public entry points)

- `SolveOptions` 新增 `presolve: Bool`（**默认 true**）：`solve` / `solve_with` 现在先化简再求解，
  并把解还原回**原变量**。还原结果必须**同时**通过三项检查才以 `Optimal` 返回：原模型的行、
  原模型的界、以及用原模型目标向量重算出的目标值与报告值一致；任何一项不过即返回 `NotSolved`
  并附上实测违反量。化简能自行证明不可行/无界时直接返回该判定，不启动内核；
  化简消掉全部变量时其自身答案也要过同一套检查。
- **整数模型不经化简**：内核在 M5 之前拒绝整数变量，这个承诺不能取决于化简是否碰巧把所有整数
  变量定住（那也正是一个非整数固定值会溜进来的地方），因此含整数变量的模型直接交给内核领取拒绝理由；
  相应地，测试里针对内核"迭代上限"与"整数拒绝"的用例显式传 `presolve: false`，让它们继续测内核本身。
- 新增 3 个门面测试（化简独立解出模型并还原取值、化简路径与仅内核路径一致、化简自证无界），
  测试总数 88。`cmd/main` 与两个示例的输出不变（production plan 目标 21、transportation 目标 11）。

### Added — M3 (presolve: model reduction and postsolve)
- `presolve` 包：空行/列消元、活动范围推出的冗余行、singleton 行转界、隐式界收紧、
  固定变量消元（含目标常数偏移）与 `postsolve` 解还原；证明不可行或无界时返回判定而不是调用内核。
  公开接口：`presolve`、`ReducedModel::{reduced,stats,verdict,reason,objective_offset,
  reconstruct,objective}`，以及 `max_row_violation` / `max_bound_violation` —— 后两个是
  **独立于化简记账**的可行性检查，还原解必须自己站得住；
- 测试 85 个（新增 10）：9 个手工可验的化简用例 + 150 个随机模型的差异测试
  （状态一致、目标值一致、还原解在原模型的行与界上可行）。生成器专门覆盖无约束列、
  上下界相等、singleton 行、宽松行与无穷界；差异测试还断言化简至少在这 150 例中的 40 例真正触发，
  否则"一致"就是空话；
- `cmd/parse --presolve`：逐实例打印化简前后规模与各项计数，并打印还原解在原模型上的
  最大行/界违反，可行才标 `(feasible)`；
- 实测（wasm、单进程）：`blend2` 274→186 行 / 353→336 变量 / 17 固定 / 108 界收紧，
  `khb05250` 1350→1299 变量 / 51 固定 / 2596 界收紧，`dcmulti` 290→272 行 / 533 界收紧，
  目标值与无 presolve 完全一致，还原解全部可行；
- **已知阻塞项**：`noswot` 在界收紧后内核于重新分解时报基奇异。已测量：基矩阵原始形态下无零行、
  无零列、无重复基列（尺度 21，相关列原始最大元为 1），但消元后该列候选元变为精确 0 /
  ~7e-17 —— 属该基的线性相关或近奇异。已排除"重新分解间隔过疏"（500→100/50 仍失败）与
  "eta 权重丢弃判据"（不丢弃仍失败，实验已回滚）。下一步方向见 `docs/roadmap.md`：
  行列均衡、基修复、枢轴稳定性校验。因此 presolve 暂不作为默认求解路径。

### Fixed — M3 (numerical robustness and a size gate that fails instead of crashing)

- **守卫式 Harris 比值检验**：第二遍按数值偏好选出主元行后先模拟这一步，
  若有基本变量会被推出可行性下限（`-tol·(1+|xb|)`）就退回严格最小比值行。
  Harris 的带宽是相对量，超调量却是"带宽 × 主元元素"，在比值与元素都在 1e5 量级的实例上
  足以把基本变量推负：`noswot` 因此以缩放负值 4.2e-4 报数值失败，修复后求到最优 `obj = -43.0`
  （官方 MIP 最优值 `-41.00000885`，松弛值更小，方向一致）；
- **`SimplexStatus::TooLarge` 与 `SimplexOptions::max_kernel_rows`（默认 4000）**：
  内核在分配稠密基逆**之前**按实测行数拒绝。每个有限上界都会变成一行，
  所以模型行数不能代表内核规模：`fast0507`（507 条约束、63009 个 0/1 变量）的内核规模是
  63516 行，稠密基逆需要约 30.8 GB，此前在 native 目标上以访问冲突（exit `0xC0000005`）退出，
  并因巨量换页拖垮整机；现在同一实例返回 `too-large` 并以 0 退出。
  这是边界声明，不是错误答案：拒绝带着实测数字回来，调用方可以据此行动；
- **`bench/report-solve.ps1` 拒绝写不能自证的报告**：内核退出码非零，
  或覆盖实例数与清单条数不符时直接失败。此前一次 native 崩溃被写成
  "optimal=17 skipped=5" 的完整报告（实际只跑了 22/33 个实例）。
  同时修正 `solve=` 列被空格截断的解析问题，并删掉清单里重复的 `danoint` 一行。
- **崩溃期的两个"结果异常"用探针排除**：`bienst2` 单独运行与跟在 `flugpl` 之后运行时
  结果完全一致（`obj = 11.724137931034488`，2054 次迭代），不存在跨求解状态泄漏；
  崩溃前出现的 `obj = 11` 与停在 `blp-ar98` 的访问冲突属于同一次巨大分配之后的同一个窗口。
  `blp-ar98` 单独运行正常（16021 变量 / 1128 约束，按行数上限正确跳过，8 秒干净退出）。

- **报告与内核重新对齐（提交 `d4f749a`）**：重跑 300 行口径全量清单 —— 32 个实例全覆盖、
  15 最优、17 跳过、**0 数值失败、0 规模拒绝**，单进程 native release 用时 83 秒；
  15 项松弛值对 MIPLIB 官方最优值表交叉校验 **0 违反**。`bench/solve-report.md` 重新生成，
  `bench/README.md` 的对拍表、`README.md` 的能力声明与 `docs/roadmap.md` 同步更新。
  这也是规模门禁落地后"全量清单不再崩溃"的一次实测，而不是推断。

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
