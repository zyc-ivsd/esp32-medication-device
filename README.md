# parcel — AreoEase

AreoEase is the Android companion app for parcel's portable aerosol delivery project. It transfers device timestamps over Bluetooth, stores them on the phone, and presents a medication-use diary with daily counts, history, CSV export, and an offline rule-based assistant. The interface is English with a lavender and peach palette.

## Hardware target: ESP32-S3

**ESP32-S3 is the project hardware target.** The checked-in Arduino firmware under `firmware/esp32-c3/` and the firmware CI build still target the earlier ESP32-C3 prototype. They are retained under their original names so build instructions remain accurate. This repository does not yet establish an S3-compatible firmware build or successful S3 hardware validation. Select and validate the S3 board configuration before flashing an S3 device.

## User workflow

1. Open AreoEase on an Android phone and connect through the device page.
2. Synchronize button-generated timestamps over BLE.
3. Review medication-use times and daily counts in Overview and History.
4. Export selected entries as CSV or ask the local assistant about the stored counts.

The team defines one valid button-generated timestamp as one medication-use entry. This is a diary convention, not a measurement of delivered dose or proof of inhalation. Replaying the same device/file identity does not add another entry.

## Data and privacy

Original device text is retained locally, and valid timestamps populate the diary. A record is acknowledged only after its required local writes succeed. Incomplete synchronization can be retried; conflicting content under an existing identity is rejected. Unknown or future timestamps remain inspectable but do not contribute to current daily counts.

The product direction is offline assistance without cloud AI or runtime demonstration data. Legacy online-provider code, settings, and gateway experiments remain in this checkout; documenting the offline direction does not remove those network paths. The local assistant uses fixed rules, not an on-device language model.

## Development

Continue development on **`codex/android-xiaozhi-prep`**. The historical branch name does not imply a current Xiaozhi integration requirement.

```sh
git clone https://github.com/zyc-ivsd/esp32-medication-device.git
cd esp32-medication-device
git checkout codex/android-xiaozhi-prep
cd mobile_app
flutter pub get --enforce-lockfile
flutter analyze
flutter test
flutter build apk --debug
```

The Android app is **AreoEase 0.4.1+7**. The development toolchain uses Flutter 3.47.4, Dart 3.13.3, JDK 17, and Android SDK 36. Android 7.0 / API 24 or later is required. Debug APKs are intended for testing; retain the application ID and signing certificate for in-place updates that preserve local data.

## Repository guide

| Directory | Contents |
|---|---|
| [mobile_app](mobile_app/README.md) | Flutter Android app and tests |
| [firmware](firmware/README.md) | Hardware target and retained prototype firmware |
| [hardware](hardware/README.md) | PCB, schematic, Gerber, and BOM assets |
| [protocol](protocol/README.md) | BLE and record-format documentation |
| [ftest](ftest/README.md) | Isolated firmware diagnostic sketches |
| [docs](docs/README.md) | Development notes and historical handoffs |
| [tools/python](tools/python/README.md) | Desktop helper-tool area |
| [server/assistant-gateway](server/assistant-gateway/README.md) | Legacy gateway experiments |
| [.github/workflows](.github/workflows/README.md) | Automated checks |

Android is the current delivery platform. Retained iOS files and earlier architecture notes are historical material. Source code and the current build configuration take precedence over older plans. See [LICENSE](LICENSE) for licensing terms.
