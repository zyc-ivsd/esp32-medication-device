# ESP32-S3 智能用药装置：Flutter 手机 App + 开源辅助工具开发方案


项目拆成两个软件端：


最终用户端：手机 App
开发辅助端：电脑 Python 程序


系统结构：


按键/传感器  ->

ESP32-S3：事件识别 + Flash 本地日志  ->

Flutter 手机 App：BLE Central/Client + SQLite + 图表 + 导出

Python 工具（可选）：协议测试 + 数据标定 + 数据分析


手机 App 是用户实际使用的软件，计划使用 Flutter/Dart 开发；Python 只作为可选的电脑端复现、调试和分析工具，不作为手机 App 的主开发语言。

技术栈：

- ESP32-S3：ESP-IDF + C/C++。
- 手机 App：Flutter + Dart，第一版优先支持 Android，后续可扩展 iOS。
- BLE：`flutter_reactive_ble`，负责扫描、连接、Read、Write 和 Notify。
- 本地数据：SQLite，Flutter 端可使用 `sqflite` 或同类开源库。
- 电脑辅助工具：Python + `bleak`，不是手机 App 的必要组成部分。

Flutter 官方支持 Android 和 iOS；`flutter_reactive_ble` 支持 Android/iOS 的 BLE 扫描、连接、特征值读写和 Notify，并采用 BSD-3-Clause 许可证。依赖版本应在项目中固定，避免不同开发者构建出不同结果。[Flutter 平台支持](https://docs.flutter.dev/reference/supported-platforms) · [flutter_reactive_ble](https://pub.dev/packages/flutter_reactive_ble)

## 1. 参考 UCAS-China 2025 项目

此项目的 App 明确运行在手机或平板上，使用 Ionic + Vue.js 构建，并可部署到 Android 和 iOS。硬件作为局域网 HTTP Server，手机 App 作为 HTTP Client；传感器数据保存在手机本地，并支持导出 CSV。[UCAS-China 2025 Software](https://2025.igem.wiki/ucas-china/software)

通信方式是：

硬件 ← Wi-Fi/HTTP → 手机 App


不是 BLE。

## 2. 本项目

### 第一版须完成

- 记录一次用药事件的时间和序号。
- 将记录可靠写入 ESP32 Flash。
- 手机 App 通过 BLE 连接并同步记录。
- 使用 Notify 发送数据，使用 ACK 防止丢失。
- 手机本地 SQLite 保存历史记录。
- 支持次数统计和 CSV/JSON 导出。
- ESP32 同步后继续进入低功耗状态。

### 以后可能添加的功能

- 医疗级药物质量测量。
- AI 自动修改药物剂量。
- 手机全天高频后台扫描。
- Wi-Fi、BLE、语音和 Deep Sleep 同时工作。


## 3. 软件模块和职责

### 3.1 ESP32 固件

- 读取微动开关和差压/气流传感器。
- 识别一次用药事件。
- 生成连续递增的 `seq` 序号。
- 将记录追加写入 Flash。
- 作为 BLE Peripheral / GATT Server。
- 通过 `RecordData` Notify 发送记录。
- 收到 ACK/COMMIT 后才回收已同步日志。
- 处理 Deep Sleep、唤醒、低电量和掉电恢复。

### 3.2 手机 App

使用 Flutter/Dart 开发。Flutter 负责界面和跨平台代码，BLE 插件负责调用 Android/iOS 原生蓝牙接口。

手机 App 负责：

- 扫描和连接 ESP32。
- 订阅 Notify 特征。
- 校验记录和去重。
- 写入 SQLite。
- 发送 ACK、COMMIT 和校时指令。
- 显示今日次数、历史趋势和设备状态。
- 导出 CSV/JSON。

手机 App 不需要持续后台扫描。第一版采用“用户打开 App 后扫描—连接—同步”的方式，降低手机功耗并减少 Android/iOS 后台限制带来的不确定性。

### 3.3 电脑端 Python 辅助工具（可选）

Python 程序使用 `bleak`，不参与手机 App 的运行，负责：

- 电脑端 BLE 协议验证。
- 模拟记录和测试 SQLite。
- 断线、重复包和掉电流程测试。
- 传感器数据标定和画图。
- 读取手机导出的 CSV/JSON。

如果只做临时 Android 演示，也可以尝试 Python/Kivy；但为了让不同国家的开发者更容易构建 Android/iOS App，本项目主路线使用 Flutter，Python 工具保持可选。

## 4. 低功耗工作状态


DEEP_SLEEP
    │ 按键/微动开关/RTC 唤醒
    ▼
MEASURE
    │ 采集压力特征和用药动作
    ▼
COMMIT_LOG
    │ 先写 Flash，确保掉电不丢
    ▼
WAIT_SYNC
    │ 用户打开 App 或按同步键
    ▼
BLE_ADVERTISE
    │ 广播 15～30 秒
    ▼
BLE_CONNECTED
    │ 手机订阅 Notify
    ▼
SYNC_NOTIFY
    │ 发送记录并等待 ACK
    ▼
COMMIT_ACK
    │ 允许回收已确认记录
    ▼
DEEP_SLEEP


第一版建议用户打开 App 后手动同步，不要求手机永久后台扫描。即使手机没有连接，记录也应一直保存在 ESP32 中。

语音 AI 单独使用：

```text
AI_MODE = Wi-Fi + 麦克风 + 扬声器
SYNC_MODE = BLE
SLEEP_MODE = 无线和音频关闭
```

## 5. BLE 接口约定

以下 UUID 只是示例，必须在 ESP32 固件和手机/Python 两端保持一致。

| 特征 | 方向 | 属性 | 用途 |
|---|---|---|---|
| `DeviceInfo` | ESP32 → App | Read | 设备 ID、固件版本、协议版本、电池电压 |
| `RecordData` | ESP32 → App | Notify | 发送一条用药记录 |
| `SyncControl` | App → ESP32 | Write With Response | 请求同步、ACK、COMMIT、校时 |
| `SyncStatus` | ESP32 → App | Notify | 同步结束、错误和存储状态 |

### 5.1 20 字节记录格式

为兼容默认 BLE MTU，一条记录控制在 20 字节


### 5.2 控制指令


0x01 + last_seq(uint32)       SYNC_REQ：请求发送 last_seq 之后的记录
0x02 + seq(uint32)            ACK：App 已成功保存该记录
0x03 + timestamp(uint32)      SET_TIME：同步设备时间
0x04 + last_seq(uint32)       COMMIT：允许回收该序号以前的记录


## 6. 可靠同步流程

不能采用“Notify 发送完成后立即删除”。Notify 不等于手机数据库已经保存成功。

正确流程：

```text
App 读取本地 ack_seq
        ↓
发送 SYNC_REQ(ack_seq)
        ↓
ESP32 Notify 发送 seq=101
        ↓
App 校验 CRC 并提交 SQLite
        ↓
App 发送 ACK(101)
        ↓
ESP32 持久化确认位置
        ↓
ESP32 继续发送下一条
        ↓
ESP32 发送 SYNC_END
        ↓
App 发送 COMMIT(last_seq)
        ↓
ESP32 回收已确认记录
```

异常情况的处理：

- 传输中断：ESP32 保留未 ACK 的记录。
- 手机保存失败：不发送 ACK。
- 手机重复收到：根据 `device_id + seq` 去重。
- ESP32 在 ACK 前掉电：下次重新发送，手机不会产生重复记录。
- COMMIT 前掉电：记录仍保留。
- Flash 存满：上报错误，不能静默删除未同步数据。

## 7. Flash、时间和日志设计

- NVS：保存设备配置、设备 ID、校准参数和 `ack_seq`。
- 独立日志分区：保存用药事件，采用追加式日志。
- 每条记录带 `magic`、长度、序号和 CRC。
- 启动时扫描最后一条有效记录，忽略掉电造成的损坏尾部。
- 不要每次同步都擦除整块 Flash，只移动日志尾指针并批量回收。
- 设备没有可靠时间时，同时保存 `uptime`；手机连接时下发 Unix 时间。

ESP-IDF 官方建议 NVS 用于配置类小数据，频繁、大量日志应使用独立分区或文件系统，并考虑磨损均衡。[ESP-IDF ESP32-S3 存储 API](https://docs.espressif.com/projects/esp-idf/en/stable/esp32s3/api-reference/storage/index.html)

## 8. 手机 App 页面结构

手机 App 使用 Flutter/Dart 编写，推荐使用 `flutter_reactive_ble` 作为 BLE 层。BLE、数据库和界面分层，便于其他开发者替换 BLE 库或增加 Wi-Fi 通信。

```text
App
├── 设备列表页
│   ├── 扫描设备
│   ├── 连接/断开
│   └── 显示电量和固件版本
├── 同步页
│   ├── 显示待同步条数
│   ├── 显示同步进度
│   └── 显示最后同步时间
├── 用药记录页
│   ├── 今日次数
│   ├── 最近记录
│   └── 历史趋势图
├── 设备详情页
│   ├── 压力特征
│   ├── 有效性置信度
│   └── 低电量提醒
└── 数据导出页
    ├── CSV
    └── JSON
```

手机端将 BLE、数据库和界面分层：

```text
UI 页面
   ↓
业务层：同步、统计、提醒
   ↓
BleService：扫描、连接、Notify、ACK
   ↓
LocalDatabase：SQLite
```

这样以后把 BLE 改成 Wi-Fi HTTP，界面和数据库仍可复用。

推荐的软件目录：

```text
mobile_app/
├── lib/
│   ├── main.dart
│   ├── ble/              # 扫描、连接、Notify、ACK
│   ├── database/         # SQLite 表和数据访问
│   ├── models/           # 记录、设备状态、协议数据结构
│   ├── services/         # 同步、校时、统计
│   └── pages/            # Flutter 页面
├── test/                 # 协议解析、CRC、去重和同步测试
├── pubspec.yaml
└── pubspec.lock
```

手机 App 的 BLE 层应只依赖本节规定的 GATT 接口，不要把具体插件 API 写进业务层。这样以后更换插件时，数据库、图表和同步逻辑不需要重写。



## 9. 电源对软件的约束

ESP32-S3 官方数据中，BLE 发射峰值会随发射功率变化，约为 176～335 mA；Wi-Fi 发射峰值还可能达到约 283～340 mA。Deep Sleep 的几微安是芯片级指标，不代表整块开发板的待机电流。[ESP32-S3 数据手册](https://documentation.espressif.com/esp32_s3_datasheet_en.pdf)

因此软件应：

- 休眠时关闭 BLE、Wi-Fi、OLED、功放和传感器电源。
- 同步时关闭不需要的音频和显示模块。
- BLE 发射功率先使用较低档位，再通过距离测试确定。
- 在电池电压过低时只记录数据，不启动 Wi-Fi。
- 启动无线模块前等待 `PWR_GOOD`。
- 处理 Brownout、连接超时和自动重试。

TLV61220 是升压芯片，TI 的典型 3.3 V 应用示例为 50 mA 输出，不能直接假定它能驱动 ESP32-S3、Wi-Fi、功放和显示屏。单节锂电池电压还要覆盖 4.2～3.0 V，硬件组应评估 Buck-Boost 或其他合适电源方案。[TLV61220 数据手册](https://www.ti.com/lit/ds/symlink/tlv61220.pdf)

## 10. 硬件组提供接口

- 完整 BLE Service/Characteristic UUID。
- 稳定的设备 ID。
- Notify 是否一次发送一条完整记录。
- MTU、连接超时和广播时长。
- `SYNC_END`、`STORAGE_FULL`、`LOW_BATTERY` 等状态码。
- 序号起始值和递增规则。
- 时间校准方式。
- 电池电压读取接口。
- `PWR_GOOD`、低电量和同步按键接口。
- 电源在 BLE/Wi-Fi 启动瞬间的实际电压波形。

## 11. 测试验收

### 通信

- 发送中途断线，重新连接后不丢数据。
- 手机重复收到同一条记录时不重复入库。
- CRC 错误时不发送 ACK。
- 手机保存失败时不发送 ACK。
- 1000 条记录同步后序号和数量一致。

### 掉电

- 写日志时掉电，重启后能恢复有效记录。
- ACK 前掉电，记录仍能重新发送。
- COMMIT 后掉电，手机数据库仍有该记录。
- Flash 存满时显示明确错误。

### 功耗

- 分别测量休眠、采集、BLE 同步、Wi-Fi/AI 四种模式。
- 在电池满电和低电量时测试无线启动。
- 观察 3.3 V 是否下跌、Brownout 或重启。
- 不把 Deep Sleep 和语音 AI 模式放在同一个功耗指标中。

## 12. 开源代码

使用 GitHub 或 GitLab 建立公开仓库，计划包含：

- `firmware/esp32-s3/`：ESP-IDF 固件。
- `mobile_app/`：Flutter 手机 App。
- `tools/python/`：可选的电脑端 BLE 调试和数据分析工具。
- `protocol/`：BLE UUID、数据包、字节序、CRC、ACK 和错误码说明。
- `samples/`：模拟记录和脱敏示例数据。
- `hardware/`：硬件连接图、BOM 和烧录说明。
- `README.md`：从安装环境到运行 Demo 的完整步骤。

为了保证不同地区的开发者可以复现：

1. 在 README 中固定 ESP-IDF、Flutter、Dart、Android SDK 和插件版本。
2. 提交 `pubspec.lock`，并对关键依赖使用明确版本，不使用不受限制的 `^` 版本范围。
3. 在 ESP32 工程中提交 `sdkconfig.defaults`、分区表和固件编译命令。
4. 为手机 App 提供“模拟数据模式”，没有 ESP32 硬件也可以运行界面和数据库测试。
5. 提供 Android APK、源码构建命令和常见 BLE 权限问题说明。
6. 为自有代码选择 MIT 或 Apache-2.0 等开源许可证，并检查第三方依赖许可证。
7. 使用 GitHub Actions 或其他 CI 自动执行 Flutter 测试、静态检查和 ESP-IDF 编译。

Android 可以在 Windows、Linux 或 macOS 上构建；iOS 构建需要 macOS 和 Xcode。因此第一阶段发布 Android APK，同时保留 Flutter 的 iOS 代码和构建说明。

## 13. 目前计划开发顺序

```text
1. 确定数据结构和 BLE 协议。
2. ESP32 发送假数据。
3. Flutter App 完成扫描、连接和 Notify 接收。
4. Flutter App 完成本地 SQLite 保存、去重和 ACK。
5. Python 电脑端工具验证协议、CRC 和同步异常（可选但推荐）。
6. 完成断线续传和 Flash 掉电恢复。
7. 接入微动开关和差压传感器。
8. 增加图表、提醒和数据导出。
9. 测试低功耗、电源稳定性和长期运行。
10. 最后再增加 AI 数据解读。
```

最终验收目标是：

> 手机 App 可以连接设备；ESP32 可以在大部分时间休眠；每次用药记录先写入 Flash；手机 SQLite 成功保存后才 ACK；断连、重启和重复包都不会造成数据丢失。
