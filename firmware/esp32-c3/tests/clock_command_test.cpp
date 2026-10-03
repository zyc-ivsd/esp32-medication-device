#include "../components/time/clock_command.h"
#include <assert.h>
#include <stdio.h>

int main() {
  PhoneClockCommand result = {};
  assert(parsePhoneClock("TIME|386d4380|480", result)); // 2000-01-01 UTC
  assert(result.utc == 946684800U && result.offset == 480);
  assert(parsePhoneClock("TIME|F48656FF|-840", result)); // last second of 2099
  assert(result.utc == 4102444799U && result.offset == -840);
  assert(parsePhoneClock("TIME|386d4380|840", result));
  assert(parsePhoneClock("TIME|386d4380|0", result));
  const char *invalid[] = {
    "TIME|386d437f|0", "TIME|f4865700|0", // out of supported years
    "TIME|386d4380|841", "TIME|386d4380|-841", // invalid timezones
    "TIME|386d4380|", "TIME|386d4380|-", "TIME|386d4380|+1",
    "TIME|386d4380|0junk", "TIME|386d4380|1|2", "TIME|386d4380|1000",
    "TIME|386d438x|0", "TIME|386d43800|0", "TIME|386d438|0",
    "TM2026-10-03 12:00:00", "", "TIME|", "TIME"
  };
  for (const char *value : invalid) assert(!parsePhoneClock(value, result));
  puts("Phone clock protocol: UTC bounds, offsets and malformed commands passed");
}
