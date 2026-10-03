# Prototype v0.1：C3 时间文本联调协议

此协议由 A+B 合并实现，配套 `firmware/esp32-c3/main/main.ino` 和 Android App 0.3.0；当前加入 TIME1 校时扩展。
当前固件仅在按键时生成原始时间文本，上电和重连不生成记录；它不等于 `data-format.md` 的正式事件协议。
原始文本保存在 `prototype_text.db`，不填写虚构的压力、置信度或事件类型，不计入 A 的正式事件统计。

## GATT 与组帧

Service：`4fafc201-1fb5-459e-8fcc-c5c9c331914b`。
Characteristic：`beb5483e-36e1-4688-b7f5-ea07361b26a8`，Read / Write With Response / Notify，CCCD `0x2902`。

每次 Notify 最多 20 字节，不依赖 MTU 协商。App 按字节缓存到 LF 再解码 UTF-8，最大一行 256 字节。
固件通知格式为 `LF + body + "|" + crc4 + LF`。前置 LF 能使重传从残缺帧恢复；空行忽略。
CRC-16/CCITT-FALSE：poly `0x1021`、init `0xffff`、refin/refout=false、xorout=0，覆盖 body 的 UTF-8 字节，不含末尾分隔符、校验值或 LF。crc4 为四位十六进制。独立标准校验向量 `123456789 → 29b1`。
App 发出的控制命令不带 LF，单次 Write With Response，最多 20 字节。

`token` 为 App 每轮随机生成的 8 位十六进制会话标识。设备 ID 为 12 位 eFuse 芯片标识（与手机系统给出的连接 ID 分开）。`index` 为本轮快照的零起始序号，不是正式事件序号。

| 方向 | body / 控制命令 | 行为 |
|---|---|---|
| App → 设备 | `HELLO` | 先建立 Notify 订阅，再发送；每秒重试，最多 6 次 |
| 设备 → App | `READY\|device_id\|P01\|TIME1` | CCCD 已启用且 App 校验成功后开始校时；旧 P01 三字段 READY 仍可同步，但明确标注不支持校时 |
| App → 设备 | `TIME\|utc_hex8\|offset_minutes` | UTC Unix 秒数为 8 位十六进制，时区为带符号十进制分钟；最多 18 字节 |
| 设备 → App | `TIME_OK\|utc_hex8\|offset_minutes` | 系统时钟设置及 NVS 保存成功后原样确认；仍使用分片、换行及 CRC，匹配本次请求后 App 才自动同步 |
| 设备 → App | `TIME_ERR\|reason` | `BAD_TIME`、`BUSY` 或 `CLOCK_STORAGE`；App 停止自动同步，允许手动重试校时 |
| App → 设备 | `SYNC_REQ\|token` | 请求一个新的文件快照，取消旧轮次 |
| 设备 → App | `BEGIN\|token\|count` | 固定本轮文件总数；最多 256 个 |
| App → 设备 | `START\|token` | 已校验 BEGIN，可以发送第一条 |
| 设备 → App | `R\|token\|index\|file_id\|raw_text` | raw_text 为 `YYYY-MM-DD_HH-MM-SS`，file_id 不含目录前缀 |
| App → 设备 | `ACK\|token\|index` | 必须在 CRC 校验、字段检查及 SQLite 事务成功后发送；相同文件相同内容可以重发 ACK |
| 设备 → App | `END\|token\|count` | 本轮所有记录均已获 ACK |
| App → 设备 | `COMMIT\|token` | 已保存完整连续快照；本原型仅确认收齐，设备保留全部文件 |
| 设备 → App | `DONE\|token` | App 收到才显示本轮完成；重复 COMMIT 返回相同 DONE |
| 设备 → App | `ERROR\|token\|reason` | 显示设备错误，本轮停止，不清空文件 |

## 重试与数据保留

- 校时支持 2000–2099 年、UTC 偏移 ±840 分钟。App 每 2 秒重试同一命令，共最多 3 次；同一连接内固件对相同命令只设一次时钟，再次收到仅重发 TIME_OK，避免重试把时钟调回过去。
- 新固件每次连接先校时再请求同步；手动“校准设备时间”完成后也重新同步。同步期间不校时。旧 P01 固件继续原同步路径；旧 APK 不识别 TIME1，升级时应同时更新固件与 APK。
- BEGIN、R、END 均等待相应应用层回复；固件 1.5 秒超时重试，最多额外 3 次。超过次数发 `ACK_TIMEOUT`，保留文件。
- App 接收期间 12 秒无有效进展报超时；等待 DONE 时每 2 秒重发 COMMIT，最多额外 3 次。
- 坏 CRC 不 ACK，等待设备重发。序号不连续、文件内容冲突、存储失败均停止本轮，不 COMMIT。
- 同设备 `device_id + file_id` 是原型数据库主键；重传不增加数据，同键不同内容拒绝覆盖。
- 断线时清除当前会话，自动重连最多 3 次；用户主动断开/取消扫描会取消延迟重连。重连后重新同步全部保留文件，手机去重；这不是正式协议的游标续传。
- 新文件增加 Preferences 持久计数，防止同秒按键及重启后手动时钟重复造成覆盖。旧原型 `.txt` 仍可读取。
- 发送、断线和 COMMIT 都不调用 `SPIFFS.format()`。挂载使用 `SPIFFS.begin(false)`；挂载失败报告错误。
- 快照期间新增的按钮记录留待下一次点击“重新同步”。保留策略会占用设备容量，超过 256 个文件报告 `TOO_MANY_FILES`，后续需实现有确认边界的回收/分页。

## 时钟与浅睡眠

- 系统时钟存 UTC，原始时间文本使用手机提供的时区偏移；之后手机时区改变，可手动重新校时。已有文件不被改写，旧文件的时区与准确性不能据当前校时结果反推。
- NVS 原子保存 UTC 与偏移。浅睡眠期间 RTC 继续走时；冷启动恢复的是最后已知时间，无法补回断电期间经过的时间，必须再次连接手机校准。首次无快照时使用明确的 2000 年占位，串口提示 `CLOCK_UNCALIBRATED`；校时前按键文本只能作为原型诊断，不能当作准确记录。
- 无连接且无同步、按键或待处理命令，空闲 30 秒后关闭 BLE 并进入浅睡眠。按 GPIO4 按钮唤醒，保留这次按键记录，再恢复广播；睡眠中的设备无法由手机蓝牙连接唤醒。
- Arduino-ESP32 3.3.11 的 BLEService 没有公共析构入口；为避免反复重建 GATT 泄漏，唤醒先写入本次按键记录并保存当前时钟，然后软件重启恢复广播。上电路径不产生额外记录，SPIFFS/NVS 编号不清空；重连后手机再次校时。睡眠 API 失败也回到软件重启路径，不卡在睡眠循环。连接或同步期间不主动睡眠。

## 当前边界

手机校时不证明发生真实服药，也不修正历史文件。正式 20 字节事件协议、传感器事件识别、正式游标及设备文件回收待继续开发；四特征 GATT 不会与本单特征原型混用。浅睡眠的唤醒、重复 BLE 重启及耗电表现需由硬件组在实际板上验收。
