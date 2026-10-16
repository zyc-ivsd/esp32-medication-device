# Firmware — ESP32-C3

The project uses **ESP32-C3**. Its Arduino firmware is maintained in [esp32-c3](esp32-c3/README.md), and firmware CI builds the matching `esp32:esp32:esp32c3` target.

## Implementation

The prototype records button-generated timestamps, retains files in SPIFFS, synchronizes them over BLE, accepts UTC clock calibration, and archives transferred files after the synchronization commit. The app turns valid timestamp files into diary entries.

## Build and integration

Follow the [C3 build instructions](esp32-c3/README.md). Confirm the board revision, flash size, partition layout, and schematic pin mapping before flashing. Keep the app and firmware wire protocol aligned, including handshake, clock calibration, record identity, acknowledgment, and commit behavior.

Validate button recording, reconnect/replay, clock handling, archive rotation, and sleep/wake on the physical C3 board. Automated builds do not replace these hardware checks. The firmware uses Arduino; an ESP-IDF implementation is not provided here.
