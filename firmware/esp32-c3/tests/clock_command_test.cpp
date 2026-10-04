#include "../components/time/clock_command.h"
#include <assert.h>
#include <stdio.h>

int main() {
  PhoneClockCommand result = {};
  assert(parsePhoneClock("TM|00000000386d4380", result)); // 2000-01-01 UTC
  assert(result.utc == 946684800U);
  assert(parsePhoneClock("TM|00000000F48656FF", result)); // last second of 2099
  assert(result.utc == 4102444799U);
  assert(parsePhoneClock("TM|00000000f48656ff", result)); // lowercase accepted
  const char *invalid[] = {
    "TM|00000000386d437f", "TM|00000000f4865700", // out of supported years
    "TM|386d4380", "TM|00000000386d4380|480",     // legacy 8-hex or offset form
    "TM|00000000386d43800", "TM|00000000386d438",  // wrong length
    "TM|00000000386d438x", "TM|00000000386d4380junk",
    "TIME|00000000386d4380",                       // old long prefix is no longer valid
    "TM2026-10-03 12:00:00", "", "TM|", "TM"
  };
  for (const char *value : invalid) assert(!parsePhoneClock(value, result));
  puts("Phone clock protocol: TM UTC-only bounds and malformed commands passed");
}
