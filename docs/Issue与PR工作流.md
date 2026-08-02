# Friday Issue 与 PR 工作流

> 版本：0.1  
> 日期：2026-08-02  
> 目标：让每项开发工作都有清晰的问题来源、验收条件、审查记录和可回滚边界。

## 1. 核心原则

Friday 按“一个可独立验收的结果”管理工作，而不是按聊天次数、文件数量或提交次数拆分。

```text
Issue：说明为什么做、做成什么样
Branch：隔离一项实现
PR：说明具体改了什么、证据是什么
Merge：形成可追踪、可回滚的项目历史
```

一个 Issue 可以有多个探索提交，但原则上只由一个主 PR 关闭。一个 PR 只解决一个 Issue 的一个完整结果；范围过大时先拆 Issue，不在 PR 中临时扩张。

## 2. 何时需要 Issue

| 变更 | Issue 要求 |
| --- | --- |
| 新功能或用户可见行为变化 | 必须 |
| Bug、回归、隐私、权限或费用问题 | 必须 |
| 架构、跨模块契约或供应商调整 | 必须 |
| 有独立验收信号的重构或测试任务 | 建议 |
| 错别字、纯注释或极小文档修正 | 可不建，需在 PR 中说明豁免理由 |
| 紧急修复 | 可先止损，但必须补 Issue 和证据 |

不要为同一结果创建多个重复 Issue，也不要把多个互不相关的目标放进一个“杂项优化”Issue。

## 3. Issue 内容标准

功能 Issue 至少包含：

- 用户问题，而不是预设技术方案。
- Mike Cohn 格式用户故事：`作为……我希望……以便……`。
- 可观察的验收条件，推荐 Given / When / Then。
- 本次范围和明确非目标。
- 权限、隐私、费用、供应商和外部副作用检查。
- 当前证据、参考资料或待确认问题。

Bug Issue 还必须包含实际行为、期望行为、复现步骤、环境和脱敏证据。无法复现时写明观察范围，不把推测当成根因。

纯技术 Issue 不强行编造用户故事，但必须写清当前证据、工程目标、验证信号、风险和回滚方式。

## 4. 分支规则

基线建立后，不直接在 `main` 开发功能。分支从最新 `main` 创建：

```text
Codex：codex/<issue-number>-<short-slug>
功能：feature/<issue-number>-<short-slug>
修复：fix/<issue-number>-<short-slug>
工程：chore/<issue-number>-<short-slug>
```

示例：`codex/23-dictation-retry`。

分支只服务一个 Issue。发现无关问题时另建 Issue，不顺手混入当前 PR。

## 5. PR 规则

基线建立后，代码和长期文档原则上通过 PR 合并；只有用户明确批准的紧急情况可以直接提交 `main`。

PR 必须：

1. 使用 `Closes #<issue-number>` 关联并关闭 Issue；极小维护写明 Issue 豁免理由。
2. 先说明用户或工程结果，再说明关键实现。
3. 明确范围、非目标、风险、回滚和实际验证证据。
4. 区分“代码已实现”“自动检查通过”和“真实 Mac 验收通过”。
5. 同步源码文件头、`docs/项目结构.md`、路线图和验收文档。
6. 不混入无关格式化、生成文件、用户改动或敏感内容。

PR 应保持在审查者可以一次理解的规模。若同时改变产品行为、底层协议和大量 UI，应先拆成有明确依赖顺序的多个 Issue/PR。

## 6. 审查与合并

- 自动门禁通过不替代真实 Mac 验收；权限、麦克风、屏幕与跨应用写回仍需人工验证。
- 影响隐私、费用、权限或不可逆操作的 PR，必须得到产品负责人明确确认。
- 未解决的阻断性 Review 意见不能通过后续口头承诺绕过。
- 默认使用 Squash Merge，让一个 PR 在 `main` 上形成一个清晰提交。
- 合并标题推荐：`<type>: <结果摘要> (#<issue>)`。
- 合并后确认 Issue 已关闭，必要时把未完成内容拆成后续 Issue。

## 7. Label 与 Milestone

建议 Label：

- 类型：`feature`、`bug`、`architecture`、`test`、`documentation`。
- 产品：`dictate`、`talk`、`agent`、`platform`、`backend`。
- 风险：`privacy`、`permission`、`cost`、`external-side-effect`。
- 状态：`needs-evidence`、`needs-decision`、`blocked`、`ready-for-review`。

Milestone 对应产品路线阶段，例如 `Phase 1 - Input`、`Phase 2 - Realtime`、`Phase 3 - Screen Context` 和 `Phase 4 - Agent`。Label 用于分类，Milestone 用于阶段交付，两者不互相替代。

## 8. Agent 执行边界

- 编程 Agent 开始功能、Bug 或架构任务前，应先确认对应 Issue 和分支。
- 未经用户明确授权，Agent 不创建外部 Issue、PR、不推送分支；可以先完成本地分支和提交，并报告待执行的外部步骤。
- Agent 不虚构 Issue 编号或 PR 链接。远端不可用时明确标记为“待创建”。
- 用户直接提出的新需求如果没有 Issue，Agent 应先帮助整理 Issue 内容，再获得授权后创建或由用户创建。
- 最终交付必须报告 Issue、分支、PR、提交和验证状态。

## 9. 初始化例外

仓库第一次建立可追踪历史时，允许在空的 `main` 上创建一次本地基线提交。该提交只用于纳入当前项目和协作模板，不代表其中所有产品能力都已完成真机验收。

基线提交完成后，本例外失效；后续工作执行 Issue → Branch → PR → Merge 流程。
