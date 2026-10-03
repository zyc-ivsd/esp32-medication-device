# Android → 助手网关：文字助手协议 v1

> **已废弃（仅作历史资料）。** 自建网关（含 `xiaozhi` / `llm` / `mock` 三种上游）已随小智路线一起放弃；在线助手的现行路线是 App 直连用户自己的模型（BYOK），不再经过本网关。接口与字段记录保留供归档与对比，不再作为交付或验收依据。现行边界见 [`../docs/assistant-model-access.md`](../docs/assistant-model-access.md)。
>
> `/v1/assistant/chat` 是**本仓库实现的网关接口**，既不是小智官方 API，也不是任何一个上游提供的 REST API。官方云接入待确认，详见[官方云说明](../docs/xiaozhi-official-cloud.md)。

网关有三种上游模式，**App 侧接口完全相同**，切换模式不需要改 App：

| `GATEWAY_MODE` | 上游 | 用途 |
|---|---|---|
| `mock` | 无 | 只验证 App → 网关链路；回复明确标记未调用模型 |
| `xiaozhi` | 自建 `xinnan-tech/xiaozhi-esp32-server` 的 WebSocket | 复用社区语音服务端的知识库与角色设定 |
| `llm` | **OpenAI 兼容的 `/chat/completions`** | 直连模型 API，不需要部署小智服务端 |

上游凭据（小智 Token 或模型 API Key）**只存在于网关**；App 输入的是另外生成的网关访问码。

```text
AssistantPage → AssistantService → GatewayAssistantProvider
  → HTTPS JSON 网关 → 小智 WebSocket → LLM / TTS
  ← JSON 文字回答 ← 聚合 TTS sentence_start 文本，丢弃 Opus 音频
```

默认仍使用本地 `MockAssistantProvider`。用户主动启用在线模式并同意发送统计摘要后才联网。现有 ESP32 Arduino 固件及 BLE 路径不因本接入改变。

## HTTP 请求 / 响应

```http
POST /v1/assistant/chat
Content-Type: application/json
Authorization: Bearer <网关访问码；启用鉴权时必填>
```

```json
{
  "schema_version": 1,
  "question": "最近的记录怎么样？",
  "context": {
    "today_count": 2,
    "last_7_days_count": 8,
    "invalid_event_count": 1,
    "unknown_time_count": 1,
    "future_time_count": 0,
    "total_count": 21,
    "daily_counts": [0, 1, 0, 2, 0, 0, 5],
    "last_sync_at": "2026-09-23T08:00:00Z",
    "is_demo": true
  }
}
```

所有字段必填，不接受额外字段。问题去空格后 1–1000 字；计数为 0–2147483647 整数，`is_demo` 为布尔值；`last_sync_at` 可为 null，否则为带时区的 ISO 时间。App 输出 UTC。请求上限 16 KiB。

`total_count` 是全部记录条数（含时间未知与未来时间的记录）。`daily_counts` 是**近 7 天逐日使用动作次数，最早一天在前、今天在最后**，必须正好 7 个元素，且**元素之和等于 `last_7_days_count`**；两者不一致时网关返回 400。逐日序列使模型能够回答“哪几天没有记录”“间隔是否波动”这类问题，而不再是只能报总和。

```json
{
  "schema_version": 1,
  "answer": "演示数据中近 7 天记录了 8 次使用动作。",
  "provider": "xiaozhi",
  "request_id": "服务端生成的追踪标识"
}
```

`provider` 取值为 `mock` / `xiaozhi` / `llm`，App 只用它区分展示：`mock` 会追加演示标记，其余原样显示。网关**不会**在真实上游失败时退回 `mock`。上游文本上限 8000 字；App HTTP 响应上限 64 KiB。

| HTTP | 含义 |
|---|---|
| 400 / 413 | 参数、JSON 或请求大小错误 |
| 401 | 网关访问码无效 |
| 429 | 单实例已有问题在处理；稍后由用户重试 |
| 500 | 网关内部错误（未预期异常） |
| 502 | 上游连接、绑定、协议、会话、空回答或中断错误 |
| 504 | 上游总超时（默认 45 秒）；App 总超时 55 秒 |

错误响应为 `{"error":{"code":"…","message":"…"},"request_id":"…"}`。**所有**响应（成功与失败、包括 413 与未预期的 500）都带 `request_id`，且同一个请求在成功和失败两条路径上是同一个值——用户报「回答不对」时，管理员能凭它把 App 上看到的内容和服务端日志对上，而不需要用户交出问题原文或摘要。未预期异常一律转成 500 JSON，不会漏出 aiohttp 的 HTML 错误页（App 会把非 JSON 响应报成「格式不正确」，反而掩盖真正的问题）。

App 显示本地固定错误说明，不向用户回显上游内部内容；失败时把 `request_id` 作为「请求编号」显示出来。请求不自动重试，HTTP 重定向不跟随。

## WebSocket 适配依据

本轮核对上游提交 [`788f5301fdd60cc3a8ef74025bfeece9b82b94ce`](https://github.com/xinnan-tech/xiaozhi-esp32-server/tree/788f5301fdd60cc3a8ef74025bfeece9b82b94ce)。升级自建服务器后需要重新跑兼容联调。

1. 连接配置的 `ws[s]://.../xiaozhi/v1/`，发送 `Device-Id`、`Client-Id`、`Protocol-Version: 1` 和可选上游 `Authorization: Bearer ...`。
2. 客户端发送 `hello`（version 1、transport websocket、Opus 16 kHz / 单声道 / 60 ms、`features.mcp=false`）。
3. 收到服务器 `hello` 和 `session_id` 后，发送 `{"type":"listen","state":"detect","mode":"manual","session_id":"…","text":"问题与摘要提示词"}`。
4. 累积相同会话的 `tts / sentence_start / text`；收到 `tts / stop` 才算完整成功。忽略 `stt` 回显和 `llm` 表情消息，消费但丢弃二进制音频。连接中断时不返回半截回答。

依据：[文字处理入口](https://github.com/xinnan-tech/xiaozhi-esp32-server/blob/788f5301fdd60cc3a8ef74025bfeece9b82b94ce/main/xiaozhi-server/core/handle/textHandler/listenMessageHandler.py)、[握手](https://github.com/xinnan-tech/xiaozhi-esp32-server/blob/788f5301fdd60cc3a8ef74025bfeece9b82b94ce/main/xiaozhi-server/core/handle/helloHandle.py)、[文字随 TTS 下发](https://github.com/xinnan-tech/xiaozhi-esp32-server/blob/788f5301fdd60cc3a8ef74025bfeece9b82b94ce/main/xiaozhi-server/core/handle/sendAudioHandle.py)、[小智客户端 WebSocket 说明](https://github.com/78/xiaozhi-esp32/blob/main/docs/websocket_zh.md)。

这条路径虽然只在 App 显示文字，上游仍可能生成 TTS，必须配置和验证 LLM、TTS 服务；尚未实现纯文字免 TTS 路径。自动化使用模拟 WebSocket 服务验证协议，不代表团队真实服务器已接通。

## 数据与权限边界

- 只自动发送当前问题与摘要，不发送原始事件、个人蓝牙地址或历史聊天；问题本身可能含用户输入的个人信息。
- 摘要全部是**聚合计数**：不含原始时间戳、设备标识或单条记录，因此无法从摘要反推具体服药时刻。`daily_counts` 也只是 7 个整数，不含日期标签。
- 原型 BLE 时间文本在独立库，不纳入正式统计。动作计数不能用于确认实际服药。
- 上游设备身份、模型密钥和小智 Token 只在服务端；App 输入的是独立网关访问码。
- 每问新建连接、当前实例最多一个处理中请求。**新连接不等于上游无记忆**：小智可能按设备身份保存历史，部署时须为测试专用身份关闭长期记忆、对话报告和外部工具，确认隔离行为。
- 当前仅适合单人/团队受控原型联调；多人账号鉴权、独立上游身份与记忆隔离、限流与运维审计尚未实现。不要让多份网关共享同一个上游设备身份。
- 本网关没有修改记录、调整剂量、触发硬件的接口，也不实现 MCP 客户端。上游服务器自己的工具须另外禁用，不能靠提示词阻止工具执行。

部署命令、鉴权与验收清单见 [网关 README](../server/assistant-gateway/README.md)。
