#include <Arduino.h>
#include <Preferences.h>
#include <time.h>
#include <sys/time.h>
#include "clock_command.h"

// UTC is the system clock and the only time base the device stores or sends.
// The device does not know the phone's timezone. A saved clock is a last-known
// value, not a battery-backed RTC after power loss.
Preferences clockPreferences;
bool clockStorageReady = false;
bool clockValid = false;
bool clockSynced = false;
struct ClockSnapshot { int64_t utc; uint32_t version; };

bool saveTimeToNVS() {
  if (!clockStorageReady || !clockValid) return false;
  const ClockSnapshot snapshot = {static_cast<int64_t>(time(nullptr)), 2};
  return clockPreferences.putBytes("snapshot", &snapshot, sizeof(snapshot)) == sizeof(snapshot);
}
bool setPhoneTime(uint32_t utc) {
  if (!validPhoneClock(utc) || !clockStorageReady) return false;
  struct timeval now = {};
  now.tv_sec = utc;
  if (settimeofday(&now, nullptr) != 0) return false;
  clockValid = true;
  clockSynced = saveTimeToNVS();
  return clockSynced;
}
void restoreTimeFromNVS() {
  clockSynced = false;
  // No nvs_flash_erase(): the same NVS partition holds the persistent file counter.
  clockStorageReady = clockPreferences.begin("device-time", false);
  ClockSnapshot snapshot = {};
  bool restored = clockStorageReady &&
    clockPreferences.getBytesLength("snapshot") == sizeof(snapshot) &&
    clockPreferences.getBytes("snapshot", &snapshot, sizeof(snapshot)) == sizeof(snapshot) &&
    snapshot.version == 2 && snapshot.utc >= 946684800LL && snapshot.utc <= 4102444799LL;
  if (!restored) {
    // Retain the hardware branch's previous rtc/tlo/thi snapshot when present.
    Preferences legacy;
    if (legacy.begin("rtc", true)) {
      const uint64_t saved = (static_cast<uint64_t>(legacy.getUInt("thi", 0)) << 32) |
        legacy.getUInt("tlo", 0);
      restored = legacy.getUInt("tvalid", 0) != 0 && saved >= 946684800ULL && saved <= 4102444799ULL;
      if (restored) snapshot.utc = saved;
      legacy.end();
    }
  }
  struct timeval now = {};
  now.tv_sec = restored ? snapshot.utc : 946684800LL;
  clockValid = restored && settimeofday(&now, nullptr) == 0;
  if (!restored) settimeofday(&now, nullptr); // Explicit 2000 placeholder; never pretend calibrated.
  Serial.println(restored ? "CLOCK_RESTORED: power-off elapsed time unknown; phone calibration required" :
    "CLOCK_UNCALIBRATED: connect phone before interpreting prototype timestamps");
}
// The device records UTC. The name reads as "local" for call-site continuity,
// but there is no per-device offset: the phone applies its own when displaying.
void getDeviceLocalTime(struct tm &result) {
  const time_t utc = time(nullptr);
  gmtime_r(&utc, &result);
}
void printTime() {
  struct tm result;
  getDeviceLocalTime(result);
  char text[32];
  strftime(text, sizeof(text), "%Y-%m-%d %H:%M:%S", &result);
  Serial.printf("CLOCK %s UTC; phone calibrated this boot: %s\n",
    text, clockSynced ? "yes" : "no");
}
