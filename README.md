# ESP32-S3 Medication Device

一个面向开源复现的 ESP32-S3 智能用药装置原型项目。

本项目采用单仓库管理硬件固件、手机 App、BLE 协议、测试工具和项目文档，目标是让其他开发者能够根据公开代码、协议和硬件资料完成复现。

> 本项目是课程/科研原型，不构成医疗器械、诊断或用药建议。

## 系统结构

```text
传感器/按键
    ↓
ESP32-S3 固件：采集、事件识别、Flash 日志、BLE Server
    ↓ BLE
Flutter 手机 App：BLE Client、SQLite、历史记录、数据导出
    ↓
可选 Python 工具：电脑端协议调试、数据分析和测试
```

## 技术栈

- ESP32-S3：ESP-IDF + C/C++。
- 手机 App：Flutter + Dart，第一阶段优先支持 Android。
- BLE：手机作为 Central/GATT Client，ESP32 作为 Peripheral/GATT Server。
- 本地数据：SQLite。
- 辅助工具：Python + Bleak，可选，不是手机 App 的运行依赖。

## 目录说明

| 目录 | 内容 |
|---|---|
| `protocol/` | BLE UUID、数据包、CRC、ACK 和错误码 |
| `firmware/` | ESP32-S3 的 ESP-IDF 固件 |
| `mobile_app/` | Flutter 手机 App |
| `tools/python/` | 电脑端 BLE 调试和数据分析工具 |
| `hardware/` | 原理图、PCB、BOM 和硬件说明 |
| `docs/` | 技术报告、开发流程和测试记录 |
| `samples/` | 模拟记录和示例数据 |

## 快速开始

### 1. 获取代码

```bash
git clone https://github.com/zyc-ivsd/esp32-medication-device.git
cd esp32-medication-device
```

### 2. 查看协议

先阅读：

- [`protocol/ble-gatt.md`](protocol/ble-gatt.md)
- [`protocol/data-format.md`](protocol/data-format.md)

手机 App 和 ESP32 固件必须以协议文档为共同依据。

### 3. 编译 ESP32 固件

安装与项目文档一致的 ESP-IDF 版本后：

```bash
cd firmware/esp32-s3
idf.py set-target esp32s3
idf.py build
idf.py -p PORT flash monitor
```

当前仓库首先提供工程目录和接口文档；硬件组应将已经调通的 ESP-IDF 工程代码放入此目录。

### 4.运行 Flutter App

安装 Flutter 和 Android SDK 后：

```bash
cd mobile_app
flutter pub get
flutter run
```

首次运行前，请按照 `mobile_app/README.md` 配置 Android BLE 权限。iOS 构建需要 macOS 和 Xcode。

### 5. 运行 Python 辅助工具

```bash
cd tools/python
python -m venv .venv
# Windows
.venv\Scripts\activate
# Linux/macOS
# source .venv/bin/activate
pip install -r requirements.txt
```

## 开源复现要求

- 固定 ESP-IDF、Flutter、Dart、Android SDK 和第三方依赖版本。
- 提交 Flutter 的 `pubspec.lock` 和 Python 的依赖锁定文件。
- 提交 `sdkconfig.defaults`、分区表和固件编译配置。
- 保持 `protocol/` 与实际固件/App 实现同步。
- 提供模拟数据，使没有硬件的开发者也能测试界面和数据库。
- 不提交密码、Token、私钥、个人蓝牙地址或未脱敏用户数据。

## 当前状态

- BLE 协议和数据存储：已完成基础联调。
- 硬件：采购中。
- Flutter 手机 App：待继续开发。
- Python 工具：作为可选调试工具保留。

## 许可证

本项目代码采用 MIT License，详见 [`LICENSE`](LICENSE)。第三方依赖仍需遵守其各自许可证。
