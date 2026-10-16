# Device protocol

The Android app and firmware must implement the same wire contract, regardless of the board model. The project uses ESP32-C3, with its firmware implementation under `firmware/esp32-c3/`.

- [BLE GATT](ble-gatt.md): service and characteristic design.
- [Prototype text synchronization](prototype-text-v01.md): timestamp-file transfer and acknowledgment.
- [Structured data format](data-format.md): structured-event design, distinct from timestamp-only files.
- [Examples](examples/): protocol examples.
- [Historical Xiaozhi bridge](xiaozhi-bridge.md): archived integration design, not the current product direction.

The current timestamp path uses a HELLO/READY handshake, UTC clock commands `TM` / `TOK` / `TER`, and token-matched synchronization requests. Records are acknowledged after durable storage; the app commits only after all expected indexes have been saved, and completes the round after DONE. Check both app and firmware implementations when an older document uses different command names.

Each timestamp payload represents UTC Unix seconds as 16 hexadecimal digits. Timestamp-only files do not provide pressure, duration, confidence, or measured dose. Do not fill missing structured fields with invented values.
