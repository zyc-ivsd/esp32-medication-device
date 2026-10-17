# Firmware — ESP32-C3

The project uses **ESP32-C3** with Arduino firmware in [esp32-c3](esp32-c3/README.md). Firmware CI builds the `esp32:esp32:esp32c3` target.

## Functions

- Record button-generated timestamps in SPIFFS.
- Exchange device records with AeroEase over BLE.
- Calibrate the device clock using UTC.
- Archive transferred files after synchronization commit.
- Manage button input and light-sleep wake behavior.

## Build and integration

Follow the [C3 build instructions](esp32-c3/README.md). Confirm the board revision, flash size, partition layout, and schematic pin mapping before flashing. The app and firmware share handshake, clock-calibration, record-identity, acknowledgment, and commit definitions.

Integration checks cover button recording, reconnect/replay, clock handling, archive rotation, and sleep/wake on the physical C3 board.
