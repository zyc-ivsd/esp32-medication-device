# Continuous integration

- `android-check.yml` runs static analysis, Flutter tests, a debug APK build, and Python gateway protocol tests. It pins the Flutter 3.47.4 Linux archive checksum and uses Python 3.12.
- `flutter analyze` treats warnings and informational diagnostics as failures. The required result is zero issues.
- Enable GitHub Actions in a fork. Workflows must be present on the default branch for their manual-dispatch controls to be available.
- `ios-check.yml` is retained for historical, manually triggered checks. Android is the current delivery platform.
- `firmware-check.yml` uses Arduino CLI 1.3.1 and Arduino-ESP32 3.3.11, runs firmware checks, and builds the **ESP32-C3** target. It uploads artifacts and logs without flashing hardware.

Debug APK signatures can differ between CI and local builds, preventing an in-place update. Public distribution requires a maintained release-signing process. Mock gateway tests do not contact a production model service and do not validate an actual upstream connection. Automated checks do not replace phone/BLE, GPIO wake, or physical-device testing.
