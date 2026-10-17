# ESP32-C3 firmware — Arduino

This directory contains the project's **ESP32-C3** Arduino firmware and build instructions. Firmware CI uses the matching `esp32:esp32:esp32c3` board target.

## Setup

The sketch entry point is `main/main.ino`. Build the sketch together with the component files in this directory. The prototype board uses a button between GPIO4 and GND with an input pull-up. Serial output uses 115200 baud.

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

## C3 build

Run from the repository root:

```sh
arduino-cli core update-index --additional-urls https://espressif.github.io/arduino-esp32/package_esp32_index.json
arduino-cli core install esp32:esp32@3.3.11 --additional-urls https://espressif.github.io/arduino-esp32/package_esp32_index.json
arduino-cli compile --fqbn esp32:esp32:esp32c3 firmware/esp32-c3/main
```

This compiles for the project's ESP32-C3 target. See the [firmware overview](../README.md) for integration and validation guidance.

## Sleep and verification

The sleep-entry sequence detaches the button interrupt before configuring the GPIO light-sleep wake source. [Isolated wake tests](../../ftest/README.md) compare the configuration sequences and report wake causes.

Host tests in `tests/` cover clock commands, archive planning, and BLE subscription behavior. Physical-board checks assess wake behavior and BLE connectivity. See the [protocol](../../protocol/prototype-text-v01.md) for message definitions.
