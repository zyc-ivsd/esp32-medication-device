# BLE 协议目录

这里是 ESP32 固件、Flutter 手机 App 和电脑端测试工具共同使用的协议源文件。

任何协议修改都应同时检查：

1. ESP32 固件；
2. Flutter App；
3. Python 测试工具；
4. `examples/` 中的示例数据。

协议版本升级时，请更新 `version` 字段并在文档中记录兼容性。
