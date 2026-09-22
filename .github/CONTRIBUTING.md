# 贡献指南

Core 的开发流程参考 Rust/Linux：**main 即 mainline，任何人（含维护者）不得直推**。
全部改动经 PR + 审查 + 合入门槛进入 main。

## 流程

1. **fork 仓库**，在 fork 上建 feature 分支（`fix/xxx`、`feat/xxx`、`docs/xxx`）
2. 提交改动（请用 jj，见下），推送分支
3. **开 PR——base 指向 `develop` 集成分支**（main 不接受直接合入；main 的合入仅维护者可执行），按 `.github/pull_request_template.md` 填写：
   - 变更描述、测试记录、语义保鲜影响（IR/类型语义是否变化）
4. 等待审查（≥1 审批，审批人限维护者）
5. 审批通过且 PR 层 CI 全绿后，维护者手动 **squash 合入 develop**（merge queue 因免费计划不可用，已降级；见 spec §3.3），源分支由 GitHub 自动删除

## 铁律

- **全面使用 jj，禁止 `git` 命令**（仓库为 jj colocated 形态；维护者本地 Claude Code hook 会拦截 git）
- 长时间编译/测试任务限速运行（`cpulimit -l 10` 或 `nice -n 19`）
- 文件还原必须经维护者明确许可

## 构建与测试

```bash
python3 build_selfhost_native.py   # 自举构建 → build/corec + build/corearch
./build/corec check FILE.cr        # 类型检查
./build/corec run 'fn main()->int{return 42;}'   # 解释器执行

python3 tests/bootstrap/test_pipeline.py   # Python bootstrap 管线测试
python3 tests/selfhost/test_compile.py     # 自举编译器测试
# tests/suite/*.cr 为集成测试：./build/corec build FILE.cr -o OUT --static && ./OUT
```

CI 与本地跑同一套命令（`src/ci/run.sh`，按 `CI_JOB_NAME` 分发）。

## 编码约定

- 全部数组为动态字节缓冲（`string` + grow 函数），无 `MAX_*` 上限
- 扁平 AST / 扁平 IR（每节点为 `{kind, a, b, c, ...}` 结构）
- 每个目录的 `_import.cr` 集中管理共享导入
- 关键字以 `src/compiler/lexer.cr` 为准（唯一）
- 文档（`docs/`）更新与实现同步；伪代码文档（`docs/pseudocode/`）由源码生成，改源码后须重跑 `tools/pseudocode_check.py`

## 审查标准

- 不绕过问题（root cause 直修）
- 语义保鲜：IR 全程保留类型/语义信息
- 惰性/数据流优化不改变程序输出
- 测试随变更更新
