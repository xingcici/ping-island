# 智能审批自动化测试矩阵

这份矩阵用于约束智能审批的发布门槛。所有模型调用都使用确定性假服务，不依赖外部网络或真实 API Key。

| 领域 | 自动化验证 | 主要测试 |
| --- | --- | --- |
| OpenAI 兼容协议 | URL 补全、Bearer Header、JSON Schema、400/422 降级、429 重试、401 不重试、超时、非法 JSON/枚举/空理由、配置校验 | `AIApprovalDecisionServiceTests` |
| 风险策略 | 允许/拒绝 × 低/中/高 × 所有人工确认多选组合 | `testExecutionPolicyCoversEveryRiskDecisionAndManualSelection` |
| 同会话并发 | 3 个不同工具乱序返回后都保留；自动允许、自动拒绝和人工确认混排；人工项依次处理 | `AIApprovalConcurrencyIntegrationTests` |
| 重复 Hook | 同一 `sessionID + toolUseID` 并发投递 12 次，只调用模型一次、只审计一次、只回调一次 | `testDuplicateConcurrentHookDeliveryEvaluatesAndRespondsOnlyOnce` |
| 跨会话高并发 | 16 个会话同时审批，全部完成且模型并发不超过 4 | `testHighVolumeCrossSessionHooksRespectLimitAndAllComplete` |
| 人工竞态 | 模型处理中用户先确认，模型任务取消、记为用户接管且不会再次回调或重新弹窗 | `testUserResolutionDuringEvaluationCancelsModelWithoutDuplicateHookResponse` |
| 失败降级 | 模型超时、接口错误或返回非法结构时保留原审批，转人工处理且不发送自动回调 | `testModelFailureFallsBackToManualApprovalWithoutSendingHookResponse` |
| 事件边界 | AskUserQuestion、通知型/无响应 Hook、显式隐藏提示、Codex bypass 不进入模型审批 | `testIneligibleHookKindsNeverInvokeModel` 及各客户端 Hook 兼容测试 |
| 提示与布局 | 处理中提示开关只改变自动展示；关闭时静默；悬浮提示使用紧凑高度；新请求清除后可再次自动展示 | `testEvaluatingHintSettingOnlyChangesAutomaticPresentation`、`DetachedIslandWindowControllerTests`、`SessionManualAttentionTrackerTests` |
| 设置持久化 | 功能开关、人工风险多选、处理中提示、Base URL、模型、规则和旧模式迁移 | `AppSettingsPersistenceTests` |
| 审计与隐私 | 30 天/1,000 条保留、会话与工具关联、完整上下文和参数导出、清空、API Key 不进入输入/审计错误 | `AIApprovalDecisionServiceTests` |
| Hook 响应格式 | allow/deny/answer 的 Bridge 编码以及并发待响应按 `toolUseID` 独立移除 | `HookBridgeResponseEncodingTests`、Bridge E2E 测试、智能审批并发集成测试 |

发布前执行：

```bash
./scripts/test.sh
```

GitHub Actions `PR Checks` 还必须通过根 Xcode 单测，并成功生成无签名 DMG/ZIP。任何矩阵项失败都不应发布安装包。
