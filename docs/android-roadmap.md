# Android current development plan

Current branch: **`codex/android-xiaozhi-prep`**. App: **0.4.0+6**, English UI, lavender/peach theme. Android is the delivery target; Xiaozhi is not part of the current design.

Each valid button-generated timestamp now represents one medication-use entry. The app backfills retained timestamps, saves new entries before ACK, deduplicates by device/file identity and supplies Overview, History, CSV and assistant summaries. No sensor measurements or UTC offsets are invented.

| Owner | Next action | Acceptance evidence |
|---|---|---|
| Android + hardware | Install over the previous APK, with matching branch firmware. Sync, press once, sync again, then repeat synchronization. | One new entry with correct date/time; daily count +1; replay adds zero; old data remains. |
| Hardware | Check button debounce, wake-up behavior and clock retention. A wake-up press currently also creates a record. | Each intended press generates one file; explicitly agree whether wake-up presses should count. Do not silently filter them on the phone. |
| Android + hardware | Interrupt transfer, reconnect, restart and test storage failures. | No ACK before both saves, no duplicate counts, no false completed-sync timestamp; hardware files retained for retry. |
| Android | Test real phones, large text, Bluetooth permissions, date filters, CSV sharing and offline English TTS. | Screenshots and CSV agree with actual device entries; controls remain readable. |
| Assistant member | Test the actual model, long answers, cancellation and disconnection. | English default responses; counts match Overview; partial answers retained and labeled; no credentials in logs/exports. |
| Hardware + protocol | Define log retention and richer timestamp metadata before extended deployment. Current P01 snapshots are limited to 256 retained files. | Stable event identity, original time offset/quality and safe acknowledged-record retention, with migration/replay tests. |
| Release owner | Establish team-owned signing and backup procedures. | Reproducible signed build and upgrade path that preserves data. |

The 20-byte structured-event model remains available for a future sensor protocol, but is not required for today's button-based diary. If both protocols later represent the same physical action, agree on shared event identity before enabling both to avoid double counting.

Build instructions: [App README](../mobile_app/README.md). Wire behavior: [P01 / TIME1](../protocol/prototype-text-v01.md). Older dated documents describe historical stages and do not override these current entry points.
