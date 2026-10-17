# Continuous integration

| Workflow | Checks and outputs |
|---|---|
| `android-check.yml` | Static analysis, Flutter tests, internal release APK, and packaged INTERNET-permission check |
| `firmware-check.yml` | Clock-command and BLE-subscription host tests, ESP32-C3 firmware build, and validation logs |
| `ios-check.yml` | Manually triggered platform checks |

The Android workflow pins the Flutter 3.47.4 Linux archive checksum. `flutter analyze` requires zero issues, including warnings and informational diagnostics. The firmware workflow uses Arduino CLI 1.3.1 and Arduino-ESP32 3.3.11 with the `esp32:esp32:esp32c3` target.

Enable GitHub Actions in a fork to execute the workflows. Manual-dispatch controls require the workflow definition on the default branch.

Internal release APKs use debug signing. In-place updates require matching signing certificates; distribution builds require a team-managed release key. Firmware artifacts are compiled binaries and are not automatically flashed. Physical-device checks assess BLE, GPIO wake, button behavior, and timekeeping.
