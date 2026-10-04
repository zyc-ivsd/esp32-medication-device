#pragma once
#include <Arduino.h>

// Serial logging that stays silent unless a real monitor is attached.
//
// On ESP32-C3 the console is the native USB-CDC interface. With no host reading
// it two things go wrong: the TX buffer fills and println() blocks outright,
// and even before that each write waits on the USB polling interval, which
// stretches loop() and starves the BLE protocol. Both effects disappear the
// moment a monitor drains the port, which is why transfers looked 2-5x slower
// (and sometimes stalled) without one open.
//
// The detector below never writes until it has evidence of a reader:
//   * The CDC TX buffer starts empty, so "space available" alone proves nothing.
//     A probe line fills it, and only a reader can free that space again.
//   * After the probe, a buffer that keeps showing free space means a host is
//     draining it, so logging turns on permanently.
//   * With no reader the probe sits there, availableForWrite() stays low, and
//     every LOG/LOGLN becomes a no-op instead of a stall.
//
// Logging is a debugging aid, never a protocol step, so silence is always
// preferable to a frozen radio.
namespace logdetail {

// How many blank bytes the initial probe writes. This must exceed the USB-CDC
// TX buffer so the buffer ends up occupied; a short probe would leave room and
// look indistinguishable from an attached monitor.
constexpr size_t kBufProbeBytes = 512;
// Free space must reappear this many times before logging is trusted.
constexpr uint8_t kAttachConfirmations = 2;

inline bool &loggingEnabled() {
  static bool enabled = false;
  return enabled;
}

inline uint8_t &attachProgress() {
  static uint8_t progress = 0;
  return progress;
}

// Counts how often TX capacity reappears after the probe filled it. Called from
// the main loop; cheap enough to run every iteration.
inline void pollMonitor() {
  if (loggingEnabled()) return;
  if (Serial.availableForWrite() <= 0) return; // Probe still parked: no reader.
  if (++attachProgress() >= kAttachConfirmations) {
    loggingEnabled() = true;
    Serial.println();
    Serial.println("SERIAL_MONITOR: logging enabled");
  }
}

// Lays down the initial probe and gives an attached monitor a moment to drain
// it, so boot-time logging can appear too. Call once from setup() right after
// Serial.begin().
inline void primeMonitorProbe() {
  for (size_t written = 0; written < kBufProbeBytes;) {
    const int room = Serial.availableForWrite();
    if (room <= 0) break;
    const size_t chunk = static_cast<size_t>(room);
    for (size_t i = 0; i < chunk; ++i) Serial.write('\n');
    written += chunk;
  }
  // A monitor empties the buffer within a few milliseconds. Without one the
  // probe stays put, so this loop simply expires and logging stays disabled.
  const uint32_t deadline = millis() + 200;
  while (static_cast<int32_t>(millis() - deadline) < 0) {
    if (Serial.availableForWrite() > 0) {
      if (++attachProgress() >= kAttachConfirmations) {
        loggingEnabled() = true;
        return;
      }
    }
    delay(10);
  }
}

} // namespace logdetail

#define LOG(...) \
  do { if (logdetail::loggingEnabled()) Serial.printf(__VA_ARGS__); } while (0)
#define LOGLN(line) \
  do { if (logdetail::loggingEnabled()) Serial.println(line); } while (0)

// Bounded flush before sleeping or restarting. A bare Serial.flush() waits
// forever when no monitor is attached (the TX buffer never drains), which would
// hang the wake path. Without a monitor there is nothing to flush; with one,
// give the UART a short window and then continue regardless.
inline void logFlush() {
  if (!logdetail::loggingEnabled()) return;
  const uint32_t deadline = millis() + 50;
  while (Serial.availableForWrite() < 64 &&
         static_cast<int32_t>(millis() - deadline) < 0) {
    delay(1);
  }
}
