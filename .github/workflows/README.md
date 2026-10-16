# Continuous integration

- `android-check.yml` runs static analysis, Flutter tests, and an internal release APK build. It also verifies that the packaged APK does not request INTERNET permission. It pins the Flutter 3.47.4 Linux archive checksum.
- `flutter analyze` treats warnings and informational diagnostics as failures. The required result is zero issues.
- Enable GitHub Actions in a fork. Workflows must be present on the default branch for their manual-dispatch controls to be available.
- `ios-check.yml` is retained for historical, manually triggered checks. Android is the current delivery platform.
- `firmware-check.yml` uses Arduino CLI 1.3.1 and Arduino-ESP32 3.3.11, runs firmware checks, and builds the **ESP32-C3** target. It uploads artifacts and logs without flashing hardware.

Internal release builds currently use debug signing. Signatures can differ between CI and local builds, preventing an in-place update. Public distribution requires a maintained release-signing process. Automated checks do not replace phone/BLE, GPIO wake, or physical-device testing.
