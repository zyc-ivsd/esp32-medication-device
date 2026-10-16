# Firmware

The project hardware target is **ESP32-S3**. The firmware currently checked into this repository is the earlier Arduino implementation in [esp32-c3](esp32-c3/README.md). Its directory, pin assumptions, and CI board target remain explicitly C3-specific.

## Existing implementation

The prototype records button-generated timestamps, retains files in SPIFFS, synchronizes them over BLE, accepts UTC clock calibration, and archives transferred files after the synchronization commit. The app turns valid timestamp files into diary entries.

## Preparing the S3 build

1. Confirm the exact ESP32-S3 module, board, flash size, partition layout, and schematic pin mapping.
2. Adapt the Arduino board configuration and GPIO, USB, BLE, and sleep settings for that board.
3. Keep the app and firmware wire protocol aligned, including handshake, clock calibration, record identity, acknowledgment, and commit behavior.
4. Validate button recording, reconnect/replay, clock handling, archive rotation, and sleep/wake on the physical S3 board.
5. Add a matching S3 CI build after the board configuration is established.

An ESP-IDF implementation is not provided here. Do not flash a C3 binary onto an S3 board or treat a successful C3 build as S3 validation.
