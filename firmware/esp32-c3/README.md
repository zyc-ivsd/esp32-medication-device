# ESP32-C3 Arduino 原型固件

本目录当前是 ESP32-C3 + Arduino-ESP32 原型。入口 `main/main.ino`，GPIO4 按钮接 GND，串口 115200。

- `components/ble/`：单特征 GATT、CCCD、控制命令队列。
- `components/flash/`：SPIFFS 时间文本、持久文件编号、CRC、逐条 ACK、同步重试。
- `components/time/`：TIME1 手机校时、手机时区偏移、NVS 原子时钟快照；冷启动仍需重新校时。
- `components/deepsleep/`：无连接空闲 30 秒后浅睡眠，GPIO4 按键唤醒后恢复 BLE；连接/同步期间不睡眠。

配套 Android App 0.3.0 的 TIME1 版本，APK 与固件一起更新。当前协议见 [Prototype v0.1](../../protocol/prototype-text-v01.md)，实际操作见 [A+B 联调](../../docs/member-ab-integration.md)。正式事件四特征协议尚未在本固件实现。

从仓库根目录构建：

```powershell
arduino-cli core update-index --additional-urls https://espressif.github.io/arduino-esp32/package_esp32_index.json
arduino-cli core install esp32:esp32@3.3.11 --additional-urls https://espressif.github.io/arduino-esp32/package_esp32_index.json
arduino-cli compile --fqbn esp32:esp32:esp32c3 firmware/esp32-c3/main
```

本次不自动刷板。由硬件组确认板型、端口、原分区设置，再上传。不要启用整片擦除；固件也不会在挂载失败或发送结束时自动格式化 SPIFFS。

原型 COMMIT 只确认手机保存完成，仍保留设备文件供联调复查。最多同步 256 个文件，超过上限显示错误；正式回收、分页和传感器事件协议后续继续实现。浅睡眠关闭无线，先按按钮唤醒再扫描；睡眠唤醒和实际功耗须在板上实测。

纯 C++ 校时命令解析测试（无需开发板）：`g++ -std=c++11 -Wall -Wextra -Werror firmware/esp32-c3/tests/clock_command_test.cpp -o clock-test`，运行生成的测试程序。
