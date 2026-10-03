# 小智接入开发交接（Android）

> **2026-09-30 更新：小智路线（官方云 + 自建智控台）已整体放弃，本文仅作历史资料。** 在线助手的现行路线是 App 直连用户自己的模型（BYOK），API Key 只能是用户自己的、绝不出手机，见 [`assistant-model-access.md`](assistant-model-access.md)。下面的分支交接、官方云核查与接入顺序不再作为待办主线。

**继续开发的分支：`codex/android-xiaozhi-prep`。** `main` 尚未包含 Android 0.3.0、A+B BLE 合并与助手接口。克隆后执行 `git fetch origin`、`git switch --track origin/codex/android-xiaozhi-prep`，在此分支上新建自己的功能分支；不要从 `main` 或旧 `ble_connect` 开始。

> **2026-09-29 更新：本文余下的“官方云”方向已核查为 App 不可用。**
>
> 官方设备激活要求用 ESP32 eFuse 里的 HMAC KEY0 对服务器 challenge 签名，手机算不出来；官方也没有给第三方 App 的聊天 API。在线助手现在走本仓库网关的三种上游（`mock` / `xiaozhi` / `llm`），其中**知识库 RAG、角色设定和大模型都在自建 `xiaozhi-esp32-server` 的智控台里配**。
>
> 本文下面的官方激活核查步骤保留作为**证据记录**，不再作为待办主线。结论和可操作步骤见 [`xiaozhi-official-cloud.md`](xiaozhi-official-cloud.md) 与 [`../server/assistant-gateway/README.md`](../server/assistant-gateway/README.md)。

## 分支审核

| 分支 | 与推荐分支的关系 | 处理 |
|---|---|---|
| `codex/member-a-records-app`、`ble_connect`、`codex/member-ab-ble-integration` | A 的离线记录、B 的 BLE 和 A+B 可靠同步均已包含在推荐分支的提交历史中 | 不再重复合并 |
| `codex/ios-readiness` | 推荐分支的祖先；保留的 iOS 历史不属于当前 Android 目标 | 不作为接入起点 |
| `lightsleep`、`try_deepsleep` | 硬件组独立实验，与现有固件的 BLE、Flash、主循环有重叠修改 | 不自动合并；由硬件组先确认板型、睡眠唤醒与 BLE 重连行为，再逐项迁移并真机测试 |
| `main` | 推荐分支的祖先，缺少后续 App 与小智准备工作 | 不从这里开发小智 |

`try_deepsleep` 的主循环、广播重启和按键处理都与当前 BLE 文件同步逻辑相交。直接合并可能让连接/重传路径退化；这里保留硬件实验历史，不宣称其已经通过现有 App 的同步协议验收。

## 现有代码和真实边界

- `mobile_app/lib/assistant/assistant_provider.dart` 是回答接口；`providers/mock_assistant_provider.dart` 是默认本地规则实现，`providers/gateway_assistant_provider.dart` 是旧自建 HTTPS 网关客户端，`providers/direct_llm_assistant_provider.dart` 是用户自带 Key 的直连实现。`assistant_page.dart` 管界面与「本地/在线」切换，`assistant_api_console.dart` 管多份在线 API 的查看/选择/修改/删除，`assistant_settings_dialog.dart` 只是单条配置的表单（含发送摘要前的同意）。
- `mobile_app/lib/assistant/models/assistant_context.dart` 定义可发送的统计摘要。原型 BLE 时间文本存于独立库，不进入这份摘要，也不代表实际给药。
- `server/assistant-gateway/` 与 `protocol/xiaozhi-bridge.md` 属于上一阶段自建 `xiaozhi-esp32-server` 的文字适配。`POST /v1/assistant/chat` 是本仓库接口，**不是小智官方 API**；团队网关模式只接受这个地址，此外用户也可以选择在 App 里直连自己的 OpenAI 兼容模型服务（Key 只存本机）。
- `firmware/esp32-c3/` 是 Arduino BLE 时间文本原型，未实现小智官方设备激活、OTA 与官方云会话。`protocol/prototype-text-v01.md` 是当前 App 与设备的原型同步依据。
- 官方 WebSocket 文档主要描述设备身份、令牌、`hello` 和音频/控制消息。尚无本项目已验证的 Android 独立客户端凭据流程；先按 [官方云接入核查](xiaozhi-official-cloud.md)确认是否获支持，不能把设备密钥或共享测试令牌塞入 APK。

## 接入顺序和验收

1. 与硬件组确认实际 ESP32-C3 模组、固件版本、设备身份和官方激活能力；取得官方公开文档或支持回复，确认 Android 是否能作为独立文字客户端。将依据和适用版本记入本仓库。
2. 若官方支持该路径，用**自己的测试账号和设备**完成激活与脱敏的文字往返，验证重装、断线、令牌失效和账号隔离。若不支持，先报告结论，再选择官方支持的设备侧方案或另行评估服务端方案。
3. 在 `AssistantProvider` 下新增获官方支持的实现和对应设置界面；保留默认离线助手。每次联网前明确征得同意，仅传必要的当次问题与摘要；凭据使用 Android 安全存储，不写入源码、APK 构建参数、Wiki 或日志。
4. 增加协议、失败恢复和隐私边界测试；用真实 Android 手机与硬件记录端到端证据。测试应区分 mock、旧自建网关和官方服务，不能用模拟 WebSocket 测试宣称官方云已经接通。

## 复现和基线检查

Android 构建入口、依赖版本及安装步骤见 [`mobile_app/README.md`](../mobile_app/README.md)。从仓库根目录运行：

```bash
cd mobile_app
flutter pub get --enforce-lockfile
flutter analyze
flutter test
flutter build apk --debug
```

旧网关的独立测试可在 `server/assistant-gateway/` 执行 `python -m unittest discover -s tests -v`。2026-09-28 在本地复跑为 **9/9 通过**；已保存的 2026-09-23 App 验证日志为 **57 个 Flutter 测试通过、analyze 无问题、debug APK 已构建**，本次审核机器没有可调用的 Flutter，因此没有把旧日志当作新一轮 App 实测。分支推送后的 Android CI 也只验证代码和模拟上游，不替代官方账号、真机 BLE 或整机测试。
