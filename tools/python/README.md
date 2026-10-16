# Python helper tools

This directory is reserved for desktop development utilities. Python is not a runtime dependency of the Android app.

Planned uses include BLE scanning and notification debugging, checksum and acknowledgment tests, test-fixture generation, and CSV/JSON analysis. These plans do not imply that each utility is implemented. Test fixtures are separate from the app's user-facing data; there is no runtime demonstration dataset.

From this directory, create and activate an environment before installing dependencies:

```sh
python -m venv .venv
python -m pip install -r requirements.txt
```
