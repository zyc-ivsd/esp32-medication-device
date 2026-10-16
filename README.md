# parcel — AeroEase

AeroEase is the Android companion app for parcel's portable aerosol delivery project. It transfers device timestamps over Bluetooth, stores them on the phone, and presents a medication-use diary with daily counts, history, CSV export, and an offline rule-based assistant. The interface is English with a lavender and peach palette.

## Hardware: ESP32-C3

The project uses **ESP32-C3**. The Arduino firmware is maintained under `firmware/esp32-c3/`, and firmware CI builds the `esp32:esp32:esp32c3` target. AeroEase communicates with the device over BLE.

## User workflow

1. Open AeroEase on an Android phone and connect through the device page.
2. Synchronize button-generated timestamps over BLE.
3. Review medication-use times and daily counts in Overview and History.
4. Export selected entries as CSV or ask the local assistant about the stored counts.

The team defines one valid button-generated timestamp as one medication-use entry. This is a diary convention, not a measurement of delivered dose or proof of inhalation. Replaying the same device/file identity does not add another entry.

## Data and privacy

Original device text is retained locally, and valid timestamps populate the diary. A record is acknowledged only after its required local writes succeed. Incomplete synchronization can be retried; conflicting content under an existing identity is rejected. Unknown or future timestamps remain inspectable but do not contribute to current daily counts.

The assistant works offline with fixed local rules, not a language model. Cloud providers, API settings, credential-storage dependencies, and the experimental gateway have been removed. There is no runtime demonstration dataset. Release builds do not request Android INTERNET permission; debug/profile builds retain it for Flutter development tools.

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
flutter build apk --release
```

The Android app is **AeroEase 0.4.2+8**. The development toolchain uses Flutter 3.47.4, Dart 3.13.3, JDK 17, and Android SDK 36. Android 7.0 / API 24 or later is required. Debug APKs are intended for testing; retain the application ID and signing certificate for in-place updates that preserve local data.

## Repository guide

| Directory | Contents |
|---|---|
| [mobile_app](mobile_app/README.md) | Flutter Android app and tests |
| [firmware](firmware/README.md) | ESP32-C3 prototype firmware |
| [hardware](hardware/README.md) | PCB, schematic, Gerber, and BOM assets |
| [protocol](protocol/README.md) | BLE and record-format documentation |
| [ftest](ftest/README.md) | Isolated firmware diagnostic sketches |
| [docs](docs/README.md) | Development notes and historical handoffs |
| [tools/python](tools/python/README.md) | Desktop helper-tool area |
| [.github/workflows](.github/workflows/README.md) | Automated checks |

Android is the current delivery platform. Retained iOS files and earlier architecture notes are historical material. Source code and the current build configuration take precedence over older plans. See [LICENSE](LICENSE) for licensing terms.
