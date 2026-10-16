# Legacy ESP32-C3 firmware — Arduino

The project hardware target is now **ESP32-S3**. This directory retains the earlier **ESP32-C3** implementation and build instructions. It is not an S3 firmware release; porting and physical-board validation are required before using it on S3.

## Setup

The sketch entry point is `main/main.ino`. Use the complete firmware tree from `codex/android-xiaozhi-prep`, not an isolated copy of the sketch. The legacy board uses a button between GPIO4 and GND with an input pull-up. Serial output uses 115200 baud.

Components cover BLE synchronization, SPIFFS file storage and archiving, UTC clock commands, and sleep/wake handling. SPIFFS is not automatically formatted on a mount failure.

## Synchronization

1. The app connects, subscribes to notifications, and sends HELLO.
2. Firmware sends READY once notifications are available. TIME1 calibration uses `TM`, `TOK`, and `TER`.
3. A device REQ and matching app SYNC_REQ establish a transfer round.
4. BEGIN/START precede record packets. The app saves original text and the diary entry before ACK.
5. END is followed by COMMIT only when all expected records are stored. Firmware archives the transferred files and sends DONE.

Timestamp payloads contain 16 hexadecimal digits of UTC Unix seconds. Pending `data_` files are transferable; DA/DB archive files are not offered again. An unfinished round must remain recoverable through reconnection and replay.

## Diagnostics

Look for `CONNECTED`, `NOTIFY_SUBSCRIBED`, `CONTROL_RX HELLO`, and `NOTIFY READY` in serial output. `HELLO_WAIT_NOTIFY` indicates that the notification subscription is not ready. READY in the serial log with zero received app bytes points to the notification path. `REQ_SKIP` can indicate no pending files; `SYNC_REQ_IGNORED` requires checking the request token.

NimBLE manages its notification subscription through its own callbacks; do not add a conflicting BLE2902 configuration. Keep firmware and app protocol changes together.

## Legacy C3 build

Run from the repository root:

```sh
arduino-cli core update-index --additional-urls https://espressif.github.io/arduino-esp32/package_esp32_index.json
arduino-cli core install esp32:esp32@3.3.11 --additional-urls https://espressif.github.io/arduino-esp32/package_esp32_index.json
arduino-cli compile --fqbn esp32:esp32:esp32c3 firmware/esp32-c3/main
```

This compiles for C3, not the S3 project target. See the [firmware overview](../README.md) for S3 migration requirements.

## Sleep and verification

Detach the button interrupt **before** configuring the GPIO light-sleep wake source. The opposite order caused the recorded C3 wake failure. [Isolated wake tests](../../ftest/README.md) preserve the diagnostic procedure and earlier results.

Host tests in `tests/` cover clock commands, archive planning, and BLE subscription behavior. CI does not establish physical-board wake or radio reliability. Also consult the [protocol](../../protocol/prototype-text-v01.md) and [integration notes](../../docs/member-ab-integration.md).
