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

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File bench/fetch-instances.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File bench/report-parse.ps1
```

两个脚本只用 ASCII 字符：Windows PowerShell 5.1 读取**没有 BOM** 的 UTF-8 脚本时会按 ANSI 解码，
非 ASCII 字符会变成乱码。新增脚本请遵守这一约定。

## 报告

- `parse-report.md`：解析报告。含工具链版本与产生它的提交哈希，因此每个数字都可追溯到具体代码；
  记录每个实例的规模、整数列数与校验结论，失败的实例逐条给出原因与位置。
- 后续里程碑会加入求解报告（目标值、与公开已知最优值的相对误差、迭代数、耗时）。

## 报告原则

1. 只报告**实测**结果，不写没有测量支撑的推测；
2. 失败要显式：超时、迭代上限、数值失败、超出能力边界分别统计，不合并成“其他”；
3. 每次报告携带运行环境（`moon version --all`）与提交哈希，保证可复现；
4. 数据不入库，脚本入库，报告入库。
