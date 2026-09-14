# 贡献指南

本项目处于高强度开发期（见 `docs/roadmap.md`），提交约定如下。

## 本地环境

```bash
moon version --all          # 需要 MoonBit 0.10.7 以上
moon update
git config core.hooksPath .githooks   # 启用 pre-commit（moon check）
```

## 提交前必须全绿

```bash
moon check --deny-warn
moon test --deny-warn
moon fmt && git diff --exit-code
moon info && git diff --exit-code
```

`.mbti` 文件是接口合同，必须随代码一起提交；`moon info` 产生 diff 说明公开接口发生了变化，
请在 PR 描述里说明是否是有意变更。

## 代码规范

- 每个文件用 `///|` 分块，块顺序无关，便于按块重构；
- 数值比较一律使用 `core` 的容差工具，禁止浮点 `==`；
- 新算法必须带三类测试：单元测试、不变量测试、（与 `oracle` 重叠时）差分测试；
- 不扩大承诺的模型类别：能力缺失时返回 `NotSolved` 并给出原因，绝不返回可疑解；
- 新增公开 API 需要同步更新 `README.md` / `docs/design.md` 与 `CHANGELOG.md`。

## 数据与许可

第三方数据集（Netlib、MIPLIB）**不再分发**，只提交下载脚本与清单，见 `bench/README.md`。
新增第三方代码/数据必须在 PR 中说明来源与许可证。
