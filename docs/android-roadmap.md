# Android 当前路线与交接（2026-09-23）

当前代码在本地分支 `codex/android-xiaozhi-prep`，App 版本 `0.3.0+3`。团队只交付 Android；iOS 代码保留，自动 CI 停止。团队已把小智目标从自建服务调整为官方云；现有 Android 代码尚未连接官方云。

> **2026-09-30 更新：小智路线（自建 + 官方云）已整体放弃。** 在线助手的 forward 路线锁定为 **App 直连用户自己的模型（BYOK）**——API Key 只能是用户自己的、加密保存在手机（`flutter_secure_storage`），调用时直接发送给所选模型服务、不经过团队服务器。下面派发表里第 2/3/4 项（核对官方云激活、开发官方 Provider）不再排期；在线能力已由 `DirectLlmAssistantProvider` 直连实现，并补了设备端 RAG 检索与朗读。规则见 [`assistant-model-access.md`](assistant-model-access.md)。

## 本轮已经补齐

- Android 主 manifest 的联网权限；本地 / 在线助手切换，发送问题与摘要前确认。
- 可替换的网关 Provider：HTTPS、访问码、超时、大小限制、错误提示；配置只放当前页面内存，不在 APK 内预埋密钥。
- 可运行 Python 网关：mock 联调模式，以及社区自建小智 WebSocket 文字适配；逐句接收文字，完整结束后返回。这是旧方案，可留作兼容演示。
- 网络与协议测试；Android CI；更新当前说明并标记旧 iOS / 双平台计划为历史。

这些是代码与自动化能力，不代表 Android 真机、真实小智模型或整机链路已经验收。

## App 侧本地规则助手（2026-09-29）

已在 `codex/android-xiaozhi-prep` 上完成，并经 CI 验证（analyze 0 issue、65 项测试、debug APK 构建通过）：

- 助手摘要从 5 个汇总计数扩展为**总数 + 近 7 天逐日序列**，因此能回答“哪几天没有记录”“分布是否均匀”这类问题。契约见 [`protocol/xiaozhi-bridge.md`](../protocol/xiaozhi-bridge.md)，网关侧强制校验逐日之和等于 7 天总数。
- 新增本地规则引擎 `mobile_app/lib/assistant/rules/observation_rules.dart`（9 条观察，分 info / attention 两级）；规则与文案见 [`assistant-local-rules.md`](assistant-local-rules.md)。
- 概览页新增“需要留意”卡片，与助手**共用同一套规则**；助手页摘要卡片画出逐日次数，快捷问句增加“有什么建议？”。
- 以上均不联网、不需要账号、不需要设备。

**仍然受限**：助手的输入是**正式记录**（`RecordSummary`），而正式事件帧尚未冻结（见下表第 6 项）。所以目前只有“导入演示数据”时助手才有内容可解释；原型 BLE 时间文本**不会**进入摘要。相关前置条件见 [`assistant-data-requirements.md`](assistant-data-requirements.md)。

## 接下来按这个顺序派发

| 顺序 / 负责人 | 任务 | 交付与验收 |
|---|---|---|
| 1 · Android 成员 | 安装本轮 APK，验收本地功能；网关 mock 可验证上一阶段通信代码 | 机型/Android 版本、截图、问题清单；mock 明确标记演示 |
| 2 · 硬件组 + 项目负责人 | 核对官方云允许的设备身份、OTA 激活与客户端流程；明确当前 ESP32-C3 Arduino 是否能在不泄漏 eFuse 密钥的前提下完成官方激活 | 官方书面接入依据、板型/固件能力、账号/设备配对步骤；确认 Android 是否可作为独立客户端 |
| 3 · 软件组 + 硬件组 | 用专用测试设备和官方账号完成首次激活；验证获准凭据如何安全交给 App；发送文字问题并接收完整回答 | 无真实药物数据的端到端记录；确认是否要迁移固件或仅增加设备侧安全签名能力 |
| 4 · Android 成员 | 只有第 2、3 项证明官方支持且有可实现的凭据来源后，开发正式官方 Provider、凭据安全存储、用户授权和错误恢复 | 官方账号下成功文字问答；重启/换手机后的绑定行为清楚；其他队伍可用自己的账号复现 |
| 5 · B + 硬件组 | 使用同一开发分支的 TIME1 固件/APK，验收手机校时、空闲 30 秒浅睡眠、按键唤醒与重复恢复广播；继续验证保存后 ACK、重传去重、断线/掉电文件保留 | Android + ESP32 逐项联调记录；至少 10 轮唤醒重连，实测通过后整合 main |
| 6 · A + B + 硬件组 | 明确正式事件帧，完成解码 → 事务入正式库 → 连续 ACK/COMMIT；定义正式事件时间质量，继续游标续传、日志回收 | 真实事件出现在历史/统计/助手；未知与未来时间口径正确；断线/掉电不丢记录、不提前回收 |
| 7 · Android 成员 | 正式发布签名，覆盖升级保留数据库；如官方 Provider 最终启用，安全保存官方凭据 | 团队保管发布密钥、可安装正式包、升级结果；不把 debug 包标作正式版 |
| 8 · Wiki 成员 | 更新架构为 Android → BLE / SQLite；小智目标记为“官方云待验证/接入”，保留自建网关作为历史备选 | 使用已验证证据，分别写“已实现”“已验收”“待联调”，不把计划写成已完成 |

第 1、2、5 项可并行。官方激活方式没有确认前，不要开发假想的 Android Token 登录、不要求组员部署自有服务器，也不要把共享测试 Token 当作正式复现方式。事件同步必须以双方确认的正式协议为依据，不能凭原型时间文本推断药物、剂量或实际服药。

## 交接给组员的文件

- App 与构建：[mobile_app/README.md](../mobile_app/README.md)。
- 官方云接入前置条件：[xiaozhi-official-cloud.md](xiaozhi-official-cloud.md)。
- 上一阶段自建网关：[server/assistant-gateway/README.md](../server/assistant-gateway/README.md)、[协议](../protocol/xiaozhi-bridge.md)。
- 硬件联调：[member-ab-integration.md](member-ab-integration.md)、`protocol/` 与对应固件。
- A/B 正式入库接口：[member-a-handoff.md](member-a-handoff.md)。

无需提供 Mac。App 是否要改固件取决于官方认可的激活/客户端路线，目前尚不能承诺维持 Arduino 不变或改用 ESP-IDF；须由官方接入要求和硬件实测决定。
