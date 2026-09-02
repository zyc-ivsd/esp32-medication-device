# Flutter 手机 App

## 目标

手机 App 是用户实际使用的软件，负责扫描并连接 ESP32、接收 Notify、保存 SQLite、显示历史记录和导出数据。

## 分层

```text
pages/       Flutter 页面
services/    同步、统计、校时
ble/         扫描、连接、Notify、ACK
database/    SQLite 数据库
models/      记录和设备状态
```

BLE 层只依赖 `protocol/` 中规定的接口，不要让页面直接调用 BLE 插件。

## 开发准备

安装 Flutter 和 Android Studio 后，在此目录运行：

```bash
flutter pub get
flutter analyze
flutter test
flutter run
```

Android 需要配置 BLE 权限。第一版只实现用户打开 App 后主动扫描、连接和同步，不实现全天后台扫描。

## 开源复现

提交经过测试的 `pubspec.lock`，并在根目录 README 中记录 Flutter、Dart、Android SDK 和 BLE 插件版本。iOS 构建需要 macOS 和 Xcode。
