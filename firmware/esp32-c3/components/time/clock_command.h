#pragma once
#include <stdint.h>
#include <string.h>

struct PhoneClockCommand { uint32_t utc; int32_t offset; };
inline bool validPhoneClock(uint32_t utc, int32_t offset) {
  return utc >= 946684800U && utc <= 4102444799U && offset >= -840 && offset <= 840;
}
// TIME|8-hex-UTC-seconds|signed-offset-minutes: at most 18 ASCII bytes.
inline bool parsePhoneClock(const char *text, PhoneClockCommand &result) {
  const size_t length = strlen(text);
  if (length < 15 || length > 18 || strncmp(text, "TIME|", 5) != 0 || text[13] != '|') return false;
  uint32_t utc = 0;
  for (size_t i = 5; i < 13; ++i) {
    const char c = text[i];
    const int digit = c >= '0' && c <= '9' ? c - '0' :
      (c >= 'a' && c <= 'f' ? c - 'a' + 10 : (c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1));
    if (digit < 0) return false;
    utc = (utc << 4) | static_cast<uint32_t>(digit);
  }
  size_t i = 14;
  const bool negative = text[i] == '-';
  if (negative) ++i;
  if (i == length || length - i > 3) return false;
  int32_t offset = 0;
  for (; i < length; ++i) {
    if (text[i] < '0' || text[i] > '9') return false;
    offset = offset * 10 + text[i] - '0';
  }
  if (negative) offset = -offset;
  if (!validPhoneClock(utc, offset)) return false;
  result = {utc, offset};
  return true;
}
