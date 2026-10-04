#pragma once
#include <stdint.h>
#include <string.h>

struct PhoneClockCommand { uint32_t utc; };
inline bool validPhoneClock(uint32_t utc) {
  return utc >= 946684800U && utc <= 4102444799U;
}
// TIME is abbreviated to TM so the whole control command fits the 20-byte
// write limit: "TM|" (3) + 16 hex digits (16) = 19 bytes. The device never
// learns the phone's timezone; the phone applies its own offset when displaying
// the raw UTC seconds it later receives from the device.
inline bool parsePhoneClock(const char *text, PhoneClockCommand &result) {
  if (strlen(text) != 19 || strncmp(text, "TM|", 3) != 0) return false;
  uint32_t utc = 0;
  for (size_t i = 3; i < 19; ++i) {
    const char c = text[i];
    const int digit = c >= '0' && c <= '9' ? c - '0' :
      (c >= 'a' && c <= 'f' ? c - 'a' + 10 : (c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1));
    if (digit < 0) return false;
    utc = (utc << 4) | static_cast<uint32_t>(digit);
  }
  if (!validPhoneClock(utc)) return false;
  result = {utc};
  return true;
}
