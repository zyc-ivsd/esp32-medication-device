# 第一阶段 AI 助手接口

## 当前范围

第一阶段只在 Flutter 手机 App 中实现文字助手和 Mock Provider：

- 不在手机端保存 API Key；
- 不要求联网即可运行 Mock 模式；
- 不通过 BLE 传输语音；
- 不让 AI 修改药物剂量、删除记录或关闭安全提醒；
- AI 只负责对已经统计的数据进行解释。

## App 内部接口

`AssistantProvider` 是 AI 服务抽象层。当前实现为：

```text
AssistantService
    ↓
MockAssistantProvider
```

以后可以替换为：

```text
AssistantService
    ↓
GatewayAssistantProvider
    ↓ HTTPS/WebSocket
AI 网关或小智兼容后端
```

页面和数据库不应直接依赖具体 AI 服务。

## 预留网关接口

后续真实网关可以提供：

```http
POST /v1/assistant/chat
Content-Type: application/json
```

请求：

```json
{
  "question": "我最近的使用情况怎么样？",
  "context": {
    "today_count": 2,
    "last_7_days_count": 12,
    "invalid_event_count": 1,
    "last_sync_at": "2026-09-02T08:00:00Z"
  }
}
```

响应：

```json
{
  "answer": "近 7 天共记录 12 次，其中有 1 条疑似无效记录。",
  "conversation_id": "example-session"
}
```

API Key、模型配置和第三方服务地址必须保存在网关，不得硬编码进手机 App。

## 与小智的关系

小智官方 ESP32 项目主要采用设备通过 Wi-Fi 使用 WebSocket/MQTT 连接后端，语音数据使用 Opus；本项目第一阶段只借鉴其 Provider/网关思想，不把音频链路加入 BLE。

后续若要让 ESP32 运行小智语音模式，应新增独立的 `AI_MODE`，不能让 Wi-Fi、麦克风、扬声器和 BLE 同时成为低功耗模式的必需条件。
