# Device protocol

The AeroEase Android app communicates with the ESP32-C3 firmware over BLE using a shared synchronization contract.

| Document | Scope |
|---|---|
| [BLE GATT](ble-gatt.md) | Service and characteristic definitions |
| [Timestamp synchronization](prototype-text-v01.md) | Timestamp-file transfer and acknowledgment |
| [Structured data format](data-format.md) | Structured-event representation |
| [Examples](examples/) | Message and record examples |

Timestamp synchronization uses HELLO/READY, UTC clock commands `TM` / `TOK` / `TER`, and token-matched synchronization requests. The app acknowledges records after durable storage, commits after all expected indexes have been saved, and marks the round complete after DONE.

Each timestamp payload represents UTC Unix seconds as 16 hexadecimal digits. Timestamp-only records provide a recorded device time. Pressure, duration, confidence, and measured dose are not supplied by this payload.
