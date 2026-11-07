# 文档文风规范化实施计划

> 定位：受众 = 维护者；状态 = active；出处 = `docs/superpowers/specs/2026-09-28-doc-tone-normalization-design.md` 与 `docs/doc-style.md`。

## 目标

按 `docs/doc-style.md` 统一全文文风。只改文字和定位声明；事实、数字、结论、链接目标、`file:line` 和提交 sha 保持不变。内容与实现不符的修订另开一批，按 `docs/superpowers/implementation/2026-09-16-doc-reality-audit.md` 的 35 条处理。

## 范围

1. 根目录文档、`docs/developer`、`docs/maintainer`、`docs/academic`、`docs/ir-schema`、`docs/verifier`、`docs/coq`。
2. `docs/superpowers/specs`、`plans`、`implementation`。
3. `docs/archive` 中的历史设计文档只补定位声明和文风，不改旧结论。
4. `docs/archive/sdd/` 不在版本控制内，不处理。

每份文档保留已有的定位声明、真源规则和分类结构。缺定位声明的文档补一行，写明受众、状态和出处。状态按目录和正文判断：active、superseded、historical 或已完成记录。

## 批次

1. 试点：`docs/developer/syntax.md`、`docs/maintainer/design/execution-model.md`、`docs/superpowers/plans/2026-09-16-criteria-carrier.md`。本批同时验证规范是否合适。已完成。
2. 根目录与 `docs/developer`：README、project-book、glossary、z-vision、developer 下的全部文档。
3. `docs/maintainer`：onboarding、testing、design、adr、proposals。
4. `docs/academic`、`docs/ir-schema`、`docs/verifier`、`docs/coq`。
5. `docs/superpowers/specs`。
6. `docs/superpowers/plans`。
7. `docs/superpowers/implementation`。
8. `docs/archive` 的历史设计文档。

每批单独提交和开 PR。批次内先改文字，再检查链接；`CLAUDE.md` 不在批次内，修改时保留硬性规则标题、#1–#6 编号、`TODO #2026-09-10-3` 引用和自动检查命令，并运行 `tests/harness/test_todo_id_migration.py` 与 `tests/harness/test_block_git.py`。

## 检查

1. 修改前后对同一文件做事实字段对照：数字、sha、`file:line`、链接目标不因文字修改而变化。
2. 链接检查：每个相对链接目标存在。
3. 抽样通读：每批至少复读两份文档，确认陈述句、术语和无装饰符号。
4. 文档不设自动文风检查。链接检查和事实字段对照可以脚本化。

## 不包含

1. 不修改实现、测试和格式。
2. 不把 `docs/archive` 的旧结论改成新结论。
3. 不在本批处理 `docs/pseudocode/`；该目录由源码生成，先确认生成器。
