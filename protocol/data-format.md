# 记录数据格式

## 20 字节记录

为兼容默认 BLE MTU，一条记录控制在 20 字节以内：

| 字段 | 长度 | 说明 |
|---|---:|---|
| `magic` | 1 | 固定 `0xA5` |
| `version` | 1 | 数据格式版本，初始为 `0x01` |
| `seq` | 4 | 设备内递增序号 |
| `timestamp` | 4 | Unix 秒，未校时时为 `0` |
| `event_type` | 1 | `1` 用药动作，`2` 疑似无效，`3` 其他 |
| `duration_ms` | 2 | 事件持续时间 |
| `pressure_peak_pa` | 2 | 有符号压力特征 |
| `confidence` | 1 | 置信度，范围 `0～100` |
| `battery_mv` | 2 | 电池电压 |
| `crc16` | 2 | 对前 18 字节计算 CRC-16/CCITT |

手机 App 和 Python 工具应保留原始压力特征、置信度和算法版本，不要只保存未经验证的“药量 mg”。

## 校验与去重

- 先检查长度、`magic`、`version` 和 CRC。
- CRC 错误时不发送 ACK。
- 数据库主键使用 `device_id + seq`。
- 已存在的记录视为重复包，但可以再次发送 ACK。
