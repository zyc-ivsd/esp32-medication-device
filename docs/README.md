# 项目文档入口

**当前只推进 Android。在线助手由 App 直连用户自己的模型（BYOK）；小智和自建 Python 网关已退出当前路线，相关资料保留为历史。0.3.2 已移除演示数据，概览、历史、CSV 和助手统计只使用设备事件记录。**

- [Android 当前路线与分工](android-roadmap.md)：本轮任务与验收入口。
- [小智接入可行性与限制](xiaozhi-official-cloud.md)：官方云为何不可用、自建智控台怎么配 RAG。
- [小智接入开发交接](xiaozhi-developer-handoff.md)：推荐分支、代码入口和验收边界。
- [A+B 硬件联调说明](member-ab-integration.md)：现有 BLE 原型操作。
- [正式数据层接口](member-a-handoff.md)：供正式协议接入参考。
- [本地专家 / 联网大模型接入与边界](assistant-model-access.md)：本地规则、用户模型 Key、手机端 RAG 与朗读。
- [助手本地规则与安全红线](assistant-local-rules.md)：设备记录观察、空记录行为、禁用词。
- [App 安装与构建](../mobile_app/README.md)。
- [自建小智网关操作](../server/assistant-gateway/README.md)。
- [助手请求与上游协议](../protocol/xiaozhi-bridge.md)。

历史资料：[原开发方案](development-plan.md)、[旧 AI 续作说明](ai-continuation-task.md)、[A 验证记录](member-a-validation.md)、[iOS 构建交接](ios-readiness.md)。历史文件中的计划、测试数量和分支只代表对应日期，不能代替当前进度。BLE 格式以 `protocol/` 与实际固件共同核对为准。
