# parcel — AeroEase

AeroEase is the Android companion app for parcel's portable aerosol delivery device. It synchronizes ESP32-C3 timestamps over Bluetooth and presents a medication-use diary with daily summaries, record history, CSV export, and an offline assistant. The English interface uses a lavender and peach palette.

## Features

- Bluetooth connection, device clock calibration, and timestamp synchronization.
- Daily and seven-day activity summaries with interactive record views.
- Date-filtered history, individual record details, and CSV export.
- Offline explanations of saved records and app functions.
- Local storage with duplicate detection and acknowledgment after durable saves.

Each valid button-generated timestamp represents one medication-use diary entry. It records a device action; it does not measure the delivered dose or confirm inhalation.

## User guide

See the [Software page on the UCAS-China Wiki](https://2026.igem.wiki/ucas-china/software) for the user-facing project description and usage guidance. AeroEase requires **Android 7.0 / API 24 or later**, Bluetooth, and the matching ESP32-C3 device firmware.

## Data and privacy

Original device text and diary entries are stored locally. Records are identified by device and file, so repeated synchronization does not increase the count. Conflicting content under an existing identity is rejected. Unknown and future timestamps remain available for inspection and export while being excluded from current daily counts.

The assistant uses fixed local rules and processes questions and record summaries on the phone. It requires no account or model API key. English read-aloud uses an installed Android voice marked as not requiring a network connection.

Release APKs do not request Android INTERNET permission. Debug and profile builds include network permission for Flutter development tools. CSV sharing is initiated by the user.

## Build and test

App version: **AeroEase 0.4.2+8**. Toolchain: **Flutter 3.47.4**, **Dart 3.13.3**, **JDK 17**, and **Android SDK 36**. Dependencies are pinned in `mobile_app/pubspec.lock`.

```sh
git clone --branch codex/android-xiaozhi-prep https://github.com/zyc-ivsd/esp32-medication-device.git
cd esp32-medication-device/mobile_app
flutter pub get --enforce-lockfile
flutter analyze
flutter test --concurrency=1
flutter build apk --release
```

The APK is generated at `mobile_app/build/app/outputs/flutter-apk/app-release.apk`, relative to the repository root. See the [Android README](mobile_app/README.md) for application structure and signing requirements, and the [firmware README](firmware/esp32-c3/README.md) for the Arduino build.

## Repository guide

| Directory | Contents |
|---|---|
| [mobile_app](mobile_app/README.md) | Flutter Android app and tests |
| [firmware](firmware/README.md) | ESP32-C3 Arduino firmware |
| [hardware](hardware/README.md) | PCB, schematic, Gerber, and BOM assets |
| [protocol](protocol/README.md) | BLE synchronization and record formats |
| [ftest](ftest/README.md) | GPIO light-sleep diagnostic program |
| [docs](docs/README.md) | Software and integration references |
| [tools/python](tools/python/README.md) | Desktop Python dependency manifest |
| [.github/workflows](.github/workflows/README.md) | Automated checks and build artifacts |

## License

Project source code is distributed under the [MIT License](LICENSE). Third-party dependencies retain their respective licenses.
