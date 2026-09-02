# ESP32-S3 ESP-IDF 工程

建议的代码模块：

- `main/`：启动、状态机和任务调度。
- `components/ble/`：GATT 服务、Notify、ACK 和同步状态。
- `components/storage/`：Flash 日志、CRC 和掉电恢复。
- `components/sensor/`：按键、微动开关和差压传感器。
- `components/power/`：电池检测、低电量和电源状态。

代码必须遵守 [`protocol/`](../../protocol/) 中的协议定义。
