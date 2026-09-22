# cmd/main

`moonopt` 的命令行入口：把库自带的两个示例模型各跑一遍，再跑一个"当前不支持"的模型，
每个都按统一格式打印状态、迭代数或节点数、界、gap 与目标值。

```bash
moon run cmd/main
```

它刻意不读文件也不接参数 —— 需要模型文件、证书导出与基准入口的是 `cmd/parse`
（`moon run cmd/parse -- <file.mps> --solve`）。这里放的是"装完就能跑"的最小入口，
而且**包含那个诚实的失败示例**：一个只展示成功路径的 CLI，会把库真实的能力边界藏起来。

输出示例（首行是版本）：

```text
moonopt 0.1.1
== production plan
status     : Optimal
objective  : 21.00000000002238
```
