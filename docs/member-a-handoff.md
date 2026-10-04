# 成员 B：接上 BLE 即可复用的 App 数据层

> A 数据层接口参考；A+B 原型已合并，不必重新接入扫描页。2026-09-23 的剩余任务见 [Android 路线](android-roadmap.md)，本轮不再推进 iOS。

## 先用起来

从 `mobile_app/README.md` 启动 App，进入设备连接页确认蓝牙接收。A 已完成记录模型、SQLite、历史 / 统计、CSV 和助手摘要；你负责通信状态和正式协议同步。0.3.2 已移除演示数据，完整设备事件入库前显示空统计。页面自动化测试用例提供测试输入，不要把原型时间文本直接变成正式使用记录。

## 页面接入

在 `lib/main.dart` 启动应用时传入 `connectionBuilder`，把你实现的连接组件放到概览预留位置：

```dart
runApp(MedicationDeviceApp(
  connectionBuilder: (context, deviceRepository) {
    // DeviceConnectionCard 是 B 接下来实现的组件。
    return DeviceConnectionCard(repository: deviceRepository);
  },
));
```

该参数始终是设备数据库。不要使用随界面切换的 `controller.repository` 写 BLE 数据。连接组件应持有服务实例并管理订阅生命周期，避免每次 build 创建新连接。

## 正式记录的保存契约

入口：`RecordRepository.saveValidatedRecord(MedicationRecord record)`。

| 结果 | B 应做什么 |
|---|---|
| `inserted` | 已提交 SQLite 事务，可发送该记录 ACK |
| `duplicate` | 同设备、同序号且所有保存字段完全一致，可重发 ACK |
| 抛出异常 | 不发送 ACK；显示错误并保留设备端记录以便重试 |
| `RecordConflictException` | 序号相同但内容不同，停止此同步，核查设备 ID、重启 / 序号规则；不覆盖旧数据 |

顺序必须是：**长度 / magic / version / CRC 校验 → 解码 → await 入库 → ACK**。下面只展示调用顺序，其中 decoder / transport 是 B 的实现：

```dart
final record = decoder.decodeAndValidate(packet, deviceInfo);
await deviceRepository.saveValidatedRecord(record);
await transport.sendAck(record.seq);
```

校验或入库异常应在外层处理；不要在 `finally` 或忽略保存结果后发送 ACK。数据库接口不校验 CRC，也不发送 ACK / COMMIT。事务成功之后如果 ACK 丢失，设备重发相同记录仍能安全确认。

`MedicationRecord` 保存 Unix 秒、事件类型、持续时间、有符号压力特征、置信度、电压、协议版本和可选算法版本。算法版本不在现有 20 字节记录内，需双方约定其来源与重传一致性；不要填写虚构值。模型不能被解读为药量或确认服药。

## 断线续传的位置

`readSyncCursor(deviceId)` 读取的是**本机已连续持久保存的位置**，不代表设备已收到 COMMIT。它与“曾收到的最大序号”分开保存。

收到并校验正式 `SYNC_END` 后，按协议确定连续保存范围，调用：

```dart
await deviceRepository.advanceSyncCursor(
  deviceId, lastSequence,
  firstSequence: sessionFirstSequence, // 首次推进必填，来自双方约定的同步信息
);
await transport.sendCommit(lastSequence);
// 按最终协议确认整轮同步成功之后：
await deviceRepository.markSyncCompleted(DateTime.now());
```

数据库拒绝越过缺失序号或倒退。第一次的起点不能拿“第一个碰巧收到的包”猜，也不能用 `MIN/MAX(seq)` 猜。重连后的 COMMIT 重试和成功确认方式由 B 与固件共同实现。

当前键为 `device_id + seq`，不支持同设备 ID 的序号回绕或重置后复用。必须在接正式设备前冻结稳定 ID、序号起点、会话 / 重启规则；若协议需要 epoch/session，应双方同步修改模型、主键、游标并增加迁移。

## 周末联调顺序

1. 硬件组确认板型、固件版本和 GATT UUID；先修复原型发送后 `SPIFFS.format()` 清空记录的问题。
2. B 完成 Android / iOS 蓝牙权限状态、扫描、连接、订阅，显示 Prototype v0 原始文本；目前 A 的 APK 尚不能连接设备。
3. 双方冻结正式包小端序、完整 CRC 参数与共享测试向量、DeviceInfo / SyncStatus / SYNC_END 格式，再接正式记录入库。
4. 检查重复包、坏 CRC、存储失败、缺失序号、断线重连、设备重启 / 掉电；没有成功保存的包不能获 ACK，没有完整保存的范围不能获 COMMIT。
5. 手机上检查重启后的记录、CSV 分享、助手数字；分别记录 Android 与 iPhone 结果。

## 交给 Wiki 的材料

架构图可画“设备 → BLE / 校验（B）→ SQLite（A）→ 历史 / 统计 / CSV → 助手摘要”。A 能提供三张演示界面与自动化测试证据；B 补真机连接截图与同步录屏。Android+iOS 可写为共同开发目标，实测平台与演示数据需在证据说明中标明。

后续改进：大量记录分页 / SQL 聚合、CSV 临时文件清理、数据库升级迁移、正式协议会话标识、真实助手网关和小智语音。现阶段本地数据层不依赖这些功能。
