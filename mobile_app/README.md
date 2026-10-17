# AeroEase Android · 0.4.2+8

AeroEase is a Flutter / Dart medication-use diary with an English interface and lavender and peach colors. It connects to the project's **ESP32-C3** device over BLE and stores synchronized records on the phone.

## Using the app

Android 7.0 / API 24 or later is required. Install the APK and open **AeroEase**. Use **Overview → Device connection** to grant Bluetooth permissions, scan, and connect. The [UCAS-China Software page](https://2026.igem.wiki/ucas-china/software) provides user-facing project and usage information.

Use the [firmware supplied in this repository](../firmware/esp32-c3/README.md), which implements the P01/TIME1 handshake and UTC clock calibration. See the [wire protocol](../protocol/prototype-text-v01.md).

## Records and summaries

One valid button-generated timestamp represents one medication-use diary entry. Entries populate Overview, History, CSV exports, and assistant summaries. They describe device activity, not measured dose or confirmed inhalation.

- The device reports UTC Unix seconds as 16 hexadecimal digits. The phone converts each instant to local time for display.
- `(device_id, file_id)` identifies an entry. Repeated transfers preserve the count; separate files recorded in the same second remain separate entries. Conflicting payloads under an existing identity are rejected.
- The diary accepts timestamps in 2001–2099. Malformed, unknown, and future values remain inspectable but do not contribute to current daily counts.
- Original text is stored in `prototype_text.db`. Diary entries use the `timestamp_uses` table in `records_device.db` (schema version 2).
- ACK follows the required durable writes. Replay and startup backfill maintain consistency between raw storage and diary entries. Last-sync time advances after DONE.
- Firmware archives committed files in DA/DB groups. Pending files remain available for synchronization retry.
- History and CSV use the same date selection. Overview and the assistant summarize the complete diary; the assistant reads a fresh summary for each question.
- Timestamp-only records do not contain pressure, duration, confidence, or battery measurements. Corresponding CSV fields remain empty.

## Offline assistant and privacy

The assistant uses fixed local rules to explain counts, synchronization, data quality, and app functions. Questions, summaries, and chat history are processed locally. It requires no account, API key, or network connection and provides no diagnostic or dosing advice.

English read-aloud uses an installed Android TTS voice marked as not requiring a network connection. If a suitable voice is unavailable, the app reports that read-aloud is unavailable. Chat search, clear-chat controls, larger text, and read-aloud preferences are available on the assistant page.

Release APKs do not request Android INTERNET permission. Debug/profile builds include network permission for Flutter development tools. CSV export uses the phone's share interface at the user's request.

## Build and verification

Toolchain: Flutter **3.47.4**, Dart **3.13.3**, JDK **17**, Android compile/target SDK **36**. Dependencies are pinned in `pubspec.lock`.

From this directory:

```sh
flutter pub get --enforce-lockfile
flutter analyze
flutter test --concurrency=1
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Tests cover UTC timestamp validation, duplicate and conflicting files, storage consistency, database migration, acknowledgments, synchronization completion, record summaries, CSV selection, offline assistance, and interface behavior. CI also verifies that the release APK does not request INTERNET permission. Physical-device checks cover Bluetooth permissions, radio behavior, button input, and device timekeeping.

For UI renders, set `PARCEL_PREVIEW_OUTPUT` to an output folder and `PARCEL_PREVIEW_FONTS` to Flutter's `bin/cache/artifacts/material_fonts`, then run `flutter test test/timestamp_diary_ui_test.dart`. Preview fixtures are confined to tests.

## Application structure

| Entry point | Responsibility |
|---|---|
| `lib/ble/` | Bluetooth permissions, P01/TIME1 synchronization, and raw storage |
| `lib/database/`, `lib/models/` | Diary storage, identity checks, date validation, and summaries |
| `lib/pages/`, `lib/services/` | Overview, history, details, date filters, and CSV |
| `lib/theme/` | Shared lavender and peach theme |
| `lib/assistant/` | Offline rules, local chat history, and read-aloud |

## Signing and installation

The application ID is `org.igem.medication.medication_device_app`. In-place updates require the same application ID and signing certificate. Uninstalling removes local app data.

The build configuration uses the Android debug key for internal release APKs. Distribution builds require a team-managed signing key and a consistent update-signing process.
