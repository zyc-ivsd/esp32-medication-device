# AI 续作任务说明：ESP32-S3 智能用药装置

> Historical design note: cloud AI, model API configuration, and the gateway were removed in AeroEase 0.4.2. The instructions below do not apply to the current offline app.

> 此文件是早期交接，以下“当前提交”、本地路径和计划均已过时，保留供追溯。继续开发请以根 README、[Android 路线](android-roadmap.md)及本地 Git 实际状态为准；当前只推进 Android。

这份文档用于交给其他 AI 编程工具，帮助其在现有仓库基础上继续开发。请先阅读本文件、根目录 `README.md` 以及 `protocol/` 目录中的协议文档，再修改代码。

仓库地址：<https://github.com/zyc-ivsd/esp32-medication-device>

当前主分支最新提交：`7067e0d feat: add phase one in-app assistant scaffold`

本地仓库位置：`D:\download\esp32-medication-device`

## 1. 项目目标

开发一个面向开源复现的 ESP32-S3 智能用药记录装置：

```text
传感器/按键
    ↓
ESP32-S3：采集、事件识别、Flash 日志、BLE Server
    ↓ BLE
Flutter 手机 App：BLE Client、SQLite、历史记录、AI 助手
    ↓ 可选 HTTPS/WebSocket
AI 网关：RAG 知识库和大模型适配器
```

项目最终希望形成：

```text
低功耗运行 → 设备自检测 → 安全存储 → 可靠同步 → App 分析 → AI/RAG 解释 → 维护反馈
```

项目是课程/科研原型，不是医疗器械。不能宣称已经实现医疗级药量测量、疾病诊断或自动调整药物剂量。

## 2. 当前已经完成的内容

### 已完成或已验证

- 已确定 ESP32 作为 BLE Peripheral/GATT Server，手机作为 Central/GATT Client。
- 硬件组已经使用手机 BLE 调试软件验证了基础 BLE 广播、连接、Notify 信息传送。
- 硬件组已经验证了记录写入 SPIFFS、读取文件并通过 BLE 发送的基础数据存储链路。
- `seq + CRC + ACK + COMMIT` 是最终可靠同步的目标方案，目前硬件原型还没有完整实现。
- 已建立 GitHub Public 仓库和开源目录结构。
- Flutter 手机 App 初始工程已建立。
- Flutter App 已有 `AssistantService`、`AssistantProvider`、`AssistantContext` 和 `MockAssistantProvider`。
- 主页面已有“打开 AI 助手”入口。
- 已提供模拟记录 `samples/demo-records.json`。

### 当前尚未完成

- Flutter 手机端真实 BLE 扫描、连接和 Notify/Write 代码。
- Flutter SQLite 数据库和真实同步服务。
- ESP32 固件目前已有硬件组推送的第一版 Arduino 原型，基础 BLE 和 SPIFFS 数据传输已经可用，但尚未按最终协议和目录完成工程化整理。
- `PowerManager`、`SelfTestEngine` 和 `SecurityManager` 尚未实现。
- RAG 网关尚未实现，目前只有接口说明和预留目录。
- 小智真实云端/语音链路尚未接入。
- 硬件正在采购，传感器和电源参数需要到货后实测。

### 必须优先解决的硬件代码差异

当前仓库中的硬件组原型位于 `firmware/esp32-c3/main/main.ino`，但项目总体设计和多数文档仍以 ESP32-S3 为目标。该原型目前具有以下特征：

- 使用 Arduino BLE API，而不是 ESP-IDF 工程；
- 使用自定义 UUID `4fafc201-1fb5-459e-8fcc-c5c9c331914b` 和 `beb5483e-36e1-4688-b7f5-ea07361b26a8`；
- 以 SPIFFS 中的时间文本文件为数据来源；
- 按最多 30 字节的文件片段发送 Notify；
- 当前没有实现设计文档中的 `SYNC_REQ`、逐条 `ACK` 和 `COMMIT`；
- 发送完成后会清空 SPIFFS，不能直接作为最终的可靠同步实现；
- 代码包含 Deep Sleep 相关函数和 GPIO4 唤醒逻辑，但实际低功耗行为仍需真机验证。

而 `protocol/` 中的目标协议是：ESP32-S3、结构化 20 字节记录、`a100～a104` 服务/特征和 `seq + CRC + ACK + COMMIT`。下一位 AI 可以先为硬件原型编写临时兼容适配器用于演示，但必须把它标记为 Prototype v0，不能把它当作最终可靠协议：

1. 实际采购和使用的芯片到底是 ESP32-C3 还是 ESP32-S3；
2. 最终使用 ESP-IDF 还是 Arduino；
3. 最终 UUID 和数据包格式是什么；
4. 是否采用逐条 ACK/COMMIT，而不是发送后直接清空文件。

建议保留当前原型作为 `prototype-v0`，在不破坏基础 BLE/存储功能的前提下，完成协议统一后再整理为 `firmware/esp32-xxx/` 正式工程。

## 3. 当前主开发路线

手机端主路线使用 Flutter/Dart，不使用 Python 作为手机 App 主程序。

```text
Arduino C++            当前 ESP32-C3 硬件原型
ESP-IDF + C/C++       最终固件路线，芯片待确认
Flutter + Dart         手机 App
SQLite                 手机本地数据
Python + Bleak         可选的电脑端 BLE 调试工具
FastAPI/其他后端       可选的 RAG 网关
```

开发顺序调整为：先保留并验证当前硬件原型，再统一最终协议；同时手机 App 先用 Mock 模式开发，之后增加 Prototype v0 兼容适配器，最后接入最终 BLE 协议、SQLite、三项创新和 RAG。没有网络和没有硬件时，App 仍应能通过 Mock 模式运行。

## 4. 必须遵守的协议规则

详细定义以 `protocol/ble-gatt.md` 和 `protocol/data-format.md` 为准。

### BLE 特征

| 特征 | 方向 | 作用 |
|---|---|---|
| `DeviceInfo` | ESP32 → 手机 | 设备 ID、固件版本、电池状态 |
| `RecordData` | ESP32 → 手机 | Notify 发送记录 |
| `SyncControl` | 手机 → ESP32 | 同步请求、ACK、COMMIT、校时 |
| `SyncStatus` | ESP32 → 手机 | 同步结束、错误、存储状态 |
| `HealthStatus` | ESP32 → 手机 | 建议新增，用于设备自检测状态 |

### 同步流程

```text
手机读取本地 ack_seq
    ↓
发送 SYNC_REQ(ack_seq)
    ↓
ESP32 Notify 发送一条记录
    ↓
手机检查长度、magic、version、CRC
    ↓
手机按 device_id + seq 去重并写入 SQLite
    ↓
手机发送 ACK(seq)
    ↓
ESP32 持久化确认位置并发送下一条
    ↓
发送 SYNC_END
    ↓
手机发送 COMMIT(last_seq)
```

禁止使用“Notify 发送后立即删除”。没有收到 ACK/COMMIT 时，ESP32 必须保留记录。

现有 20 字节记录格式尽量保持兼容。设备自检测信息优先通过新增 `HealthStatus` 特征传输，而不是直接修改旧记录格式；如果必须修改记录格式，必须增加版本号并同步更新三端代码。

## 5. 后续开发阶段

### 阶段 A：保留成果并完成原型兼容接入

优先完成以下工作：

1. 在 `mobile_app/lib/ble/` 建立 BLE 接口抽象，页面不能直接调用 BLE 插件。
2. 建立 `MockBleTransport`，能够回放 `samples/demo-records.json`。
3. 建立 `PrototypeV0BleTransport`，支持当前原型的实际 UUID、Notify 和 30 字节分片。
4. 能够在 App 中显示当前原型传来的时间文本或原始分片，并明确标记为 Prototype v0。
5. 完成设备列表、连接状态和基础数据接收页面。
6. 保留现有 AI 助手 Mock 模式，并将模拟或真实统计摘要传入 `AssistantContext`。
7. 增加 Mock BLE、原型分片重组和协议异常测试。

阶段 A 完成后，开发者可以在没有硬件时运行 Mock 模式，也可以使用实际硬件原型完成基础 BLE 演示。Prototype v0 的数据删除行为不应被描述为可靠同步。

### 阶段 B：统一最终协议并接入 SQLite

在保留 Prototype v0 可演示的基础上完成：

1. 由硬件组确认实际芯片是 ESP32-C3 还是 ESP32-S3，以及最终使用 Arduino 还是 ESP-IDF。
2. 冻结最终 UUID、记录格式、字节序、CRC 和错误码。
3. 在 `mobile_app/lib/database/` 实现 SQLite 表、插入、去重和 `ack_seq`。
4. 在 `mobile_app/lib/services/` 实现 `SYNC_REQ`、逐条 `ACK`、`SYNC_END` 和 `COMMIT`。
5. 固件只有在收到 ACK/COMMIT 后才能回收记录，删除当前“发送完成后直接 `SPIFFS.format()`”逻辑。
6. 测试真实记录、断线续传、重复包、CRC 错误、手机保存失败和 ESP32 掉电。
7. 将最终固件整理到 `firmware/esp32-xxx/`，保留 Prototype v0 代码和说明。

### 阶段 C：三个核心创新模块

#### C1. 低功耗 `PowerManager`

推荐状态机：

```text
DEEP_SLEEP
    ↓ 按键/微动开关/RTC 唤醒
SELF_CHECK
    ↓
MEASURE
    ↓
STORE_FLASH
    ↓
WAIT_SYNC
    ↓ 用户按同步键
BLE_ADVERTISE
    ↓
BLE_SYNC
    ↓
DEEP_SLEEP
```

要求：

- 休眠时关闭 BLE、Wi-Fi、音频、显示和非必要传感器。
- BLE 只在有限时间窗口内广播和同步。
- 第一版使用物理同步按键或 RTC 唤醒，不依赖手机永久后台扫描。
- 记录休眠、采集、BLE 同步和 Wi-Fi/AI 模式的实际电流。
- 手机无法通过 BLE 唤醒处于深度睡眠的 ESP32，这是设计约束，不能在文档中假设手机可以直接唤醒设备。

#### C2. 自检测 `SelfTestEngine`

启动时和每次采集前后检查：

- 传感器是否在线；
- 传感器零点是否异常；
- 压力是否饱和或超范围；
- 事件持续时间是否异常；
- 信号噪声是否过大；
- Flash 是否可读写；
- 电池是否过低；
- BLE 和存储状态是否正常。

输出统一的健康状态和原因码，例如：

```json
{
  "health": "warning",
  "confidence": 62,
  "flags": ["PRESSURE_OUT_OF_RANGE", "SHORT_DURATION"]
}
```

AI 可以解释这些状态，但不能代替底层规则判断。

#### C3. 数据安全 `SecurityManager`

第一版至少完成：

- BLE 配对和安全连接；
- 设备绑定和基本身份校验；
- `seq + CRC + ACK + COMMIT`；
- 手机端按 `device_id + seq` 去重；
- 不在代码中写入 API Key、密码或 Token；
- 云端只接收必要的统计摘要，不默认上传完整原始数据；
- 说明 SQLite 数据保护和 Android Keystore/iOS Keychain 的使用方案。

注意：CRC 只能检查传输错误，不能提供身份认证或保密性。后续可以增加 HMAC、ESP32 Flash Encryption 和手机数据库加密，但不能把“有 CRC”描述为“数据已经加密”。

### 阶段 D：RAG 智能助手

RAG 不直接放在 BLE 链路中，而放在手机 App 和可选 AI 网关之间。

```text
用户问题
    ↓
Flutter AssistantService
    ├── 统计类问题 → SQLite
    ├── 说明类问题 → RAG 知识库
    └── 综合问题 → SQLite + RAG
    ↓
AI 网关
    ↓
回答 + 文档来源 + 数据依据
```

知识库建议包括：

- 设备使用说明；
- BLE 协议说明；
- 校准和维护说明；
- 故障排查；
- 自检测错误码说明；
- 团队审核过的安全规则。

真实 Provider 应新增实现，不要修改现有页面：

```text
AssistantProvider
├── MockAssistantProvider
└── RagAssistantProvider
```

真实网关需要：

- 使用 HTTPS/WebSocket；
- API Key 只保存在服务器；
- 返回回答和来源文档；
- 找不到可靠资料时明确表示“不确定”；
- 不自动改变药物剂量、不删除记录、不进行疾病诊断。

### 阶段 E：三周 MVP 计划

如果硬件组计划三周完成，建议按以下顺序交付：

| 时间 | 软件组 | 硬件组 | 阶段成果 |
|---|---|---|---|
| 第 1 周 | Flutter 页面、Mock BLE、Prototype v0 兼容接收、SQLite 初版 | 保持现有 BLE/SPIFFS 原型可运行，确认芯片型号和 UUID | 手机能显示模拟数据和原型数据 |
| 第 2 周 | 最终数据模型、CRC、SQLite 去重、ACK/COMMIT 同步 | 将原型数据改为结构化记录，停止无条件清空 SPIFFS | 真实数据断线后可继续同步 |
| 第 3 周 | 设备状态页、低功耗/自检测/安全状态展示、AI Mock/RAG 演示 | 启用并测量 Deep Sleep，补充电池和传感器状态 | 完成一次低功耗、安全、可解释的端到端演示 |

如果进度落后，保留顺序为：基础 BLE/存储 → ACK/COMMIT → 低功耗 → 自检测 → 数据安全 → RAG。语音小智和精确药量测量最后处理。

## 6. 推荐代码目录

后续可逐步补充以下目录：

```text
firmware/esp32-s3/components/
├── ble/
├── storage/
├── power_manager/
├── self_test/
├── security/
└── sensor/

mobile_app/lib/
├── ble/
├── database/
├── models/
├── services/
├── pages/
├── device_health/
├── security/
└── assistant/

server/assistant-gateway/
├── app/
├── rag/
├── knowledge/
└── tests/
```

## 7. 不能做或不能宣称的内容

- 不要把 App 改成 Python 主程序。
- 不要在三周原型阶段实现全天后台 BLE 扫描。
- 不要让 BLE 传输语音 Opus 数据。
- 不要声称差压数据已经等同于精确药物质量。
- 不要让 AI 自动调整剂量或替代医生诊断。
- 不要把小智云端账号、API Key 或密码提交到 GitHub。
- 不要为了接入 AI 而破坏已经调通的 BLE 和 Flash 同步协议。
- 不要删除未 ACK 的设备记录。

## 8. 验收标准

### App

- Flutter App 可以在 Mock 模式下运行，无硬件也能演示。
- 可以显示模拟记录、统计次数并打开 AI 助手。
- `flutter analyze` 无错误。
- `flutter test` 通过。

### BLE 与数据

- 能扫描并连接真实 ESP32。
- 能接收 Notify 并校验 CRC。
- 重复包不会重复写入 SQLite。
- 传输中断后可以继续同步。
- 手机保存失败时不会发送 ACK。
- ESP32 在 ACK/COMMIT 前掉电，记录仍然存在。

### 低功耗与自检测

- 能区分睡眠、采集、BLE 同步和 AI/Wi-Fi 模式。
- 能显示低电量、传感器异常、存储异常和记录置信度。
- 至少测量并记录不同工作模式的实际电流。

### 数据安全

- 未配对设备不能直接读取敏感数据。
- 仓库中没有密钥和个人数据。
- App、设备和服务器之间的数据边界写入文档。
- AI 回答显示数据依据或知识库来源。

## 9. Git 开发方式

开始工作前：

```bash
git status
git pull --ff-only origin main
```

每个独立功能使用一个分支，例如：

```text
feature/flutter-ble
feature/sqlite-sync
feature/device-self-test
feature/security
feature/rag-gateway
```

提交信息应说明功能，例如：

```text
feat: add mock BLE transport
feat: persist sync watermark in sqlite
feat: add device health status model
test: cover duplicate record handling
docs: update RAG bridge contract
```

完成一个阶段后必须：

1. 运行可用的测试和静态检查；
2. 检查 `git diff --check`；
3. 确认没有密钥、Token、个人数据和生成物；
4. 更新相关 README/协议文档；
5. 在最终说明中列出修改文件、测试结果和未完成事项。

## 10. 给下一位 AI 的第一步

请按以下顺序执行：

1. 阅读根目录 README、本文件和 `protocol/` 文档。
2. 检查当前 Git 分支、工作区和最近提交，不覆盖已有改动。
3. 检查 Flutter、Dart、ESP-IDF 是否已安装。
4. 先实现 Mock BLE 和 Prototype v0 兼容接收，确保不破坏硬件组已经调通的基础 BLE/存储演示。
5. 与硬件组确认芯片、框架、UUID 和最终数据格式，再实现 SQLite 和 ACK/COMMIT。
6. 依次加入低功耗、自检测和数据安全模块。
7. 再把同步统计接入现有 `AssistantContext`，最后实现真实 RAG Provider，不要一开始依赖云端 API。
8. 完成后运行测试并报告：已完成、未完成、需要硬件组提供的接口，以及 Prototype v0 与最终协议的差异。
