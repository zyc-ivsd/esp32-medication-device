# CI

- `android-check.yml`：自动静态检查、Flutter 测试、Android debug APK，以及 Python 网关协议测试。Flutter 3.47.4 的 Linux 安装包固定 SHA256，Python 使用 3.12。
- **`flutter analyze` 对 warning 和 info 一律返回失败**：必须修到 **0 issue**。const 相关提示（`prefer_const_constructors`、`unnecessary_const`、const 构造函数里的断言）最常出现在测试文件中。
- **在 fork 里跑 CI 需要两步**：Settings → Actions 启用 Actions；把默认分支改为包含 workflow 文件的开发分支（否则 Actions 页面只显示“从模板新建”引导页，也没有 `Run workflow` 按钮）。
- `ios-check.yml`：历史 iOS 验证，改为仅手动触发，不随 Android 提交自动启动。
- Android APK 是内部测试包；CI 的 debug 签名可能与本地包不同，不能保证相互覆盖安装。正式发布密钥和商店发布尚未配置。
- CI 使用模拟 WebSocket，不连接真实小智、不需要生产密钥，也不代替 Android + ESP32 真机联调。
- 固件编译 CI 仍待硬件组统一 Arduino 工程组织和依赖后添加。
