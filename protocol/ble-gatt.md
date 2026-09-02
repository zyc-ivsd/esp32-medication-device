# BLE GATT 接口

## 角色

```text
ESP32-S3：BLE Peripheral / GATT Server
手机 App：BLE Central / GATT Client
```

ESP32 深度睡眠时不保持 BLE 连接。第一版采用手机打开 App 后主动扫描、连接和同步。

## UUID

以下 UUID 为仓库模板。请将硬件组已经调通的 UUID 填入并冻结，之后以本文件为唯一协议来源。

| 项目 | UUID | 属性 | 用途 |
|---|---|---|---|
| Service | `0000a100-0000-1000-8000-00805f9b34fb` | — | 项目 BLE 服务 |
| `DeviceInfo` | `0000a101-0000-1000-8000-00805f9b34fb` | Read | 设备 ID、固件版本、电池电压 |
| `RecordData` | `0000a102-0000-1000-8000-00805f9b34fb` | Notify | 发送一条记录 |
| `SyncControl` | `0000a103-0000-1000-8000-00805f9b34fb` | Write With Response | 同步请求、ACK、COMMIT、校时 |
| `SyncStatus` | `0000a104-0000-1000-8000-00805f9b34fb` | Notify | 同步结束、错误和存储状态 |

## 控制指令

| 指令 | 格式 | 说明 |
|---|---|---|
| `SYNC_REQ` | `0x01 + last_seq(uint32)` | 请求发送 `last_seq` 之后的记录 |
| `ACK` | `0x02 + seq(uint32)` | 手机已校验并保存该记录 |
| `SET_TIME` | `0x03 + timestamp(uint32)` | 同步设备 Unix 时间 |
| `COMMIT` | `0x04 + last_seq(uint32)` | 允许回收该序号以前的记录 |

所有整数使用小端序。Notify 发送完成不代表手机数据库已经持久化，必须使用应用层 ACK。

## 同步规则

```text
手机读取本地 ack_seq
    ↓
发送 SYNC_REQ(ack_seq)
    ↓
ESP32 Notify 发送记录
    ↓
手机校验 CRC、写入 SQLite、去重
    ↓
手机发送 ACK(seq)
    ↓
ESP32 继续发送下一条
    ↓
发送 SYNC_END
    ↓
手机发送 COMMIT(last_seq)
```

未收到 ACK 的记录不能删除。手机根据 `device_id + seq` 去重。
