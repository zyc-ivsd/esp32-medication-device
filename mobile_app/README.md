# parcel Android · 0.4.0+6

English-language medication diary built with Flutter / Dart, with a lavender and peach interface. Android is the delivery target. There is no runtime demonstration dataset.

## Install and use

Android 7.0 / API 24 or later is required. Transfer the APK to the phone, open it in the file manager, allow installation and open **parcel**. Use **Overview → Device connection**, grant Bluetooth permissions and connect inside the app. Wake a sleeping device with its button before scanning.

Use the complete firmware from `codex/android-xiaozhi-prep`; older firmware without HELLO/READY cannot complete the handshake. TIME1 firmware is calibrated with UTC only (`TM`/`TOK`/`TER`) before transferring records. See [the wire protocol](../protocol/prototype-text-v01.md).

The device stores and reports **UTC only**: each record is 16 hex-digit Unix seconds. The app applies the phone's current timezone offset for display, so changing the phone timezone changes how records read without rewriting them. The device never learns the phone's timezone.

The team defines **one valid button-generated timestamp as one medication-use entry**. After synchronization, entries feed History, daily counts, CSV and assistant summaries. This is a user-triggered diary, not a dose measurement or proof of ingestion.

- `(device_id, file_id)` identifies an entry. Reconnection and replay do not add another count; different files at the same second remain separate entries. Conflicting content for an existing identity is rejected.
- Each record is 16 hex-digit UTC Unix seconds and must fall in 2001–2099. The firmware's year-2000 placeholder and malformed values are retained but excluded from daily counts. Future instants are also excluded until no longer future.
- Original text remains in `prototype_text.db`. Diary entries are stored in the new `timestamp_uses` table in `records_device.db` (schema v2), alongside existing structured events.
- ACK follows both durable writes. If interrupted between writes, replay or startup backfill repairs the missing entry. Last-sync time advances only after DONE. After DONE the device moves the transferred `data_` files into its DA/DB archive, so they are kept on device but never offered again; an unfinished round leaves them transferable, so reconnect-and-replay still recovers a dropped session.
- Upgrading imports **all** retained timestamps, including those beyond the connection page's 100-record display limit. Existing structured records, cursors, settings and chats remain. Historical test button presses cannot be distinguished from real diary entries and are also imported.
- Timestamp-only records do not supply pressure, duration, confidence or battery voltage. CSV fills those fields empty and exports the UTC instant plus the phone-local rendering.
- History filters and CSV use the same selection. Overview and assistant use the complete diary; the assistant reloads its summary for every question.

In-place updates require the same application ID (`org.igem.medication.medication_device_app`) and signing certificate. Do not uninstall simply to resolve a signing mismatch: uninstalling removes local data. Old demonstration databases remain unused and are not deleted automatically.

## Assistant

**Local** uses fixed rules, not a language model. It explains counts, synchronization, data quality and app functions offline. English quick questions and answers are provided, while legacy Chinese query matching remains supported.

**Online** connects directly to the user's OpenAI-compatible model API. In **Manage APIs**, enter the service URL, your own API key and model name, then confirm summary sharing. Credentials use `flutter_secure_storage`. No shared key is embedded in the APK, no team server is required, and Xiaozhi is not used.

Requests include the question, aggregate diary context and relevant on-device reference snippets. Raw rows and device identifiers are not automatically uploaded. Optional conversation history is off by default and limited to relevant recent messages. Answers stream into the chat; interrupted/truncated replies remain visible with a notice and retry option. Source labels distinguish records from general AI knowledge.

English read-aloud uses Android TTS (`en-US`) with a compatible installed offline voice. The app does not record speech or control the hardware. Records do not establish adherence, and the assistant does not prescribe or adjust medication.

## Develop and verify

Development branch: **`codex/android-xiaozhi-prep`**. Toolchain: Flutter **3.47.4**, Dart **3.13.3**, JDK **17**, Android compile/target SDK **36**. Dependencies are pinned in `pubspec.lock`.

```sh
cd mobile_app
flutter pub get --enforce-lockfile
flutter analyze
flutter test
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

Static analysis must report zero issues. Timestamp tests cover UTC hex validation, duplicate/conflicting files, same-second entries, schema-v1 migration, backfill beyond 100 rows, failure before ACK and completion only after DONE. Widget tests verify English diary dates, counts and original evidence.

For optional UI previews, set `PARCEL_PREVIEW_OUTPUT` to an output folder and `PARCEL_PREVIEW_FONTS` to Flutter's `bin/cache/artifacts/material_fonts`, then run `flutter test test/timestamp_diary_ui_test.dart`. Fixtures exist only in tests, not in the APK.

| Entry point | Responsibility |
|---|---|
| `lib/ble/` | Permissions, P01/TIME1 synchronization, raw storage and diary write-through |
| `lib/database/`, `lib/models/` | Durable storage, migration, deduplication, calendar validation and daily summaries |
| `lib/pages/`, `lib/services/` | Overview, history, details, filters and CSV |
| `lib/theme/` | Shared lavender/peach theme |
| `lib/assistant/` | English UI, local rules, reference retrieval, model API and TTS |

Automated tests cannot validate phone permissions, radio behavior, physical button debounce or hardware timekeeping. Debug APKs are for internal testing. Release currently also uses debug signing; establish a team-owned release key before public distribution. See [remaining work](../docs/android-roadmap.md).
